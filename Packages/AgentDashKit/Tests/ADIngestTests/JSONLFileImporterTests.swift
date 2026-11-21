import ADCore
@testable import ADIngest
import ADStore
import Foundation
import Testing

@Test("ADP-2: a split UTF-8 character and split CRLF retain their original byte positions")
func framingKeepsByteOffsetsAcrossChunks() throws {
    var framer = JSONLFramer(offset: 10, sequence: 4, prefixLimit: 16)
    let bytes = Data("登录\r\nlast\r".utf8)
    var lines: [JSONLFrame] = []
    try framer.push(bytes.prefix(2)) { lines.append($0) }
    #expect(lines.isEmpty)
    try framer.push(bytes.dropFirst(2).prefix(5)) { lines.append($0) } // stops at the CR
    #expect(lines.isEmpty)
    try framer.push(bytes.dropFirst(7)) { lines.append($0) }
    #expect(lines.map(\.endOffset) == [18])
    try framer.push(Data([0x0A])) { lines.append($0) }
    #expect(lines.map { String(decoding: $0.bytes, as: UTF8.self) } == ["登录", "last"])
    #expect(lines.map(\.endOffset) == [18, 24])
    #expect(lines.map(\.sequence) == [5, 6])
}

@Test("ADP-2/5: restart reads only the uncommitted tail and retains the prior decoder context")
func completeLinesSurviveAStoreReopen() throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }
    let complete = Data("{\"text\":\"首条\",\"timestamp\":42}\r\n".utf8)
    let pending = Data("{\"text\":\"待续\"}".utf8)
    try (complete + pending).write(to: fixture.input)
    let sourceBefore = try fixture.snapshot()

    let first = try fixture.importRecords()
    #expect(first.completeLines == 1)
    #expect(first.checkpoint.offset == Int64(complete.count))
    #expect(first.checkpoint.sequence == 0)
    #expect(first.checkpoint.size == Int64(complete.count + pending.count))
    #expect(first.checkpoint.decoderState == Data([0x42]))
    #expect(try fixture.store.events(in: fixture.key).map(\.text) == ["首条"])
    #expect(try fixture.snapshot() == sourceBefore)
    #expect(try Data(contentsOf: fixture.input) == complete + pending)

    let reopened = try AgentStore(databaseURL: fixture.index)
    try fixture.append(Data([0x0A]))
    let second = try JSONLFileImporter.importFile(fixture.file, authorizedRoot: fixture.root, store: reopened) { line, context in
        #expect(context.previousTimestamp == 42)
        #expect(context.state == Data([0x42]))
        return fixture.decode(line, context)
    }
    #expect(second.completeLines == 1)
    #expect(second.bytesRead == Int64(pending.count + 1))
    #expect(second.checkpoint.sequence == 1)
    #expect(second.checkpoint.offset == second.checkpoint.size)
    let events = try reopened.events(in: fixture.key)
    #expect(events.map(\.text) == ["首条", "待续"])
    #expect(events.map(\.timestamp) == [42, 42])
    let unchanged = try fixture.importRecords()
    #expect(unchanged.bytesRead == 0)
    #expect(unchanged.completeLines == 0)
    #expect(unchanged.checkpoint == second.checkpoint)
}

@Test("ADP-2…4: shrink, inode replacement and parser upgrade replay from the beginning")
func rewriteAndVersionInvalidateOffsets() throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }
    try Data("{\"text\":\"before one\"}\n{\"text\":\"before two\"}\n".utf8).write(to: fixture.input)
    let first = try fixture.importRecords()

    let smaller = Data("{\"text\":\"small\"}\n".utf8)
    let writer = try FileHandle(forWritingTo: fixture.input)
    try writer.truncate(atOffset: 0)
    try writer.write(contentsOf: smaller)
    try writer.close()
    let shrunk = try fixture.importRecords(expectNewDecoder: true)
    #expect(shrunk.checkpoint.inode == first.checkpoint.inode)
    #expect(shrunk.bytesRead == Int64(smaller.count))

    let replacement = Data("{\"text\":\"replacement one\"}\n{\"text\":\"replacement two\"}\n".utf8)
    try replacement.write(to: fixture.input, options: .atomic)
    let replaced = try fixture.importRecords(expectNewDecoder: true)
    #expect(replaced.checkpoint.inode != shrunk.checkpoint.inode)
    #expect(replaced.bytesRead == Int64(replacement.count))

    var upgraded = fixture.file
    upgraded.parserVersion += 1
    let reparsed = try fixture.importRecords(file: upgraded, expectNewDecoder: true)
    #expect(reparsed.checkpoint.parserVersion == upgraded.parserVersion)
    #expect(reparsed.bytesRead == Int64(replacement.count))
    #expect(try fixture.store.events(in: fixture.key).map(\.text) == ["replacement one", "replacement two"])
}

@Test("ADP-1/2: an oversized line and malformed JSON do not prevent importing the next line")
func boundedPrefixAndUnknownCount() throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }
    let oversized = Data(repeating: 0x61, count: 1_048_600)
    try (oversized + Data("\ninvalid-json\n{\"text\":\"after\"}\n".utf8)).write(to: fixture.input)
    let result = try JSONLFileImporter.importFile(fixture.file, authorizedRoot: fixture.root, store: fixture.store) { line, context in
        if line.sequence == 0 {
            #expect(line.isTruncated)
            #expect(line.bytes.count == 1_048_576)
            #expect(line.endOffset == Int64(oversized.count + 1))
        }
        return fixture.decode(line, context)
    }
    #expect(result.completeLines == 3)
    #expect(result.checkpoint.unknownRecords == 2)
    #expect(try fixture.store.checkpoint(for: result.fileID) == result.checkpoint)
    #expect(try fixture.store.events(in: fixture.key).map(\.text) == ["after"])
}

@Test("ADP-2: a same-size modification invalidates the append-only checkpoint")
func sameSizeModificationForcesReplay() throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }
    let old = Data("{\"text\":\"one\"}\n".utf8)
    let new = Data("{\"text\":\"two\"}\n".utf8)
    try old.write(to: fixture.input)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)],
                                         ofItemAtPath: fixture.input.path)
    let first = try fixture.importRecords()
    let writer = try FileHandle(forWritingTo: fixture.input)
    try writer.write(contentsOf: new)
    try writer.close()
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2000)],
                                         ofItemAtPath: fixture.input.path)
    let updated = try fixture.importRecords(expectNewDecoder: true)
    #expect(updated.checkpoint.size == first.checkpoint.size)
    #expect(updated.checkpoint.inode == first.checkpoint.inode)
    #expect(updated.completeLines == 1)
    #expect(try fixture.store.events(in: fixture.key).map(\.text) == ["two"])
}

@Test("ADP-2: a mutation noticed before commit cannot advance the read position")
func rejectsMutationDuringRead() throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }
    try Data("{\"text\":\"synthetic mutation\"}\n".utf8).write(to: fixture.input)
    let fileID = try fixture.store.upsertFile(fixture.file, checkpoint: nil)
    #expect(throws: JSONLImportFailure.sourceChanged) {
        try JSONLFileImporter.importFile(fixture.file, authorizedRoot: fixture.root, store: fixture.store) { line, context in
            let writer = try FileHandle(forWritingTo: fixture.input)
            try writer.truncate(atOffset: 0)
            try writer.close()
            return fixture.decode(line, context)
        }
    }
    #expect(try fixture.store.checkpoint(for: fileID) == nil)
    #expect(try fixture.store.events(in: fixture.key).isEmpty)
}

@Test("ADP-2/3: a failed batch keeps the preceding committed position and does not duplicate records on retry")
func failedNormalizedWriteLeavesPreviousCheckpoint() throws {
    let fixture = try ImportFixture()
    defer { fixture.remove() }
    let complete = Data("{\"text\":\"good\"}\n".utf8)
    try (complete + Data("{\"text\":\"retry\"}\n".utf8)).write(to: fixture.input)
    let fileID = try fixture.store.upsertFile(fixture.file, checkpoint: nil)
    #expect(throws: StoreError.invalidTokenCounts) {
        try JSONLFileImporter.importFile(fixture.file, authorizedRoot: fixture.root, store: fixture.store) { line, context in
            let decoded = fixture.decode(line, context)
            if line.sequence == 0, let event = decoded.records.last {
                // Fill exactly one atomic batch with idempotent writes.
                return .init(records: [.session(fixture.session(context.fileID))] + Array(repeating: event, count: 499),
                             state: decoded.state)
            }
            return .init(records: decoded.records + [
                .tokens(.init(session: fixture.key, timestamp: 0, counts: .init(inputFresh: -1), dedupeKey: "synthetic:invalid"))
            ])
        }
    }
    #expect(try fixture.store.checkpoint(for: fileID)?.offset == Int64(complete.count))
    #expect(try fixture.store.events(in: fixture.key).map(\.text) == ["good"])
    let retry = try fixture.importRecords()
    #expect(retry.completeLines == 1)
    #expect(try fixture.store.events(in: fixture.key).map(\.text) == ["good", "retry"])
}

private struct ImportFixture {
    let directory: URL
    let root: URL
    let index: URL
    let input: URL
    let store: AgentStore
    let file: SourceFile
    let key = SessionKey(agent: .codex, nativeID: "synthetic-import")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("jsonl-import-\(UUID().uuidString)")
        root = directory.appendingPathComponent("synthetic-source")
        index = directory.appendingPathComponent("index.sqlite")
        input = root.appendingPathComponent("records.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: index)
        let sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: root))
        file = .init(sourceID: sourceID, relativePath: "records.jsonl", role: .session)
    }

    func importRecords(file override: SourceFile? = nil, expectNewDecoder: Bool = false) throws -> JSONLImportResult {
        try JSONLFileImporter.importFile(override ?? file, authorizedRoot: root, store: store) { line, context in
            if expectNewDecoder && line.sequence == 0 { #expect(context.state == nil) }
            return decode(line, context)
        }
    }

    func snapshot() throws -> SourceFileReader.Snapshot {
        try SourceFileReader(root: root, relativePath: file.relativePath).snapshot()
    }

    func append(_ bytes: Data) throws {
        let writer = try FileHandle(forWritingTo: input)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: bytes)
    }

    func session(_ fileID: Int64) -> SessionRecord {
        .init(key: key, sourceID: file.sourceID, fileID: fileID, environment: "Synthetic")
    }

    private struct Message: Decodable {
        let text: String
        let timestamp: Int64?
    }

    func decode(_ line: JSONLFrame, _ context: JSONLDecodeContext) -> DecodedJSONLFrame {
        guard !line.isTruncated, let message = try? JSONDecoder().decode(Message.self, from: line.bytes)
        else { return .init(state: context.state, isUnknown: true) }
        let event = EventRecord(session: key, sequence: line.sequence,
                                timestamp: message.timestamp ?? context.previousTimestamp ?? 0,
                                kind: .user, text: message.text, dedupeKey: "message:\(line.sequence)")
        return .init(records: [.session(session(context.fileID)), .event(event)],
                     timestamp: message.timestamp, state: Data([0x42]))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
