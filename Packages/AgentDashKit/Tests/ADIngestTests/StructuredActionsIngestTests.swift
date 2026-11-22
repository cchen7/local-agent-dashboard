import ADAdapters
import ADCore
import ADIngest
import ADStore
import Foundation
import Testing

@Test("§10.5: each supported adapter imports structured command, completion and file facts",
      arguments: [AgentKind.claudeCode, .codex, .copilot])
func structuredActionsReachOverviewThroughActualImporter(agent: AgentKind) async throws {
    let fixture = try StructuredLogFixture(agent: agent)
    defer { fixture.remove() }
    try fixture.write()
    try fixture.index()
    try fixture.index() // An unchanged authorized scan cannot duplicate evidence.
    var views = fixture.store.sessionOverviewUpdates(in: fixture.key).makeAsyncIterator()
    let view = try #require(try await views.next() ?? nil)
    #expect(view.commands.count == 1 && view.commands.first?.text == "synthetic diagnostic")
    #expect(view.files.count == 1 && view.files.first?.path == "/synthetic/edited.swift")
    #expect(view.files.first?.count == 1)
    switch agent {
    case .claudeCode:
        #expect(view.files.first?.added == 2 && view.files.first?.removed == 1)
        #expect(view.commands.first?.success == true && view.commands.first?.durationMS == 643)
        #expect(view.commands.first?.exitCode == nil)
    case .codex:
        #expect(view.files.first?.added == 2 && view.files.first?.removed == 1)
        #expect(view.commands.first?.exitCode == 7 && view.commands.first?.durationMS == 213)
        #expect(view.commands.first?.success == nil)
    case .copilot:
        #expect(view.files.first?.added == nil && view.files.first?.removed == nil)
        #expect(view.commands.first?.success == false && view.commands.first?.durationMS == nil)
        #expect(view.commands.first?.exitCode == nil)
    case .grokBuild:
        Issue.record("Unsupported source must not be in this test matrix.")
    }
}

private struct StructuredLogFixture {
    let directory: URL
    let root: URL
    let file: URL
    let store: AgentStore
    let source: Source
    let key: SessionKey

    init(agent: AgentKind) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("structured-log-\(UUID())")
        root = directory.appendingPathComponent("source")
        key = .init(agent: agent, nativeID: "00000000-0000-0000-0000-000000000072")
        switch agent {
        case .claudeCode: file = root.appendingPathComponent("projects/demo/\(key.nativeID).jsonl")
        case .codex: file = root.appendingPathComponent("sessions/2026/11/22/rollout-\(key.nativeID).jsonl")
        case .copilot: file = root.appendingPathComponent("session-state/\(key.nativeID)/events.jsonl")
        case .grokBuild: throw StoreError.invalidStoredValue
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        var saved = Source(agent: agent, label: "Synthetic", rootURL: root)
        saved.id = try store.upsertSource(saved)
        source = saved
    }

    func write() throws {
        let rows: [String]
        switch key.agent {
        case .claudeCode:
            rows = [
                #"{"timestamp":"2026-11-22T00:00:01Z","type":"assistant","uuid":"synthetic-edit","message":{"content":[{"type":"tool_use","id":"edit","name":"Edit","input":{"file_path":"/synthetic/edited.swift","old_string":"old\n","new_string":"new\nextra\n"}}]}}"#,
                #"{"timestamp":"2026-11-22T00:00:02Z","type":"assistant","uuid":"synthetic-command","message":{"content":[{"type":"tool_use","id":"cmd","name":"Bash","input":{"command":"synthetic diagnostic"}}]}}"#,
                #"{"timestamp":"2026-11-22T00:00:03Z","type":"user","uuid":"synthetic-result","toolUseResult":{"durationMs":643},"message":{"content":[{"type":"tool_result","tool_use_id":"cmd","is_error":false,"content":"synthetic result"}]}}"#,
            ]
        case .codex:
            rows = [
                #"{"timestamp":"2026-11-22T00:00:00Z","type":"session_meta","payload":{"id":"\#(key.nativeID)","cwd":"/synthetic"}}"#,
                #"{"timestamp":"2026-11-22T00:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","call_id":"edit","input":"*** Begin Patch\n*** Update File: /synthetic/edited.swift\n@@\n-old\n+new\n+extra\n*** End Patch"}}"#,
                #"{"timestamp":"2026-11-22T00:00:02Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"cmd","arguments":"{\"cmd\":\"synthetic diagnostic\"}"}}"#,
                #"{"timestamp":"2026-11-22T00:00:03Z","type":"event_msg","payload":{"type":"exec_command_end","call_id":"cmd","exit_code":7,"duration_ms":213}}"#,
                #"{"timestamp":"2026-11-22T00:00:04Z","type":"response_item","payload":{"type":"function_call_output","call_id":"cmd","output":"synthetic wrapper"}}"#,
            ]
        case .copilot:
            rows = [
                #"{"timestamp":"2026-11-22T00:00:00Z","id":"first","type":"session.start","data":{"sessionId":"\#(key.nativeID)"}}"#,
                #"{"timestamp":"2026-11-22T00:00:01Z","id":"edit","type":"tool.execution_start","data":{"toolName":"edit","toolCallId":"edit","arguments":{"path":"/synthetic/edited.swift"}}}"#,
                #"{"timestamp":"2026-11-22T00:00:02Z","id":"command","type":"tool.execution_start","data":{"toolName":"bash","toolCallId":"cmd","arguments":{"command":"synthetic diagnostic"}}}"#,
                #"{"timestamp":"2026-11-22T00:00:03Z","id":"result","type":"tool.execution_complete","data":{"toolCallId":"cmd","success":false,"result":{"content":"synthetic result"}}}"#,
            ]
        case .grokBuild:
            throw StoreError.invalidStoredValue
        }
        try Data((rows.joined(separator: "\n") + "\n").utf8).write(to: file)
    }

    func index() throws {
        switch key.agent {
        case .claudeCode: try index(ClaudeCodeAdapter())
        case .codex: try index(CodexAdapter())
        case .copilot: try index(CopilotAdapter())
        case .grokBuild: throw StoreError.invalidStoredValue
        }
    }

    private func index<A: AgentAdapter>(_ adapter: A) throws {
        let file = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
        _ = try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
