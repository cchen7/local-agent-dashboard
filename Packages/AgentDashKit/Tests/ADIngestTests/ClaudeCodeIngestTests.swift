import ADAdapters
import ADCore
import ADIngest
@testable import ADStore
import Foundation
import GRDB
import Testing

private let mainID = "00000000-0000-0000-0000-000000000001"
private let copyID = "00000000-0000-0000-0000-000000000002"

@Test("ADP-CC / SEC-3: discovery selects supported local transcripts without following symlinks")
func claudeDiscoveryKeepsTheSourceBoundary() throws {
    let box = try ClaudeFixture()
    defer { box.remove() }
    let child = "projects/synthetic/\(mainID)/subagents/agent-synthetic.jsonl"
    let legacy = "projects/synthetic/agent-legacy.jsonl"
    try box.write([], to: box.main)
    try box.write([], to: child)
    try box.write([], to: legacy)
    try box.write([], to: "history.jsonl")
    try box.write([], to: "projects/synthetic/\(mainID)/tool-results/irrelevant.jsonl")
    let external = box.directory.appendingPathComponent("external.jsonl")
    try Data("outside".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(at: box.root.appendingPathComponent(box.copy),
                                                withDestinationURL: external)
    let files = try box.adapter.discover(in: box.source, authorizedRoot: box.root)
    #expect(Set(files.map(\.relativePath)) == [box.main, child, legacy, "history.jsonl"])
    #expect(files.filter { $0.role == .subagent }.count == 2)
    #expect(files.allSatisfy { $0.sourceID == box.source.id && $0.parserVersion == ClaudeCodeAdapter.parserVersion })

    let resume = box.adapter.resumeCommand(for: .init(key: box.key, sourceID: 1, environment: "Test",
                                                     cwd: "/synthetic/project's folder"))
    #expect(resume == #"cd '/synthetic/project'\''s folder' && claude --resume 00000000-0000-0000-0000-000000000001"#)
}

@Test("ADP-CC: repeated and copied responses keep exact cumulative cache-inclusive token totals")
func claudeGoldenUsageAndTranscript() throws {
    let box = try ClaudeFixture()
    defer { box.remove() }
    let split = ["ephemeral_5m_input_tokens": 2, "ephemeral_1h_input_tokens": 1]
    let user: [String: Any] = ["type": "user", "uuid": "synthetic-prompt", "sessionId": mainID,
        "cwd": "/synthetic/original", "gitBranch": "demo", "version": "0.0-synthetic",
        "timestamp": "2026-01-01T00:00:00Z", "message": ["content": "修复登录问题"]]
    func usage(_ output: Int) -> [String: Any] {
        ["input_tokens": 11, "cache_read_input_tokens": 7, "cache_creation_input_tokens": 3,
         "cache_creation": split, "output_tokens": output]
    }
    let first = assistant("synthetic-answer-1", id: "synthetic-response-a",
                          usage: usage(4), content: [["type": "text", "text": "合成回复"]])
    let update = assistant("synthetic-answer-2", id: "synthetic-response-a", usage: usage(6), content: [
        ["type": "thinking", "thinking": "private synthetic reasoning should not be indexed"],
        ["type": "tool_use", "name": "Synthetic", "id": "tool-1", "input": ["command": "synthetic check"]],
        ["type": "unknown-block", "text": "unrecognized synthetic payload"]
    ])
    let older = assistant("synthetic-answer-3", id: "synthetic-response-a", usage: usage(5))
    let tool: [String: Any] = ["type": "user", "uuid": "synthetic-tool", "sessionId": mainID,
        "message": ["content": [["type": "tool_result", "tool_use_id": "tool-1", "is_error": true,
                                 "content": String(repeating: "测", count: 800)]]]]
    let meta: [String: Any] = ["type": "user", "uuid": "synthetic-meta", "isMeta": true,
        "message": ["content": "injected synthetic context should not be indexed"]]
    var requestFallback = assistant("synthetic-answer-4", usage: ["input_tokens": 4, "output_tokens": 2])
    requestFallback["requestId"] = "synthetic-request-b"
    let uuidFallback = assistant("synthetic-answer-5",
        usage: ["input_tokens": 2, "cache_read_input_tokens": 1, "cache_creation_input_tokens": 4, "output_tokens": 3])
    try box.write([user, first, update, older, tool, meta, requestFallback, uuidFallback], to: box.main)
    let initial = try box.importPath(box.main, role: .session)
    #expect(initial.completeLines == 8)
    #expect(initial.checkpoint.unknownRecords == 1)

    let copyPrompt: [String: Any] = ["type": "user", "sessionId": copyID, "uuid": "synthetic-copy-prompt",
        "message": ["content": "New synthetic prompt"], "cwd": "/synthetic/continued"]
    try box.write([user, first, copyPrompt], to: box.copy)
    _ = try box.importPath(box.copy, role: .session)
    let events = try box.store.events(in: box.key)
    #expect(events.first?.text == "修复登录问题")
    #expect(events.allSatisfy { $0.timestamp == 1_767_225_600_000 })
    #expect(events.allSatisfy { !($0.text ?? "").contains("private synthetic reasoning") })
    #expect(events.allSatisfy { !($0.text ?? "").contains("injected synthetic context") })
    let result = try #require(events.first { $0.kind == .toolResult })
    #expect(result.text?.utf8.count == 2046)
    #expect(result.metadataJSON?.contains(#""is_error":true"#) == true)
    let copyEvents = try box.store.events(in: .init(agent: .claudeCode, nativeID: copyID))
    #expect(copyEvents.map(\.text) == ["New synthetic prompt"])
    try box.store.databasePool.read { db in
        let sum = try #require(try Row.fetchOne(db, sql: """
            SELECT count(*) AS n,sum(input_fresh) AS fresh,sum(cache_read) AS cached,
                sum(cache_write) AS short,sum(cache_write_1h) AS long,sum(output) AS produced
            FROM token_events
            """))
        #expect((sum["n"] as Int) == 3)
        // (11,7,2,1,6) + (4,0,0,0,2) + (2,1,4,0,3) = 43 tokens.
        let counts = TokenCounts(inputFresh: sum["fresh"], cacheRead: sum["cached"], cacheWrite: sum["short"],
                                 cacheWrite1h: sum["long"], output: sum["produced"])
        #expect(counts == TokenCounts(inputFresh: 17, cacheRead: 8, cacheWrite: 6, cacheWrite1h: 1, output: 11))
        #expect(counts.total == 43)
        let owner = try String.fetchOne(db, sql: """
            SELECT s.native_id FROM sessions s JOIN token_events t ON t.session_id=s.id
            WHERE t.dedupe_key='claude:response:synthetic-response-a'
            """)
        #expect(owner == mainID)
    }
}

@Test("ADP-CC: nested child links resolve when its parent is imported later and workspace survives append")
func claudeParentAndIncrementalMetadata() throws {
    let box = try ClaudeFixture()
    defer { box.remove() }
    let child = "projects/synthetic/\(mainID)/subagents/agent-synthetic.jsonl"
    try box.write([["type": "user", "uuid": "synthetic-child", "sessionId": mainID,
                    "cwd": "/synthetic/child", "message": ["content": "Child work"]]], to: child)
    _ = try box.importPath(child, role: .subagent)
    try box.write([["type": "user", "uuid": "synthetic-open", "sessionId": mainID, "cwd": "/synthetic/parent",
                    "gitBranch": "demo", "message": ["content": "Parent work"]]], to: box.main)
    _ = try box.importPath(box.main, role: .session)
    let reopened = try AgentStore(databaseURL: box.index)
    let append = Data("{\"type\":\"summary\",\"uuid\":\"synthetic-summary\",\"summary\":\"Updated work\"}\n".utf8)
    let handle = try FileHandle(forWritingTo: box.root.appendingPathComponent(box.main))
    try handle.seekToEnd()
    try handle.write(contentsOf: append)
    try handle.close()
    let replay = try box.importPath(box.main, role: .session, store: reopened)
    #expect(replay.bytesRead == Int64(append.count) && replay.completeLines == 1)
    #expect(try reopened.events(in: box.key).map(\.kind) == [.user, .summary])
    try reopened.databasePool.read { db in
        let parent = try #require(try Row.fetchOne(db, sql: "SELECT cwd,git_branch FROM sessions WHERE native_id=?", arguments: [mainID]))
        #expect((parent["cwd"] as String) == "/synthetic/parent")
        #expect((parent["git_branch"] as String) == "demo")
        let childLink = try Row.fetchOne(db, sql: """
            SELECT parent.native_id AS native, child.cwd
            FROM sessions child JOIN sessions parent ON child.parent_session_id=parent.id
            """)
        #expect((childLink?["native"] as String?) == mainID)
        #expect((childLink?["cwd"] as String?) == "/synthetic/child")
    }
}

@Test("ADP-CC: prompt history stays a prompt-history entry with its recorded workspace")
func claudePromptHistoryNormalization() throws {
    let box = try ClaudeFixture()
    defer { box.remove() }
    try box.write([["display": "历史合成提示", "project": "/synthetic/history", "timestamp": 1234]], to: "history.jsonl")
    _ = try box.importPath("history.jsonl", role: .promptHistory)
    let history = SessionKey(agent: .claudeCode, nativeID: "history:\(box.source.id ?? 0):/synthetic/history")
    let rows = try box.store.events(in: history)
    #expect(rows.map(\.text) == ["历史合成提示"])
    #expect(rows.map(\.kind) == [.promptHistory])
    #expect(rows.map(\.timestamp) == [1234])
}

private func assistant(_ uuid: String, id: String? = nil, usage: [String: Any],
                       content: [[String: Any]] = []) -> [String: Any] {
    var message: [String: Any] = ["content": content, "model": "claude-synthetic", "usage": usage]
    if let id { message["id"] = id }
    return ["type": "assistant", "uuid": uuid, "sessionId": mainID, "message": message]
}

private struct ClaudeFixture {
    let directory: URL
    let root: URL
    let index: URL
    let store: AgentStore
    let source: Source
    let adapter = ClaudeCodeAdapter()
    let main = "projects/synthetic/\(mainID).jsonl"
    let copy = "projects/synthetic/\(copyID).jsonl"
    let key = SessionKey(agent: .claudeCode, nativeID: mainID)

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("claude-fixture-\(UUID().uuidString)")
        root = directory.appendingPathComponent("synthetic-source")
        index = directory.appendingPathComponent("index.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: index)
        var saved = Source(agent: .claudeCode, label: "Synthetic", rootURL: root, environment: "Synthetic")
        saved.id = try store.upsertSource(saved)
        source = saved
    }

    func write(_ records: [[String: Any]], to file: String) throws {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines = Data()
        for record in records {
            lines.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
            lines.append(0x0A)
        }
        try lines.write(to: url)
    }

    func importPath(_ path: String, role: SourceFile.Role, store override: AgentStore? = nil) throws -> JSONLImportResult {
        let id = try #require(source.id)
        return try JSONLFileImporter.importFile(.init(sourceID: id, relativePath: path, role: role),
                                                from: source, authorizedRoot: root, store: override ?? store,
                                                adapter: adapter)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
