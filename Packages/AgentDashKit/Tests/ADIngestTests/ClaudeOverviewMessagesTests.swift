import ADAdapters
import ADCore
import ADIngest
import ADStore
import Foundation
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
        #"{"type":"assistant","uuid":"answer-end","timestamp":10,"message":{"id":"split","content":"Closing fragment"}}"#,
    ]
    let data = Data((input.joined(separator: "\n") + "\n").utf8)
    try data.write(to: fixture)
    let store = try AgentStore(databaseURL: tmp.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
    let sourceID = try store.upsertSource(source)
    source.id = sourceID
    let key = SessionKey(agent: .claudeCode, nativeID: nativeID)

    // Use the same v3 event keys with no message metadata, as stored before
    // this change. Checkpoint v4 must backfill by replay, without duplicates.
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
    #expect(imported.checkpoint.parserVersion == 4 && imported.bytesRead == snapshot.size)
    let after = try #require(try await updates.next() ?? nil)
    #expect(after.lastReply == "First part. Closing fragment")
    #expect(try store.events(in: key).filter { $0.kind == .assistant }.count == 4)

    let more = #"{"type":"assistant","uuid":"newest","timestamp":8,"message":{"id":"distinct","content":"New response"}}"# + "\n"
    let handle = try FileHandle(forWritingTo: fixture)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(more.utf8))
    try handle.close()
    try JSONLFileImporter.importFile(oldFile, from: source, authorizedRoot: root, store: store, adapter: adapter)
    let last = try #require(try await updates.next() ?? nil)
    #expect(last.lastReply == "New response")
}
