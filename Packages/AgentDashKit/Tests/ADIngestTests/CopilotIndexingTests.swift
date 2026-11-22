import ADAdapters
import ADCore
import ADIngest
@testable import ADStore
import GRDB
import Foundation
import Testing

@Test("ADP-CP: reconcile cumulative usage and unique per-call usage without counting child records twice")
func copilotUsageGolden() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-copilot-\(UUID().uuidString)")
    let root = temp.appendingPathComponent("source")
    let directory = root.appendingPathComponent("session-state/synthetic")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let url = directory.appendingPathComponent("events.jsonl")
    let initial = [
        #"{"type":"session.start","id":"s1","timestamp":"2020-01-01T00:00:00Z","data":{"sessionId":"synthetic","producer":"synthetic-cli","copilotVersion":"0.0","context":{"cwd":"/synthetic/O'Brien"}}}"#,
        #"{"type":"session.model_change","id":"m1","data":{"newModel":"synthetic-x"}}"#,
        #"{"type":"user.message","id":"u1","data":{"content":"Synthetic request","transformedContent":"Do not index this expansion"}}"#,
        #"{"type":"assistant.message","id":"a1","data":{"content":"Synthetic response"}}"#,
        #"{"type":"session.shutdown","id":"p1","data":{"modelMetrics":{"synthetic-x":{"usage":{"inputTokens":120,"cacheReadTokens":30,"cacheWriteTokens":10,"outputTokens":20,"reasoningTokens":6}}}}}"#,
    ].joined(separator: "\n") + "\n"
    let later = [
        #"{"type":"session.resume","id":"r1","data":{}}"#,
        #"{"type":"session.shutdown","id":"p1","data":{"modelMetrics":{"synthetic-x":{"usage":{"inputTokens":900,"outputTokens":900}}}}}"#,
        #"{"type":"session.usage_checkpoint","id":"old","data":{"modelMetrics":{"synthetic-x":{"usage":{"inputTokens":110,"cacheReadTokens":25,"cacheWriteTokens":8,"outputTokens":19,"reasoningTokens":5}}}}}"#,
        #"{"type":"session.usage_record","id":"call","data":{"modelId":"synthetic-x","usage":{"inputTokens":25,"cacheReadTokens":5,"cacheWriteTokens":4,"outputTokens":7,"reasoningTokens":2}}}"#,
        #"{"type":"session.usage_record","id":"call","data":{"modelId":"synthetic-x","usage":{"inputTokens":900,"outputTokens":900}}}"#,
        #"{"type":"session.usage_record","id":"child","agentId":"synthetic-child","data":{"modelId":"synthetic-x","usage":{"inputTokens":20,"outputTokens":10}}}"#,
        #"{"type":"session.shutdown","id":"p2","data":{"modelMetrics":{"synthetic-x":{"usage":{"inputTokens":160,"cacheReadTokens":42,"cacheWriteTokens":18,"outputTokens":32,"reasoningTokens":9}},"synthetic-y":{"usage":{"inputTokens":20,"cacheReadTokens":4,"cacheWriteTokens":1,"outputTokens":5,"reasoningTokens":1}}}}}"#,
        #"{"type":"tool.execution_start","id":"ts","data":{"toolCallId":"tool","toolName":"SyntheticTool","arguments":{}}}"#,
        #"{"type":"tool.execution_complete","id":"te","data":{"toolCallId":"tool","success":true,"result":{"content":"Synthetic output"}}}"#,
        #"{"type":"session.task_complete","id":"end","data":{"summary":"Synthetic progress","success":true}}"#,
    ].joined(separator: "\n") + "\n"
    try Data(initial.utf8).write(to: url)
    let index = temp.appendingPathComponent("index.sqlite")
    var store = try AgentStore(databaseURL: index)
    var source = Source(agent: .copilot, label: "Synthetic Copilot", rootURL: root)
    source.id = try store.upsertSource(source)
    let adapter = CopilotAdapter()
    let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    let key = SessionKey(agent: .copilot, nativeID: "synthetic")

    func importNow() throws {
        try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    }
    try importNow()
    #expect(try totals(in: store, session: key) == .init(inputFresh: 80, cacheRead: 30, cacheWrite: 10, output: 20, reasoning: 6))
    store = try AgentStore(databaseURL: index)

    let output = try FileHandle(forWritingTo: url)
    try output.seekToEnd()
    try output.write(contentsOf: Data(later.utf8))
    try output.close()
    try importNow()
    let golden = TokenCounts(inputFresh: 115, cacheRead: 46, cacheWrite: 19, output: 37, reasoning: 10)
    #expect(try totals(in: store, session: key) == golden)
    #expect(try totals(in: store, session: key).total == 217)
    let events = try store.events(in: key)
    #expect(events.filter { $0.kind == .user }.map(\.text) == ["Synthetic request"])
    #expect(events.contains { $0.kind == .toolResult && $0.toolName == "SyntheticTool" && $0.text == "Synthetic output" })
    #expect(events.contains { $0.kind == .summary && $0.text == "Synthetic progress" })
    let sessionKey = key
    let id = try #require(source.id)
    let session = SessionRecord(key: sessionKey, sourceID: id, environment: "Synthetic", cwd: "/synthetic/O'Brien")
    #expect(adapter.resumeCommand(for: session) == "cd '/synthetic/O'\\''Brien' && copilot --resume 'synthetic'")
    let safe = try store.searchIndex(SearchQuery.parse("Synthetic request"), scope: .init(now: 0, timeZone: .gmt))
    #expect(safe.groups.map(\.session) == [key])
    #expect(try store.searchIndex(SearchQuery.parse("expansion"), scope: .init(now: 0, timeZone: .gmt)).matchCount == 0)

    try Data((initial + later).utf8).write(to: url, options: .atomic)
    try importNow()
    #expect(try totals(in: store, session: key) == golden)
    #expect(try store.events(in: key) == events)
}

@Test("ADP-CP: replay v4 model-less call rows using the model explicitly recorded in usage")
func copilotReplaysNestedUsageModel() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-copilot-\(UUID().uuidString)")
    let root = temp.appendingPathComponent("source", isDirectory: true)
    let folder = root.appendingPathComponent("session-state/synthetic", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let stream = [
        #"{"type":"session.start","id":"start","timestamp":"2020-01-01T00:00:00Z","data":{"sessionId":"synthetic"}}"#,
        #"{"type":"session.usage_record","id":"before","timestamp":"2020-01-01T00:00:01Z","data":{"usage":{"model":"synthetic-inner","inputTokens":100,"cacheReadTokens":20,"outputTokens":5}}}"#,
        #"{"type":"session.shutdown","id":"snapshot","timestamp":"2020-01-01T00:00:02Z","data":{"modelMetrics":{"synthetic-inner":{"usage":{"inputTokens":100,"cacheReadTokens":20,"outputTokens":5}}}}}"#,
        #"{"type":"session.usage_record","id":"after","timestamp":"2020-01-01T00:00:03Z","data":{"usage":{"model":"synthetic-inner","inputTokens":30,"cacheReadTokens":10,"outputTokens":7}}}"#,
    ]
    try Data((stream.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("events.jsonl"))
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .copilot, label: "Synthetic Copilot", rootURL: root)
    source.id = try store.upsertSource(source)
    let sourceID = try #require(source.id)
    let adapter = CopilotAdapter()
    let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    let fileID = try store.upsertFile(file, checkpoint: nil)
    let reader = try SourceFileReader(root: root, relativePath: file.relativePath)
    let saved = try reader.snapshot()
    let key = SessionKey(agent: .copilot, nativeID: "synthetic")
    let old = Checkpoint(inode: saved.inode, size: saved.size, offset: saved.size, parserVersion: 4,
        sequence: 3, previousTimestamp: 1_577_836_803_000, device: saved.device,
        modificationTimeNS: saved.modificationTimeNS)
    try store.commitFileBatch([
        .session(.init(key: key, sourceID: sourceID, fileID: fileID, environment: "Synthetic")),
        .copilotUsageSnapshot(.init(session: key, model: "synthetic-inner", sequence: 2, timestamp: 1_577_836_802_000,
            counts: .init(inputFresh: 80, cacheRead: 20, output: 5),
            dedupeKey: "cp:9:synthetic:id:8:snapshot:checkpoint:synthetic-inner")),
    ], for: fileID, from: nil, to: old)
    #expect(try totals(in: store, session: key).total == 105)
    let rebuilt = try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    #expect(rebuilt.completeLines == 4)
    #expect(try totals(in: store, session: key) == .init(inputFresh: 100, cacheRead: 30, output: 12))
    let usage = try store.databasePool.read { db in
        try Row.fetchAll(db, sql: "SELECT model,precision,ts FROM token_events ORDER BY ts")
    }
    #expect(usage.map { $0["model"] as String } == ["synthetic-inner", "synthetic-inner"])
    #expect(usage.map { $0["precision"] as String } == ["call", "call"])
    #expect(usage.map { $0["ts"] as Int64 } == [1_577_836_801_000, 1_577_836_803_000])
    _ = try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, replay: true,
                                        store: store, adapter: adapter)
    #expect(try totals(in: store, session: key).total == 142)
}

private func totals(in store: AgentStore, session: SessionKey) throws -> TokenCounts {
    try store.databasePool.read { db in
        let row = try #require(try Row.fetchOne(db, sql: """
            SELECT sum(input_fresh) AS fresh,sum(cache_read) AS cached,sum(cache_write) AS written,
                   sum(output) AS output,sum(reasoning) AS reasoning
            FROM token_events t JOIN sessions s ON s.id=t.session_id WHERE s.agent=? AND s.native_id=?
            """, arguments: [session.agent.rawValue, session.nativeID]))
        return TokenCounts(inputFresh: row["fresh"], cacheRead: row["cached"], cacheWrite: row["written"],
                           output: row["output"], reasoning: row["reasoning"])
    }
}
