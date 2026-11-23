import ADAdapters
import ADCore
import ADIngest
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("ADP-CX: appendix on reopen replaces transcript copies, deduplicates cumulative usage and keeps exact totals")
func codexRestoresChannelUsageAndToolContext() throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let fallback = #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"syntheticfallback"}]}}"#
    let firstUsage = #"{"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":1000,"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":3,"reasoning_output_tokens":2},"total_token_usage":{"total_tokens":13}}}}"#
    let initial = lines([
        box.header,
        #"{"type":"turn_context","payload":{"model":"synthetic-model","cwd":"/synthetic/latest"}}"#,
        fallback,
        firstUsage,
        #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"synthetic-tool","arguments":"{\"cmd\":\"synthetic check\"}"}}"#,
        #"{"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"plan_type":"synthetic","primary":{"window_minutes":300,"used_percent":42,"resets_at":1700000000}}}}"#,
    ])
    try box.write(initial, to: box.plain)
    let first = try box.importPath(box.plain)
    #expect(first.completeLines == 6)
    #expect(try box.store.events(in: box.key).contains { $0.transcriptChannel == .fallback })

    let reopened = try AgentStore(databaseURL: box.index)
    let appended = lines([
        #"{"type":"event_msg","payload":{"type":"user_message","message":"修复登录问题"}}"#,
        fallback,
        firstUsage,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":11,"cached_input_tokens":3,"output_tokens":5,"reasoning_output_tokens":1},"total_token_usage":{"total_tokens":30}}}}"#,
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"synthetic-tool","output":"synthetic result"}}"#,
    ])
    let handle = try FileHandle(forWritingTo: box.root.appendingPathComponent(box.plain))
    try handle.seekToEnd()
    try handle.write(contentsOf: appended)
    try handle.close()
    let continued = try box.importPath(box.plain, store: reopened)
    #expect(continued.completeLines == 5 && continued.bytesRead == Int64(appended.count))
    let events = try reopened.events(in: box.key)
    #expect(events.filter { $0.kind == .user || $0.kind == .assistant }.map(\.text) == ["修复登录问题"])
    #expect(events.first { $0.kind == .toolResult }?.toolName == "exec_command")
    try reopened.databasePool.read { db in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM events_fts WHERE events_fts MATCH 'syntheticfallback'") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM events_fts WHERE events_fts MATCH '登录'") == 1)
        let tokens = try #require(try Row.fetchOne(db, sql: """
            SELECT count(*) n,sum(input_fresh) fresh,sum(cache_read) cached,sum(output) produced,sum(reasoning) thought
            FROM token_events
            """))
        #expect((tokens["n"] as Int) == 2)
        // (10-4,4,3) + (11-3,3,5) = 29 tokens; reasoning is inside output.
        let components = TokenCounts(inputFresh: tokens["fresh"], cacheRead: tokens["cached"],
                                     output: tokens["produced"], reasoning: tokens["thought"])
        #expect(components == TokenCounts(inputFresh: 14, cacheRead: 7, output: 8, reasoning: 3))
        #expect(components.total == 29)
        let session = try #require(try Row.fetchOne(db, sql: "SELECT * FROM sessions"))
        #expect((session["environment"] as String) == "Synthetic rule")
        #expect((session["entrypoint"] as String) == "synthetic-cli")
        #expect((session["cwd"] as String) == "/synthetic/latest")
        #expect((session["context_window"] as Int) == 1000)
        #expect((session["context_used"] as Int) == 11)
        #expect(try Int64.fetchOne(db, sql: "SELECT resets_at FROM rate_limit_snapshots") == 1_700_000_000_000)
    }
}

@Test("ADP-CX: truncated zstd trailing frame cannot publish even a large valid prefix")
func codexPreflightsArchiveBeforeCommitting() throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let row = #"{"type":"event_msg","payload":{"type":"agent_message","message":"synthetic archive entry"}}"#
    let good = rawZstd(lines([box.header] + Array(repeating: row, count: 520)))
    let trailing = rawZstd(Data("synthetic trailing content".utf8))
    try box.write(good + trailing.dropLast(2), to: box.archive)
    #expect(throws: (any Error).self) { try box.importPath(box.archive) }
    #expect(try box.store.events(in: box.key).isEmpty)
    let fileID = try box.store.upsertFile(try box.discovered(box.archive), checkpoint: nil)
    #expect(try box.store.checkpoint(for: fileID) == nil)

    try box.write(good, to: box.archive, atomic: true)
    let imported = try box.importPath(box.archive)
    #expect(imported.completeLines == 521)
    #expect(imported.checkpoint.offset == Int64(good.count))
    #expect(imported.bytesRead == Int64(2 * good.count))
    #expect(try box.store.events(in: box.key).count == 520)
    let unchanged = try box.importPath(box.archive)
    #expect(unchanged.bytesRead == 0 && unchanged.completeLines == 0)
    #expect(try box.store.events(in: box.key).count == 520)
}

@Test("FR-SRC-2: a corrupt archive's diagnostic survives reopen and clears on a successful rescan")
func codexArchiveScanFailureIsDurable() async throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let good = rawZstd(lines([box.header,
        #"{"type":"event_msg","payload":{"type":"agent_message","message":"synthetic archive entry"}}"#]))
    try box.write(good, to: box.archive)
    let previous = try box.importPath(box.archive)
    try box.write(good + rawZstd(Data("synthetic trailing record".utf8)).dropLast(2), to: box.archive)
    try await JSONLSourceIndexing.run(source: box.source, authorizedRoot: box.root, adapter: CodexAdapter(),
                                     store: box.store, mode: .fullRescan) { _ in }
    let reopened = try AgentStore(databaseURL: box.index)
    var status = reopened.indexedSourceStatusUpdates().makeAsyncIterator()
    let failed = try #require(try await status.next()?.first)
    #expect(failed.failedFiles == 1 && failed.trackedFiles == 1 && failed.lastScanAt != nil)
    #expect(try reopened.checkpoint(for: previous.fileID) == previous.checkpoint)
    #expect(try reopened.events(in: box.key).count == 1)

    try box.write(good, to: box.archive, atomic: true)
    try await JSONLSourceIndexing.run(source: box.source, authorizedRoot: box.root, adapter: CodexAdapter(),
                                     store: reopened, mode: .fullRescan) { _ in }
    let refreshed = try AgentStore(databaseURL: box.index)
    var next = refreshed.indexedSourceStatusUpdates().makeAsyncIterator()
    let succeeded = try #require(try await next.next()?.first)
    #expect(succeeded.failedFiles == 0 && succeeded.indexedFiles == 1)
    #expect(try refreshed.checkpoint(for: previous.fileID)?.offset == Int64(good.count))
    #expect(try refreshed.events(in: box.key).count == 1)
}

@Test("ADP-CX / SPEC §10.6: next-model metadata cannot mix context measurements")
func codexContextCapacityDoesNotCarryAcrossModels() async throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let first = lines([
        box.header,
        #"{"type":"turn_context","payload":{"model":"synthetic-first"}}"#,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":1000,"last_token_usage":{"input_tokens":40,"cached_input_tokens":15,"output_tokens":10}}}}"#,
        #"{"type":"turn_context","payload":{"model":"synthetic-next"}}"#,
    ])
    try box.write(first, to: box.plain)
    _ = try box.importPath(box.plain)
    var updates = box.store.sessionContextUpdates(in: box.key).makeAsyncIterator()
    let old = try #require(try await updates.next() ?? nil)
    #expect(old.input == 40 && old.capacity == 1_000 && old.model == "synthetic-first")

    let more = lines([
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":60,"cached_input_tokens":10,"output_tokens":20}}}}"#,
    ])
    let file = try FileHandle(forWritingTo: box.root.appendingPathComponent(box.plain))
    try file.seekToEnd()
    try file.write(contentsOf: more)
    try file.close()
    _ = try box.importPath(box.plain)
    let current = try #require(try await updates.next() ?? nil)
    #expect(current.input == 60 && current.capacity == nil && current.model == "synthetic-next")
}

@Test("ADP-CX: a valid header later in a file cannot validate an invalid first line")
func codexRequiresSessionHeaderFirst() throws {
    let box = try CodexFixture()
    defer { box.remove() }
    try box.write(lines(["{}", box.header,
                         #"{"type":"event_msg","payload":{"type":"user_message","message":"ignored"}}"#]), to: box.plain)
    let result = try box.importPath(box.plain)
    #expect(result.checkpoint.unknownRecords == 1)
    #expect(try box.store.events(in: box.key).isEmpty)
    try box.store.databasePool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions") == 0)
    }
}

@Test("ADP-CX: converting an indexed plain rollout into an archive does not duplicate its rows or tokens")
func codexArchivedCopyKeepsTheSameAccounting() throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let source = lines([box.header,
        #"{"type":"event_msg","payload":{"type":"user_message","message":"合成归档验证"}}"#,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":3,"reasoning_output_tokens":2},"total_token_usage":{"total_tokens":13}}}}"#,
    ])
    try box.write(source, to: box.plain)
    let plain = try box.importPath(box.plain)
    let archive = rawZstd(source)
    try box.write(archive, to: box.archive)
    let compressed = try box.importPath(box.archive)
    #expect(plain.fileID != compressed.fileID)
    #expect(compressed.checkpoint.offset == Int64(archive.count))
    #expect(try box.store.events(in: box.key).map(\.text) == ["合成归档验证"])
    try box.store.databasePool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT sum(input_fresh+cache_read+output) FROM token_events") == 13)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM events_fts WHERE events_fts MATCH '归档'") == 1)
    }
}

@Test("ADP-2/4: compressed replay never treats its physical checkpoint as a JSONL offset")
func compressedReplayDoesNotExposeRawFileOffsets() throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let inflated = Data(repeating: 0x61, count: 1_048_600) + Data("\nfollowing synthetic row\n".utf8)
    let archive = rawZstd(inflated)
    try box.write(archive, to: box.archive)
    var file = try box.discovered(box.archive)
    file.parserVersion = 2
    let before = try JSONLFileImporter.importFile(file, authorizedRoot: box.root, encoding: .zstd, store: box.store) { line, _ in
        if line.sequence == 0 { #expect(line.isTruncated) }
        return .init(isUnknown: line.isTruncated)
    }
    #expect(before.checkpoint.offset == Int64(archive.count))

    file.parserVersion = 3
    let after = try JSONLFileImporter.importFile(file, authorizedRoot: box.root, encoding: .zstd, store: box.store) { line, context in
        #expect(context.replayedPrefix == nil)
        #expect(line.readOverflow == nil)
        if line.sequence == 0 {
            #expect(line.isTruncated && line.endOffset == 1_048_601)
        } else {
            #expect(String(decoding: line.bytes, as: UTF8.self) == "following synthetic row")
        }
        return .init(isUnknown: line.isTruncated)
    }
    #expect(after.completeLines == 2 && after.checkpoint.unknownRecords == 1)
    #expect(after.checkpoint.offset == Int64(archive.count))
    #expect(after.checkpoint.parserVersion == 3)
}

@Test("FR-STO-1: one-shot rescan rereads unchanged compressed sources without duplicating usage")
func fullRescanReplaysAnUnchangedCompressedSource() async throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let archived = rawZstd(lines([box.header,
        #"{"type":"event_msg","payload":{"type":"user_message","message":"Synthetic full rescan"}}"#,
        #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":10,"cached_input_tokens":4,"output_tokens":3},"total_token_usage":{"total_tokens":13}}}}"#,
    ]))
    try box.write(archived, to: box.archive)
    let previous = try box.importPath(box.archive)
    #expect(try box.importPath(box.archive).bytesRead == 0)
    let events = try box.store.events(in: box.key)
    let scans = AsyncStream<SourceIndexUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
    try await JSONLSourceIndexing.run(source: box.source, authorizedRoot: box.root,
                                     adapter: box.adapter, store: box.store, mode: .fullRescan) {
        scans.continuation.yield($0)
    }
    scans.continuation.finish()
    var progress = scans.stream.makeAsyncIterator()
    guard case .rescanned(let scan) = await progress.next() else {
        Issue.record("Expected one-shot scan completion without watching"); return
    }
    #expect(scan.checkedFiles == 1 && scan.failedFiles == 0 && scan.bytesRead == Int64(archived.count * 2))
    let saved = try #require(try box.store.checkpoint(for: previous.fileID))
    // Decoder state is JSON; a replay need not serialize keys in the same order.
    let state = try #require(saved.decoderState)
    let oldState = try #require(previous.checkpoint.decoderState)
    let decodedState = try #require(try JSONSerialization.jsonObject(with: state) as? NSDictionary)
    let decodedOldState = try #require(try JSONSerialization.jsonObject(with: oldState) as? NSDictionary)
    #expect(decodedState.isEqual(decodedOldState))
    var normalized = saved
    normalized.decoderState = oldState
    #expect(normalized == previous.checkpoint)
    #expect(try box.store.events(in: box.key) == events)
    #expect(try Data(contentsOf: box.root.appendingPathComponent(box.archive)) == archived)
    let usage = try await box.store.databasePool.read { db in
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events")
        let tokens = try Int.fetchOne(db, sql: "SELECT sum(input_fresh+cache_read+output) FROM token_events")
        return (count, tokens)
    }
    #expect(usage.0 == 1 && usage.1 == 13)
}

private struct CodexFixture {
    let directory: URL
    let root: URL
    let index: URL
    let store: AgentStore
    let source: Source
    let key = SessionKey(agent: .codex, nativeID: "00000000-0000-0000-0000-000000000088")
    let plain = "sessions/2026/01/01/rollout-synthetic.jsonl"
    let archive = "archived_sessions/rollout-synthetic.jsonl.zst"
    let adapter = CodexAdapter()

    var header: String {
        #"{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"00000000-0000-0000-0000-000000000088","cwd":"/synthetic/original","originator":"synthetic-cli","model_provider":"synthetic-provider"}}"#
    }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-fixture-\(UUID().uuidString)")
        root = directory.appendingPathComponent("synthetic-root")
        index = directory.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: index)
        var saved = Source(agent: .codex, label: "Synthetic", rootURL: root,
                           environmentRules: [.init(field: "model_provider", equals: "synthetic-provider", environment: "Synthetic rule")])
        saved.id = try store.upsertSource(saved)
        source = saved
    }

    func write(_ data: Data, to relative: String, atomic: Bool = false) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: atomic ? .atomic : [])
    }

    func discovered(_ path: String) throws -> SourceFile {
        try #require(try adapter.discover(in: source, authorizedRoot: root).first { $0.relativePath == path })
    }

    func importPath(_ path: String, store override: AgentStore? = nil) throws -> JSONLImportResult {
        try JSONLFileImporter.importFile(discovered(path), from: source, authorizedRoot: root,
                                         store: override ?? store, adapter: adapter)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private func lines(_ body: [String]) -> Data {
    Data((body.joined(separator: "\n") + "\n").utf8)
}

/// A raw single-segment zstd frame for synthetic fixtures (no external encoder).
private func rawZstd(_ data: Data) -> Data {
    func le(_ value: Int, bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    var frame = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0]) + le(data.count, bytes: 4)
    if data.isEmpty { return frame + le(1, bytes: 3) }
    let blockSize = 128 * 1024
    for start in stride(from: 0, to: data.count, by: blockSize) {
        let end = min(start + blockSize, data.count)
        frame.append(le(((end - start) << 3) | (end == data.count ? 1 : 0), bytes: 3))
        frame.append(data[start..<end])
    }
    return frame
}

@Test("ADP-7: verified compressed Codex output arrays can be read on demand without changing the archive")
func compressedToolOutputArrayIsReadOnly() throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let text = String(repeating: "synthetic array output ", count: 180)
    let raw = lines([box.header,
        #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"synthetic","output":[{"type":"input_text","text":"\#(text)"}]}}"#])
    let compressed = rawZstd(raw)
    try box.write(compressed, to: box.archive)
    _ = try box.store.setToolOutputArchiveLimit(.previewOnly)
    _ = try box.importPath(box.archive)
    let output = try #require(try box.store.events(in: box.key).first { $0.kind == .toolResult })
    #expect(output.text?.utf8.count == 2048)
    let details = try box.store.toolOutputDetails(in: box.key, eventKey: output.dedupeKey)
    #expect(details.archivedText == nil && details.hasOriginal)
    let registration = try #require(try box.store.registeredToolOutput(in: box.key, eventKey: output.dedupeKey))
    #expect(registration.origin.byteStart == nil)
    #expect(try ToolOutputReader.read(registration, authorizedRoot: box.root).text == text)
    #expect(try Data(contentsOf: box.root.appendingPathComponent(box.archive)) == compressed)
}

@Test("§11.2: a compressed Codex tool input is recovered from its verified logical frame")
func compressedToolInputIsReadOnly() throws {
    let box = try CodexFixture()
    defer { box.remove() }
    let input = String(repeating: "synthetic argument ", count: 200)
    let raw = lines([box.header,
        #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"synthetic","call_id":"synthetic","input":"\#(input)"}}"#])
    let compressed = rawZstd(raw)
    try box.write(compressed, to: box.archive)
    _ = try box.importPath(box.archive)
    let event = try #require(try box.store.events(in: box.key).first { $0.kind == .toolCall })
    #expect(event.text?.utf8.count == 2048)
    let registered = try #require(try box.store.registeredToolInput(in: box.key, eventKey: event.dedupeKey))
    #expect(registered.origin.byteStart == nil)
    #expect(try ToolInputReader.read(registered, authorizedRoot: box.root) == input)
    #expect(try Data(contentsOf: box.root.appendingPathComponent(box.archive)) == compressed)
}
