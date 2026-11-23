import ADAdapters
import ADCore
import ADIngest
import ADStore
import Foundation
import Testing

@Test("§11.2 / SEC-3: normalized tool previews recover complete original inputs without indexing their tail",
      arguments: [AgentKind.claudeCode, .codex, .copilot])
func originalToolInputIsBoundedAndVerified(_ agent: AgentKind) throws {
    let fixture = try InputFixture(agent: agent)
    defer { fixture.remove() }
    let tail = "syntheticinputtail"
    let original = try fixture.log(payload: String(repeating: "s", count: 4096) + " " + tail)
    try original.write(to: fixture.file)
    try fixture.index()
    let event = try #require(try fixture.store.events(in: fixture.key).first { $0.kind == .toolCall })
    #expect(event.text?.contains(tail) == false && event.toolInput == nil)
    #expect(try fixture.store.searchIndex(SearchQuery.parse(tail),
              scope: .init(now: 1_770_000_000_000, timeZone: .gmt)).matchCount == 0)

    let registered = try #require(try fixture.store.registeredToolInput(in: fixture.key, eventKey: event.dedupeKey))
    #expect(registered.origin.format.agent == agent)
    #expect(try ToolInputReader.read(registered, authorizedRoot: fixture.root).contains(tail))
    #expect(try fixture.store.registeredToolInput(
        in: .init(agent: agent, nativeID: "other"), eventKey: event.dedupeKey) == nil)
    #expect(try fixture.store.setIndexSecretRedactionEnabled(true))
    #expect(try fixture.store.registeredToolInput(in: fixture.key, eventKey: event.dedupeKey)?.redact == true)

    let append = try FileHandle(forWritingTo: fixture.file)
    try append.seekToEnd()
    try append.write(contentsOf: Data("{}\n".utf8))
    try append.close()
    #expect(try ToolInputReader.read(registered, authorizedRoot: fixture.root).contains(tail))
    #expect(try Data(contentsOf: fixture.file) == original + Data("{}\n".utf8))

    let rewrite = try FileHandle(forWritingTo: fixture.file)
    try rewrite.truncate(atOffset: 0)
    try rewrite.write(contentsOf: fixture.log(payload: String(repeating: "x", count: 4096) + " " + tail))
    try rewrite.close()
    #expect(throws: ToolInputReadFailure.changedOrUnavailable) {
        try ToolInputReader.read(registered, authorizedRoot: fixture.root)
    }
    try fixture.store.removeRegisteredSource(try #require(fixture.source.id))
    #expect(try fixture.store.registeredToolInput(in: fixture.key, eventKey: event.dedupeKey) == nil)
}

@Test("§11.2 / SEC-7: an oversized JSON input is refused as a whole")
func oversizedStructuredToolInputIsNotClipped() throws {
    let fixture = try InputFixture(agent: .claudeCode)
    defer { fixture.remove() }
    try fixture.log(payload: String(repeating: "a", count: 263_000)).write(to: fixture.file)
    try fixture.index()
    let event = try #require(try fixture.store.events(in: fixture.key).first { $0.kind == .toolCall })
    let registered = try #require(try fixture.store.registeredToolInput(in: fixture.key, eventKey: event.dedupeKey))
    #expect(throws: ToolInputReadFailure.tooLarge) {
        try ToolInputReader.read(registered, authorizedRoot: fixture.root)
    }
}

@Test("§11.2: Copilot replay backfills input location on the same immutable event")
func copilotToolInputReplayPreservesIndexedPreview() throws {
    let fixture = try InputFixture(agent: .copilot)
    defer { fixture.remove() }
    try fixture.log(payload: String(repeating: "b", count: 4096)).write(to: fixture.file)
    let old = CopilotAdapter()
    let file = try #require(try old.discover(in: fixture.source, authorizedRoot: fixture.root).first)
    var legacy = file
    legacy.parserVersion = 2
    var decoder = try old.makeDecoder(for: legacy, in: fixture.source)
    _ = try JSONLFileImporter.importFile(legacy, authorizedRoot: fixture.root, store: fixture.store) { line, context in
        let decoded = decoder.decode(line, context: context)
        let records: [NormalizedRecord] = decoded.records.map { value in
            if case .event(var event) = value {
                event.toolInput = nil
                return .event(event)
            }
            return value
        }
        return .init(records: records, timestamp: decoded.timestamp, state: decoded.state, isUnknown: decoded.isUnknown,
                     recoveredOversizedRecord: decoded.recoveredOversizedRecord)
    }
    let before = try #require(try fixture.store.events(in: fixture.key).first { $0.kind == .toolCall })
    #expect(try fixture.store.registeredToolInput(in: fixture.key, eventKey: before.dedupeKey) == nil)
    try fixture.index()
    let after = try #require(try fixture.store.events(in: fixture.key).first { $0.kind == .toolCall })
    #expect(before == after)
    #expect(try fixture.store.registeredToolInput(in: fixture.key, eventKey: after.dedupeKey) != nil)
}

private struct InputFixture {
    let directory: URL
    let root: URL
    let file: URL
    let store: AgentStore
    let source: Source
    let key: SessionKey

    init(agent: AgentKind) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tool-input-\(UUID())")
        root = directory.appendingPathComponent("source")
        key = .init(agent: agent, nativeID: "00000000-0000-0000-0000-000000000065")
        switch agent {
        case .claudeCode: file = root.appendingPathComponent("projects/demo/\(key.nativeID).jsonl")
        case .codex: file = root.appendingPathComponent("sessions/2026/11/22/rollout-\(key.nativeID).jsonl")
        case .copilot: file = root.appendingPathComponent("session-state/\(key.nativeID)/events.jsonl")
        case .grokBuild: throw ToolInputReadFailure.changedOrUnavailable
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        var value = Source(agent: agent, label: "Synthetic", rootURL: root)
        value.id = try store.upsertSource(value)
        source = value
    }

    func log(payload: String) throws -> Data {
        let now = "2026-11-22T04:00:00Z"
        let args = ["command": "synthetic diagnostic", "payload": payload]
        let rows: [[String: Any]]
        switch key.agent {
        case .claudeCode:
            rows = [["type": "assistant", "uuid": "synthetic-input-line", "sessionId": key.nativeID, "timestamp": now,
                     "cwd": "/synthetic/input", "message": ["content": [["type": "tool_use", "id": "synthetic-call",
                     "name": "Bash", "input": args]]]]]
        case .codex:
            let argument = String(decoding: try JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]), as: UTF8.self)
            rows = [
                ["type": "session_meta", "timestamp": now, "payload": ["id": key.nativeID, "cwd": "/synthetic/input"]],
                ["type": "response_item", "timestamp": now, "payload": ["type": "function_call", "name": "exec_command",
                                                               "call_id": "synthetic-call", "arguments": argument]],
            ]
        case .copilot:
            rows = [
                ["type": "session.start", "id": "start", "timestamp": now, "data": ["sessionId": key.nativeID]],
                ["type": "tool.execution_start", "id": "tool", "timestamp": now,
                 "data": ["toolName": "bash", "toolCallId": "synthetic-call", "arguments": args]],
            ]
        case .grokBuild: throw ToolInputReadFailure.changedOrUnavailable
        }
        return try rows.reduce(into: Data()) {
            try $0.append(JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys]))
            $0.append(0x0A)
        }
    }

    func index() throws {
        switch key.agent {
        case .claudeCode: try index(ClaudeCodeAdapter())
        case .codex: try index(CodexAdapter())
        case .copilot: try index(CopilotAdapter())
        case .grokBuild: throw ToolInputReadFailure.changedOrUnavailable
        }
    }

    private func index<A: AgentAdapter>(_ adapter: A) throws {
        let input = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
        _ = try JSONLFileImporter.importFile(input, from: source, authorizedRoot: root, store: store, adapter: adapter)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
