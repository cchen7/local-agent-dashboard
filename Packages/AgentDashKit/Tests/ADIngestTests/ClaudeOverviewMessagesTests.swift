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
