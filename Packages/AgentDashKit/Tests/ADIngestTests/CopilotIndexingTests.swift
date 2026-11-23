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

@Test("ADP-CP / FR-COST: preserve model-less calls and do not guess when two models can cover them",
      arguments: [false, true])
func copilotKeepsUnpricedCallWithoutSnapshotDoubleCount(ambiguous: Bool) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-copilot-\(UUID().uuidString)")
    let root = temp.appendingPathComponent("source")
    let folder = root.appendingPathComponent("session-state/synthetic")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let url = folder.appendingPathComponent("events.jsonl")
    let initial = [
        #"{"type":"session.start","id":"start","timestamp":"2020-01-01T00:00:00Z","data":{"sessionId":"synthetic"}}"#,
        #"{"type":"session.usage_record","id":"call","timestamp":"2020-01-01T00:00:01Z","data":{"usage":{"inputTokens":100,"cacheReadTokens":20,"outputTokens":20,"reasoningTokens":3}}}"#,
    ].joined(separator: "\n") + "\n"
    try Data(initial.utf8).write(to: url)
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .copilot, label: "Synthetic", rootURL: root)
    source.id = try store.upsertSource(source)
    let adapter = CopilotAdapter()
    let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    let key = SessionKey(agent: .copilot, nativeID: "synthetic")
    let first = try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    #expect(first.checkpoint.unknownRecords == 0)
    #expect(try totals(in: store, session: key) == .init(inputFresh: 80, cacheRead: 20, output: 20, reasoning: 3))
    let metric = #"{"usage":{"inputTokens":130,"cacheReadTokens":26,"outputTokens":27,"reasoningTokens":5}}"#
    let additional = ambiguous ? #","other-model":{"usage":{"inputTokens":103,"cacheReadTokens":20,"outputTokens":21,"reasoningTokens":3}}"# : ""
    let later = #"{"type":"session.usage_checkpoint","id":"sample","timestamp":"2020-01-01T00:00:02Z","data":{"modelMetrics":{"synthetic-model":"#
        + metric + additional + "}}}\n"
    let fileHandle = try FileHandle(forWritingTo: url)
    try fileHandle.seekToEnd()
    try fileHandle.write(contentsOf: Data(later.utf8))
    try fileHandle.close()
    _ = try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    let expected = ambiguous ? TokenCounts(inputFresh: 267, cacheRead: 66, output: 68, reasoning: 11)
        : TokenCounts(inputFresh: 104, cacheRead: 26, output: 27, reasoning: 5)
    #expect(try totals(in: store, session: key) == expected)
    try store.databasePool.read { db in
        let rows = try Row.fetchAll(db, sql: "SELECT model,precision,price_status,input_fresh,output FROM token_events ORDER BY ts,model")
        #expect(rows.count == (ambiguous ? 3 : 2))
        #expect((rows.first?["model"] as String?) == nil)
        #expect((rows.first?["price_status"] as String?) == "unpriced")
        #expect((rows.last?["precision"] as String?) == "checkpoint")
        #expect((rows.last?["input_fresh"] as Int64?) == (ambiguous ? 104 : 24))
        #expect((rows.last?["output"] as Int64?) == (ambiguous ? 27 : 7))
    }
    _ = try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, replay: true,
                                         store: store, adapter: adapter)
    #expect(try totals(in: store, session: key) == expected)
}

@Test("ADP-CP: model-less calls overlap a unique remainder in multi-model and later checkpoints",
      arguments: [false, true])
func reconcileCopilotAnonymousOverlappingCheckpoints(later: Bool) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-copilot-\(UUID())")
    let root = temp.appendingPathComponent("source")
    let folder = root.appendingPathComponent("session-state/synthetic")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let url = folder.appendingPathComponent("events.jsonl")
    let start = #"{"type":"session.start","id":"start","timestamp":"2020-01-01T00:00:00Z","data":{"sessionId":"synthetic"}}"#
    let named = #"{"type":"session.usage_record","id":"named","timestamp":"2020-01-01T00:00:01Z","data":{"modelId":"model-a","usage":{"inputTokens":8,"outputTokens":2}}}"#
    let call = #"{"type":"session.usage_record","id":"anonymous","timestamp":"2020-01-01T00:00:02Z","data":{"usage":{"inputTokens":100,"outputTokens":20}}}"#
    let small = #"{"type":"session.usage_checkpoint","id":"small","timestamp":"2020-01-01T00:00:03Z","data":{"modelMetrics":{"model-b":{"usage":{"inputTokens":50,"outputTokens":10}}}}}"#
    let cumulative = later
        ? #"{"type":"session.shutdown","id":"end","timestamp":"2020-01-01T00:00:04Z","data":{"modelMetrics":{"model-b":{"usage":{"inputTokens":130,"outputTokens":26}}}}}"#
        : #"{"type":"session.shutdown","id":"end","timestamp":"2020-01-01T00:00:04Z","data":{"modelMetrics":{"model-a":{"usage":{"inputTokens":8,"outputTokens":2}},"model-b":{"usage":{"inputTokens":100,"outputTokens":20}}}}}"#
    let provisional = later ? [start, call, small] : [start, named, call]
    try Data((provisional.joined(separator: "\n") + "\n").utf8).write(to: url)
    let index = temp.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: index)
    var source = Source(agent: .copilot, label: "Synthetic", rootURL: root)
    source.id = try store.upsertSource(source)
    let adapter = CopilotAdapter()
    let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    let key = SessionKey(agent: .copilot, nativeID: "synthetic")
    try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((cumulative + "\n").utf8))
    try handle.close()
    let reopened = try AgentStore(databaseURL: index)
    try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: reopened, adapter: adapter)
    #expect(try totals(in: reopened, session: key).total == (later ? 156 : 130))
    let window = try UsageWindow.make(.hour, now: 1_577_836_805_000, timeZone: .gmt)
    let report = try reopened.usage(window: window)
    #expect(report.totals.counts.total == (later ? 156 : 130))
    try reopened.databasePool.read { db in
        let anonymous = try #require(try Row.fetchOne(db, sql: """
            SELECT ts,model,price_status,input_fresh,output FROM token_events WHERE model IS NULL AND precision='call'
            """))
        #expect((anonymous["ts"] as Int64) == 1_577_836_802_000)
        #expect((anonymous["price_status"] as String) == "unpriced")
        #expect((anonymous["input_fresh"] as Int64) == 100)
        #expect((anonymous["output"] as Int64) == 20)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events WHERE precision='checkpoint'") == (later ? 1 : 0))
    }
    try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, replay: true,
                                     store: reopened, adapter: adapter)
    #expect(try totals(in: reopened, session: key).total == (later ? 156 : 130))

    // Reproduce the already stored v6 overcount. Replaying only duplicates
    // must rederive the checkpoint rows even when no calls or snapshots insert.
    let updated = try #require(try reopened.checkpoint(for: reopened.upsertFile(file, checkpoint: nil)))
    try reopened.databasePool.write { db in
        try db.execute(sql: "DELETE FROM token_events WHERE precision='checkpoint'")
        if later {
            try db.execute(sql: """
                INSERT INTO token_events(session_id,agent,model,ts,input_fresh,output,precision,dedupe_key)
                SELECT id,'copilot','model-b',1577836803000,50,10,'checkpoint','cp:9:synthetic:id:5:small:checkpoint:model-b'
                FROM sessions WHERE native_id='synthetic'
                """)
        }
        try db.execute(sql: """
            INSERT INTO token_events(session_id,agent,model,ts,input_fresh,output,precision,dedupe_key)
            SELECT id,'copilot','model-b',1577836804000,?,?,'checkpoint','cp:9:synthetic:id:3:end:checkpoint:model-b'
            FROM sessions WHERE native_id='synthetic'
            """, arguments: [later ? 80 : 100, later ? 16 : 20])
        try db.execute(sql: "UPDATE source_files SET parser_version=6 WHERE rel_path=?", arguments: [file.relativePath])
    }
    #expect(try totals(in: reopened, session: key).total == (later ? 276 : 250))
    let replayed = try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: reopened, adapter: adapter)
    #expect(replayed.checkpoint.offset == updated.offset && replayed.checkpoint.parserVersion == CopilotAdapter.parserVersion)
    #expect(try totals(in: reopened, session: key).total == (later ? 156 : 130))
}

@Test("ADP-CP: replay v5/v6 removes only a recovered same-file anonymous usage placeholder",
      arguments: [5, 6])
func replayCopilotRecoveredUsageMatchesFreshTranscript(oldVersion: Int) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-copilot-\(UUID())")
    let root = temp.appendingPathComponent("source")
    let folder = root.appendingPathComponent("session-state/synthetic")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let url = folder.appendingPathComponent("events.jsonl")
    let body = [
        #"{"type":"session.start","id":"start","timestamp":"2020-01-01T00:00:00Z","data":{"sessionId":"synthetic"}}"#,
        #"{"type":"session.usage_record","id":"anonymous","timestamp":"2020-01-01T00:00:01Z","data":{"usage":{"inputTokens":100,"outputTokens":20}}}"#,
        #"{"type":"session.usage_record","id":"invalid","timestamp":"2020-01-01T00:00:02Z","data":{"usage":{"inputTokens":-1,"outputTokens":20}}}"#,
    ].joined(separator: "\n") + "\n"
    try Data(body.utf8).write(to: url)
    let index = temp.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: index)
    var source = Source(agent: .copilot, label: "Synthetic", rootURL: root)
    source.id = try store.upsertSource(source)
    let adapter = CopilotAdapter()
    let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    let key = SessionKey(agent: .copilot, nativeID: "synthetic")
    let id = try store.upsertFile(file, checkpoint: nil)
    let snapshot = try SourceFileReader(root: root, relativePath: file.relativePath).snapshot()
    let checkpoint = Checkpoint(inode: snapshot.inode, size: snapshot.size, offset: snapshot.size,
        parserVersion: oldVersion, sequence: 2, previousTimestamp: 1_577_836_802_000,
        device: snapshot.device, modificationTimeNS: snapshot.modificationTimeNS, unknownRecords: oldVersion == 5 ? 2 : 1)
    let staleKey = "cp:9:synthetic:id:9:anonymous:unknown"
    let stale = EventRecord(session: key, sequence: 1, timestamp: 1_577_836_801_000, kind: .unknown,
                            metadataJSON: #"{"unrecognized":true}"#, dedupeKey: staleKey)
    let owner = try #require(source.id)
    try store.commitFileBatch([.session(.init(key: key, sourceID: owner, fileID: id, environment: "Synthetic")),
                               .event(stale)], for: id, from: nil, to: checkpoint)
    #expect(try store.events(in: key).contains { $0.dedupeKey == staleKey })
    let migrated = try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    #expect(migrated.checkpoint.unknownRecords == 1)
    #expect(try totals(in: store, session: key).total == 120)
    let fresh = try AgentStore(databaseURL: temp.appendingPathComponent("fresh.sqlite"))
    source.id = try fresh.upsertSource(source)
    let freshFile = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    try JSONLFileImporter.importFile(freshFile, from: source, authorizedRoot: root, store: fresh, adapter: adapter)
    let migratedEvents = try #require(try store.transcriptPage(in: key)).events.filter { $0.kind == .unknown }
    let freshEvents = try #require(try fresh.transcriptPage(in: key)).events.filter { $0.kind == .unknown }
    #expect(migratedEvents.map(\.dedupeKey) == freshEvents.map(\.dedupeKey))
    #expect(migratedEvents.map(\.sequence) == [2])
    #expect(try store.events(in: key).allSatisfy { $0.dedupeKey != staleKey })
}

private func totals(in store: AgentStore, session: SessionKey) throws -> TokenCounts {
    try store.databasePool.read { db in
        let row = try #require(try Row.fetchOne(db, sql: """
            SELECT coalesce(sum(input_fresh),0) AS fresh,coalesce(sum(cache_read),0) AS cached,
                   coalesce(sum(cache_write),0) AS written,coalesce(sum(output),0) AS output,
                   coalesce(sum(reasoning),0) AS reasoning
            FROM token_events t JOIN sessions s ON s.id=t.session_id WHERE s.agent=? AND s.native_id=?
            """, arguments: [session.agent.rawValue, session.nativeID]))
        return TokenCounts(inputFresh: row["fresh"], cacheRead: row["cached"], cacheWrite: row["written"],
                           output: row["output"], reasoning: row["reasoning"])
    }
}
