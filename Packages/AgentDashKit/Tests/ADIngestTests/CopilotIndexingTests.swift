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

enum CopilotCoverageCase: CaseIterable, Sendable {
    case priorSnapshot, priorSnapshotWithNamedCalls, smallFirst, largeFirst

    var stream: (prefix: [String], shutdown: String, expected: Int64, anonymous: Int64) {
        let early = #"{"type":"session.usage_checkpoint","id":"early","timestamp":"2020-01-01T00:00:01Z","data":{"modelMetrics":{"a":{"usage":{"inputTokens":80,"outputTokens":20}},"b":{"usage":{"inputTokens":0,"outputTokens":0}}}}}"#
        let named = #"{"type":"session.usage_record","id":"named","timestamp":"2020-01-01T00:00:02Z","data":{"modelId":"a","usage":{"inputTokens":16,"outputTokens":4}}}"#
        let flat = #"{"type":"session.usage_checkpoint","id":"flat","timestamp":"2020-01-01T00:00:03Z","data":{"modelMetrics":{"a":{"usage":{"inputTokens":80,"outputTokens":20}}}}}"#
        func call(_ id: String, at seconds: Int, input: Int, output: Int) -> String {
            #"{"type":"session.usage_record","id":"\#(id)","timestamp":"2020-01-01T00:00:0\#(seconds)Z","data":{"usage":{"inputTokens":\#(input),"outputTokens":\#(output)}}}"#
        }
        func shutdown(a: Int, aOut: Int, b: Int, bOut: Int) -> String {
            #"{"type":"session.shutdown","id":"end","timestamp":"2020-01-01T00:00:05Z","data":{"modelMetrics":{"a":{"usage":{"inputTokens":\#(a),"outputTokens":\#(aOut)}},"b":{"usage":{"inputTokens":\#(b),"outputTokens":\#(bOut)}}}}}"#
        }
        switch self {
        case .priorSnapshot:
            return ([early, call("large", at: 4, input: 80, output: 20)], shutdown(a: 80, aOut: 20, b: 80, bOut: 20), 200, 100)
        case .priorSnapshotWithNamedCalls:
            return ([early, named, flat, call("small", at: 4, input: 8, output: 2)], shutdown(a: 96, aOut: 24, b: 8, bOut: 2), 130, 10)
        case .smallFirst:
            return ([call("small", at: 3, input: 8, output: 2), call("large", at: 4, input: 80, output: 20)],
                    shutdown(a: 8, aOut: 2, b: 80, bOut: 20), 110, 110)
        case .largeFirst:
            return ([call("large", at: 3, input: 80, output: 20), call("small", at: 4, input: 8, output: 2)],
                    shutdown(a: 8, aOut: 2, b: 80, bOut: 20), 110, 110)
        }
    }
}

@Test("ADP-CP: use only uncredited snapshot capacity and retry ambiguous calls after a match",
      arguments: CopilotCoverageCase.allCases)
func copilotUsesUncreditedSnapshotCapacity(example: CopilotCoverageCase) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-copilot-\(UUID())")
    let root = temp.appendingPathComponent("source")
    let folder = root.appendingPathComponent("session-state/synthetic")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let url = folder.appendingPathComponent("events.jsonl")
    let start = #"{"type":"session.start","id":"start","timestamp":"2020-01-01T00:00:00Z","data":{"sessionId":"synthetic"}}"#
    let (prefix, shutdown, expected, unpricedCalls) = example.stream
    try Data(([start] + prefix).joined(separator: "\n").appending("\n").utf8).write(to: url)
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .copilot, label: "Synthetic", rootURL: root)
    source.id = try store.upsertSource(source)
    let adapter = CopilotAdapter()
    let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    let key = SessionKey(agent: .copilot, nativeID: "synthetic")
    @discardableResult
    func importNow(replay: Bool = false) throws -> JSONLImportResult {
        try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, replay: replay,
                                         store: store, adapter: adapter)
    }
    func checkUsage(in store: AgentStore) throws {
        #expect(try totals(in: store, session: key).total == expected)
        try store.databasePool.read { db in
            let total = try Int64.fetchOne(db, sql: "SELECT input_fresh+cache_read+cache_write+cache_write_1h+output FROM session_usage_rollup")
            #expect(total == expected)
            let calls = try Int64.fetchOne(db, sql: """
                SELECT sum(input_fresh+output) FROM token_events WHERE model IS NULL AND precision='call'
                  AND price_status='unpriced' AND ts IN (1577836803000,1577836804000)
                """)
            #expect(calls == unpricedCalls)
        }
    }
    try importNow()
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((shutdown + "\n").utf8))
    try handle.close()
    try importNow()
    try checkUsage(in: store)
    try importNow(replay: true)
    try checkUsage(in: store)

    let fresh = try AgentStore(databaseURL: temp.appendingPathComponent("fresh.sqlite"))
    var freshSource = source
    freshSource.id = try fresh.upsertSource(freshSource)
    let freshFile = try #require(try adapter.discover(in: freshSource, authorizedRoot: root).first)
    try JSONLFileImporter.importFile(freshFile, from: freshSource, authorizedRoot: root, store: fresh, adapter: adapter)
    try checkUsage(in: fresh)

    // Seed the surplus that was written by v7 before rederiving its stored snapshots.
    if example == .priorSnapshot || example == .smallFirst {
        let oldModel = example == .priorSnapshot ? "b" : "a"
        let input = example == .priorSnapshot ? 80 : 8
        let output = example == .priorSnapshot ? 20 : 2
        try store.databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO token_events(session_id,agent,model,ts,input_fresh,output,precision,dedupe_key)
                SELECT session_id,'copilot',model,ts,?,?,'checkpoint',dedupe_key
                FROM copilot_usage_snapshots WHERE model=? AND ts=1577836805000
                ON CONFLICT(dedupe_key) DO UPDATE SET input_fresh=excluded.input_fresh,output=excluded.output
                """, arguments: [input, output, oldModel])
            try db.execute(sql: "UPDATE source_files SET parser_version=7 WHERE rel_path=?", arguments: [file.relativePath])
        }
        #expect(try totals(in: store, session: key).total == expected + Int64(input + output))
        let upgraded = try importNow()
        #expect(upgraded.checkpoint.parserVersion == CopilotAdapter.parserVersion)
        try checkUsage(in: store)
    }
}

struct CopilotCompleteCoverageCase: Sendable, CustomTestStringConvertible {
    let calls: [Int]
    let a: Int
    let b: Int
    let complete: Bool
    var priorCredit = 0
    var earlierPartial = false

    var testDescription: String {
        "calls=\(calls), snapshot=[\(a), \(b)], covered=\(complete), priorCredit=\(priorCredit), earlierPartial=\(earlierPartial)"
    }

    static let reviewMatrix: [Self] = {
        let sizes = [10, 20, 30, 40, 50, 60]
        var cases: [Self] = []
        for i in sizes.indices {
            for j in sizes.indices where j > i {
                for k in sizes.indices where k > j {
                    let calls = [sizes[i], sizes[j], sizes[k]]
                    let total = calls.reduce(0, +)
                    var lowerSides: [Int: Int] = [:]
                    for mask in 1..<7 {
                        let a = calls.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element).reduce(0, +)
                        if a * 2 < total { lowerSides[a, default: 0] += 1 }
                    }
                    for (a, count) in lowerSides.sorted(by: { $0.key < $1.key }) where count == 1 {
                        cases.append(.init(calls: calls, a: a, b: total - a, complete: true))
                    }
                }
            }
        }
        return cases
    }()

    static let additional: [Self] = [
        .init(calls: [10, 10], a: 10, b: 10, complete: true), // more than one assignment, same whole-batch usage
        .init(calls: [30, 35, 40], a: 50, b: 55, complete: false), // same component totals, impossible assignment
        .init(calls: [40, 50, 60], a: 60, b: 90, complete: true, priorCredit: 5),
        .init(calls: [40, 50, 60], a: 60, b: 90, complete: true, earlierPartial: true),
    ]
}

@Test("ADP-CP: prove whole snapshot coverage without requiring a uniquely matchable first call",
      arguments: CopilotCompleteCoverageCase.reviewMatrix + CopilotCompleteCoverageCase.additional)
func copilotReconcilesWholeSnapshot(example: CopilotCompleteCoverageCase) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-copilot-\(UUID())")
    let root = temp.appendingPathComponent("source")
    let folder = root.appendingPathComponent("session-state/synthetic")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let url = folder.appendingPathComponent("events.jsonl")
    let index = temp.appendingPathComponent("index.sqlite")
    let start = #"{"type":"session.start","id":"start","timestamp":"2020-01-01T00:00:00Z","data":{"sessionId":"synthetic"}}"#
    let calls = example.calls.enumerated().map { i, tokens in
        #"{"type":"session.usage_record","id":"call-\#(i)","timestamp":"2020-01-01T00:00:0\#(i+1)Z","data":{"usage":{"inputTokens":\#(4*tokens/5),"outputTokens":\#(tokens/5)}}}"#
    }
    func snapshot(_ type: String, _ id: String, _ seconds: Int, _ a: Int, _ b: Int) -> String {
        #"{"type":"\#(type)","id":"\#(id)","timestamp":"2020-01-01T00:00:0\#(seconds)Z","data":{"modelMetrics":{"a":{"usage":{"inputTokens":\#(4*a/5),"outputTokens":\#(a/5)}},"b":{"usage":{"inputTokens":\#(4*b/5),"outputTokens":\#(b/5)}}}}}"#
    }
    let credit = example.priorCredit
    let a = example.a
    let end = snapshot("session.shutdown", "end", 5, a + credit, example.b)
    let before = credit > 0 ? [snapshot("session.usage_checkpoint", "opening", 0, credit, 0)] : []
    let partial = example.earlierPartial ? [snapshot("session.usage_checkpoint", "partial", 4, 5, 5)] : []
    try Data(([start] + before + calls + partial).joined(separator: "\n").appending("\n").utf8).write(to: url)
    let store = try AgentStore(databaseURL: index)
    var source = Source(agent: .copilot, label: "Synthetic", rootURL: root)
    source.id = try store.upsertSource(source)
    let adapter = CopilotAdapter()
    let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
    let key = SessionKey(agent: .copilot, nativeID: "synthetic")
    @discardableResult
    func importNow(replay: Bool = false) throws -> JSONLImportResult {
        try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, replay: replay, store: store, adapter: adapter)
    }
    let sum = Int64(example.calls.reduce(0, +))
    let expected = (example.complete ? sum : 2 * sum) + Int64(credit)
    try importNow()
    #expect(try totals(in: store, session: key).total == sum + Int64(credit) + (example.earlierPartial ? 10 : 0))
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((end + "\n").utf8))
    try handle.close()
    try importNow()
    let checkRows: (AgentStore) throws -> Void = { dbStore in
        try dbStore.databasePool.read { db in
            let total = try Int64.fetchOne(db, sql: "SELECT input_fresh+cache_read+cache_write+cache_write_1h+output FROM session_usage_rollup")
            #expect(total == expected)
            let calls = try Int64.fetchAll(db, sql: """
                SELECT ts FROM token_events WHERE model IS NULL AND precision='call' AND price_status='unpriced' ORDER BY ts
                """)
            #expect(calls == example.calls.indices.map { 1_577_836_800_000 + 1_000 * Int64($0+1) })
        }
    }
    try checkRows(store)
    guard example.calls == [40, 50, 60], a == 60, credit == 0, !example.earlierPartial else { return }
    try importNow(replay: true)
    try checkRows(store)

    let fresh = try AgentStore(databaseURL: temp.appendingPathComponent("fresh.sqlite"))
    var freshSource = source
    freshSource.id = try fresh.upsertSource(freshSource)
    let freshFile = try #require(try adapter.discover(in: freshSource, authorizedRoot: root).first)
    try JSONLFileImporter.importFile(freshFile, from: freshSource, authorizedRoot: root, store: fresh, adapter: adapter)
    try checkRows(fresh)

    // Seed v8's duplicate checkpoint rows and verify upgrading an unchanged file repairs them.
    try store.databasePool.write { db in
        try db.execute(sql: """
            INSERT INTO token_events(session_id,agent,model,ts,input_fresh,output,precision,dedupe_key)
            SELECT session_id,'copilot',model,ts,input_fresh,output,'checkpoint',dedupe_key FROM copilot_usage_snapshots
            WHERE ts=1577836805000 ON CONFLICT(dedupe_key) DO NOTHING
            """)
        try db.execute(sql: "UPDATE source_files SET parser_version=8 WHERE rel_path=?", arguments: [file.relativePath])
    }
    #expect(try totals(in: store, session: key).total == 300)
    let upgraded = try importNow()
    #expect(upgraded.checkpoint.parserVersion == CopilotAdapter.parserVersion)
    try checkRows(store)
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
