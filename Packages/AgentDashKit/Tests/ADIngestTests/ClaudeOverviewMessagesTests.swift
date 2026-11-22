import ADAdapters
import ADCore
import ADIngest
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("SPEC §10.3: overview reconstructs Claude prompt and reply blocks, then follows newer records",
      .timeLimit(.minutes(1)))
func claudeOverviewPreservesMessageBlocks() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-overview-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let root = tmp.appendingPathComponent("source")
    let folder = root.appendingPathComponent("projects/demo")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let nativeID = "00000000-0000-0000-0000-000000000076"
    let path = "projects/demo/" + nativeID + ".jsonl"
    let fixture = root.appendingPathComponent(path)
    let input = [
        #"{"type":"user","uuid":"prompt-blocks","timestamp":10,"message":{"content":[{"type":"text","text":"First prompt "},{"type":"text","text":"continued."}]}}"#,
        #"{"type":"assistant","uuid":"reply-blocks","timestamp":20,"message":{"content":[{"type":"text","text":"First reply "},{"type":"text","text":"continued."}]}}"#,
    ]
    try Data((input.joined(separator: "\n") + "\n").utf8).write(to: fixture)
    let store = try AgentStore(databaseURL: tmp.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
    source.id = try store.upsertSource(source)
    let adapter = ClaudeCodeAdapter()
    let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    let key = SessionKey(agent: .claudeCode, nativeID: nativeID)
    var updates = store.sessionOverviewUpdates(in: key).makeAsyncIterator()
    let opening = try await updates.next()
    let first = try #require(opening ?? nil)
    #expect(first.lastPrompt == "First prompt continued.")
    #expect(first.lastReply == "First reply continued.")

    let handle = try FileHandle(forWritingTo: fixture)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((#"{"type":"assistant","uuid":"later-reply","timestamp":30,"message":{"content":"Newest distinct reply"}}"#
        + "\n").utf8))
    try handle.close()
    try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    let newValue = try await updates.next()
    let newest = try #require(newValue ?? nil)
    #expect(newest.lastPrompt == "First prompt continued.")
    #expect(newest.lastReply == "Newest distinct reply")
}

@Test("ADP-CC / SPEC §10.3: replay v3 and group assistant text across physical records without crossing response IDs",
      .timeLimit(.minutes(1)))
func claudeOverviewPreservesSplitResponseAcrossRecords() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-reply-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let root = tmp.appendingPathComponent("source")
    let folder = root.appendingPathComponent("projects/demo")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let nativeID = "00000000-0000-0000-0000-000000000077"
    let path = "projects/demo/\(nativeID).jsonl"
    let fixture = root.appendingPathComponent(path)
    let input = [
        #"{"type":"assistant","uuid":"initial-response","timestamp":9,"message":{"id":"separate","content":"Prior response"}}"#,
        #"{"type":"assistant","uuid":"answer-start","timestamp":20,"message":{"id":"split","content":[{"type":"text","text":"First "},{"type":"text","text":"part. "}]}}"#,
        #"{"type":"assistant","uuid":"tool-block","timestamp":18,"message":{"id":"split","content":[{"type":"tool_use","name":"Synthetic","id":"call","input":{}}]}}"#,
        #"{"type":"assistant","uuid":"answer-end","timestamp":10,"message":{"id":"split","model":"synthetic-context","content":"Closing fragment","usage":{"input_tokens":3,"cache_read_input_tokens":5,"cache_creation_input_tokens":7,"output_tokens":2}}}"#,
    ]
    let data = Data((input.joined(separator: "\n") + "\n").utf8)
    try data.write(to: fixture)
    let store = try AgentStore(databaseURL: tmp.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
    let sourceID = try store.upsertSource(source)
    source.id = sourceID
    let key = SessionKey(agent: .claudeCode, nativeID: nativeID)

    // Use the same v3 event keys with no message metadata, as stored before
    // this change. The current parser must backfill by replay, without duplicates.
    let oldFile = SourceFile(sourceID: sourceID, relativePath: path, role: .session, parserVersion: 3)
    let snapshot = try SourceFileReader(root: root, relativePath: path).snapshot()
    let old = Checkpoint(inode: snapshot.inode, size: snapshot.size, offset: snapshot.size, parserVersion: 3,
                         sequence: 3, previousTimestamp: 10, device: snapshot.device,
                         modificationTimeNS: snapshot.modificationTimeNS)
    let fileID = try store.upsertFile(oldFile, checkpoint: old)
    try store.write([
        .session(.init(key: key, sourceID: sourceID, fileID: fileID, environment: "Synthetic")),
        .event(.init(session: key, sequence: 1, timestamp: 20, kind: .assistant,
                     text: "First ", dedupeKey: "claude:event:answer-start:0")),
        .event(.init(session: key, sequence: 1, timestamp: 20, kind: .assistant,
                     text: "part. ", dedupeKey: "claude:event:answer-start:1")),
        .event(.init(session: key, sequence: 3, timestamp: 10, kind: .assistant,
                     text: "Closing fragment", dedupeKey: "claude:event:answer-end:0")),
    ])
    var updates = store.sessionOverviewUpdates(in: key).makeAsyncIterator()
    let before = try #require(try await updates.next() ?? nil)
    #expect(before.lastReply == "Closing fragment")

    let adapter = ClaudeCodeAdapter()
    let imported = try JSONLFileImporter.importFile(oldFile, from: source, authorizedRoot: root, store: store, adapter: adapter)
    #expect(imported.checkpoint.parserVersion == ClaudeCodeAdapter.parserVersion && imported.bytesRead == snapshot.size)
    let after = try #require(try await updates.next() ?? nil)
    #expect(after.lastReply == "First part. Closing fragment")
    #expect(try store.events(in: key).filter { $0.kind == .assistant }.count == 4)
    var contexts = store.sessionContextUpdates(in: key).makeAsyncIterator()
    let context = try #require(try await contexts.next() ?? nil)
    #expect(context.input == 15 && context.capacity == nil && context.model == "synthetic-context")

    let more = #"{"type":"assistant","uuid":"newest","timestamp":8,"message":{"id":"distinct","content":"New response"}}"# + "\n"
    let handle = try FileHandle(forWritingTo: fixture)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(more.utf8))
    try handle.close()
    try JSONLFileImporter.importFile(oldFile, from: source, authorizedRoot: root, store: store, adapter: adapter)
    let last = try #require(try await updates.next() ?? nil)
    #expect(last.lastReply == "New response")
}

@Test("ADP-CC: replay of only the retained copy restores reply metadata without replacing archived records",
      .timeLimit(.minutes(1)), arguments: [3, 4, 6])
func claudeOverviewBackfillsRetainedCopy(legacyVersion: Int) async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("claude-copy-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let root = tmp.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("projects/demo"),
                                            withIntermediateDirectories: true)
    let original = "00000000-0000-0000-0000-000000000081"
    let resumed = "00000000-0000-0000-0000-000000000082"
    let path = "projects/demo/\(resumed).jsonl"
    let fixture = root.appendingPathComponent(path)
    let records = [
        #"{"type":"assistant","sessionId":"\#(original)","uuid":"copy-start","timestamp":10,"message":{"id":"retained-response","content":"Opening ","usage":{"input_tokens":8,"cache_read_input_tokens":4,"cache_creation_input_tokens":2,"output_tokens":1}}}"#,
        #"{"type":"assistant","sessionId":"\#(original)","uuid":"copy-end","timestamp":20,"message":{"id":"retained-response","content":"closing.","usage":{"input_tokens":8,"cache_read_input_tokens":4,"cache_creation_input_tokens":2,"output_tokens":5}}}"#,
    ]
    let bytes = Data((records.joined(separator: "\n") + "\n").utf8)
    try bytes.write(to: fixture)
    let index = tmp.appendingPathComponent("upgraded.sqlite")
    let adapter = ClaudeCodeAdapter()
    var source = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
    let key = SessionKey(agent: .claudeCode, nativeID: original)
    let old: SourceFile
    do {
        let store = try AgentStore(databaseURL: index)
        let sourceID = try store.upsertSource(source)
        source.id = sourceID
        old = SourceFile(sourceID: sourceID, relativePath: path, role: .session, parserVersion: legacyVersion)
        var decoder = try adapter.makeDecoder(for: old, in: source)
        // Reproduce the missing ID in v3 and earlier replayed copies.
        let previous = try JSONLFileImporter.importFile(old, authorizedRoot: root, store: store) { frame, context in
            let decoded = try decoder.decode(frame, context: context)
            return .init(records: decoded.records.map {
                if case .event(var event) = $0, event.kind == .assistant {
                    event.metadataJSON = legacyVersion == 6 ? #"{"signal":"assistant.turn_end"}"# : nil
                    return .event(event)
                }
                return $0
            }, timestamp: decoded.timestamp, state: decoded.state, isUnknown: decoded.isUnknown)
        }
        #expect(previous.completeLines == 2 && previous.checkpoint.parserVersion == legacyVersion)
        let previousMetadata: String? = legacyVersion == 6 ? #"{"signal":"assistant.turn_end"}"# : nil
        #expect(try store.events(in: key).map(\.metadataJSON) == [previousMetadata, previousMetadata])
        if legacyVersion == 4 {
            // The original had different text and positions before it went away.
            try await store.databasePool.write { db in
                try db.execute(sql: "UPDATE events SET seq=seq+10, ts=ts+5")
                try db.execute(sql: "UPDATE events SET text='Archived opening ' WHERE dedupe_key='claude:event:copy-start:0'")
            }
        }
    }
    let store = try AgentStore(databaseURL: index)
    let before = try store.events(in: key)
    let rerun = try JSONLFileImporter.importFile(old, from: source, authorizedRoot: root, store: store, adapter: adapter)
    #expect(rerun.checkpoint.parserVersion == ClaudeCodeAdapter.parserVersion && rerun.completeLines == 2)
    let updated = try store.events(in: key)
    let metadata = try updated.map { row in
        let json = try #require(row.metadataJSON)
        return try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    }
    let expectedMetadata = legacyVersion == 6
        ? ["claude_message_id": "retained-response", "signal": "assistant.turn_end"]
        : ["claude_message_id": "retained-response"]
    #expect(metadata == [expectedMetadata, expectedMetadata])
    let previousMetadata: String? = legacyVersion == 6 ? #"{"signal":"assistant.turn_end"}"# : nil
    #expect(updated.map { var row = $0; row.metadataJSON = previousMetadata; return row } == before)
    #expect(try store.events(in: .init(agent: .claudeCode, nativeID: resumed)).isEmpty)
    var upgradedUpdates = store.sessionOverviewUpdates(in: key).makeAsyncIterator()
    let upgraded = try #require(try await upgradedUpdates.next() ?? nil)
    #expect(upgraded.lastReply == (legacyVersion == 4 ? "Archived opening closing." : "Opening closing."))

    let fresh = try AgentStore(databaseURL: tmp.appendingPathComponent("fresh.sqlite"))
    var freshSource = source
    freshSource.id = try fresh.upsertSource(freshSource)
    let freshFile = try #require(try adapter.discover(in: freshSource, authorizedRoot: root).first)
    try JSONLFileImporter.importFile(freshFile, from: freshSource, authorizedRoot: root, store: fresh, adapter: adapter)
    var freshUpdates = fresh.sessionOverviewUpdates(in: key).makeAsyncIterator()
    let freshOverview = try #require(try await freshUpdates.next() ?? nil)
    #expect(freshOverview.lastReply == "Opening closing.")
    if legacyVersion == 3 { #expect(try fresh.events(in: key) == updated) }

    // Replace only the synthetic fixture inode to force a second full replay.
    try bytes.write(to: fixture, options: .atomic)
    let again = try JSONLFileImporter.importFile(old, from: source, authorizedRoot: root, store: store, adapter: adapter)
    #expect(again.completeLines == 2)
    #expect(try store.events(in: key) == updated)
    for checked in [store, fresh] {
        try await checked.databasePool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.native_id, t.input_fresh, t.cache_read, t.cache_write, t.output
                FROM token_events AS t JOIN sessions AS s ON s.id=t.session_id
                """)
            let usage = try #require(rows.first)
            #expect(rows.count == 1)
            #expect((usage["native_id"] as String) == original)
            #expect((usage["input_fresh"] as Int) == 8 && (usage["cache_read"] as Int) == 4)
            #expect((usage["cache_write"] as Int) == 2 && (usage["output"] as Int) == 5)
        }
    }
}
