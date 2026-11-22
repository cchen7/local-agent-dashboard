import ADCore
import ADInsights
import ADStore
import Foundation
import Testing

@Test("§11.2: ordered rows use canonical project membership, keep isolated roots separate and never add hidden rows",
      .timeLimit(.minutes(1)))
func sessionGroupingPreservesScopedOrderAndUngroupedHistory() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("session-groups-\(UUID())")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let local = try store.upsertSource(.init(agent: .codex, label: "Host", rootURL: URL(fileURLWithPath: "/synthetic/.codex")))
    let mapped = try store.upsertSource(.init(agent: .copilot, label: "Mapped", rootURL: temp.appendingPathComponent("mapped"),
        environment: "Container", pathMappings: [.init(from: "/workspace", to: "/synthetic/repo")]))
    let remote = try store.upsertSource(.init(agent: .claudeCode, label: "Remote", rootURL: temp.appendingPathComponent("vm"),
                                              environment: "VM"))
    let promptFile = try store.upsertFile(.init(sourceID: local, relativePath: "history.jsonl", role: .promptHistory),
                                         checkpoint: nil)
    let a = SessionKey(agent: .codex, nativeID: "host-a")
    let b = SessionKey(agent: .copilot, nativeID: "mapped-b")
    let isolated = SessionKey(agent: .claudeCode, nativeID: "same-path-vm")
    let unrelated = SessionKey(agent: .codex, nativeID: "outside-page")
    let prompt = SessionKey(agent: .codex, nativeID: "prompt-history")
    let noPath = SessionKey(agent: .codex, nativeID: "no-project")
    try store.write([
        .session(.init(key: a, sourceID: local, environment: "Local", cwd: "/synthetic/repo", lastEventAt: 100)),
        .session(.init(key: b, sourceID: mapped, environment: "Container", cwd: "/workspace", lastEventAt: 50)),
        .session(.init(key: isolated, sourceID: remote, environment: "VM", cwd: "/synthetic/repo")),
        .session(.init(key: unrelated, sourceID: local, environment: "Local", cwd: "/synthetic/repo", lastEventAt: 900)),
        .session(.init(key: prompt, sourceID: local, fileID: promptFile, environment: "Local", cwd: "/synthetic/repo")),
        .session(.init(key: noPath, sourceID: local, environment: "Local")),
    ])

    var catalog = store.indexedProjectUpdates(hostHome: "/synthetic").makeAsyncIterator()
    let grouping = SessionProjectGrouping(projects: try #require(try await catalog.next()))
    let ranked = [isolated, b, prompt, a, noPath]
    let sections = grouping.sections(for: ranked)
    #expect(sections.map(\.sessions) == [[isolated], [b, a], [prompt, noPath]])
    #expect(sections[0].group.name == "repo" && sections[1].group.name == "repo")
    #expect(sections[0].id != sections[1].id)
    #expect(sections[0].group.context == "Remote · VM")
    #expect(sections[2].id == .ungrouped)
    #expect(grouping.sections(for: [a, b]).only?.sessions == [a, b])
    #expect(grouping.sections(for: []).isEmpty)
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
