import ADCore
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("SPEC §11.3: projects combine local worktrees and explicitly mapped paths without mixing isolated environments",
      .timeLimit(.minutes(1)))
func projectsGroupOnlyCompatibleWorkspaces() async throws {
    let box = try ProjectFixture()
    defer { box.remove() }
    let codex = try box.source(.codex, label: "Codex")
    let claude = try box.source(.claudeCode, label: "Claude")
    let mapped = try box.source(.copilot, label: "Mapped", environment: "Container",
                               mappings: [.init(from: "/workspace", to: "~/code/client")])
    let isolated = try box.source(.grokBuild, label: "Isolated", environment: "VM")
    let path = "/host/code/client"
    let primary = box.session(.codex, codex, "client", path, activity: 100)
    let worktree = box.session(.claudeCode, claude, "worktree", path + "/.claude/worktrees/preview/Sources",
                               activity: 130, branch: "feature")
    let mappedSession = box.session(.copilot, mapped, "mapping", "/workspace/", activity: 110, environment: "Container")
    let unrelated = box.session(.grokBuild, isolated, "same-text", path, activity: 120, environment: "VM")
    let invalid = box.session(.codex, codex, "relative", "host/code/client", activity: 900)
    let composed = box.session(.codex, codex, "composed", "/host/é", activity: 30)
    let decomposed = box.session(.codex, codex, "decomposed", "/host/e\u{0301}", activity: 20)
    try box.store.write([primary, worktree, mappedSession, unrelated, invalid, composed, decomposed]
        .map(NormalizedRecord.session))

    var updates = box.store.indexedProjectUpdates(hostHome: "/host").makeAsyncIterator()
    let projects = try #require(try await updates.next())
    try #require(projects.count == 4)
    let shared = try #require(projects.first)
    #expect(shared.path == path && shared.name == "client")
    #expect(shared.sessions.map(\.session.id) == [worktree.key, mappedSession.key, primary.key])
    #expect(shared.sessions.first?.worktree == "preview")
    #expect(shared.agents == [.claudeCode, .codex, .copilot])
    #expect(shared.branches == ["feature"])
    #expect(projects[1].sessions.map(\.session.id) == [unrelated.key])
    #expect(projects[1].location == "Isolated · VM")
    #expect(projects[2].id != projects[3].id)
    #expect(!projects.flatMap(\.sessions).contains { $0.session.id == invalid.key })

    var changed = primary
    changed.lastEventAt = 140
    try box.store.write([.session(changed)])
    let refreshed = try #require(try await updates.next())
    #expect(refreshed.first?.id == shared.id)
    #expect(refreshed.first?.sessions.first?.session.id == primary.key)
}

@Test("SPEC §11.3: a recorded repository project groups sessions across distinct workspaces", .timeLimit(.minutes(1)))
func projectsHonorRecordedCatalogIdentity() async throws {
    let box = try ProjectFixture()
    defer { box.remove() }
    let source = try box.source(.codex, label: "Codex")
    let a = box.session(.codex, source, "a", "/synthetic/work/one", activity: 10)
    let b = box.session(.codex, source, "b", "/synthetic/work/two", activity: 20)
    try box.store.write([.session(a), .session(b)])
    try await box.store.databasePool.write { db in
        try db.execute(sql: """
            INSERT INTO projects(id,key,display_name,root_path,repo_url)
            VALUES(1,'https://example.invalid/team/app','Catalog App','/synthetic/repo','https://example.invalid/team/app');
            UPDATE sessions SET project_id=1
            """)
    }
    var updates = box.store.indexedProjectUpdates().makeAsyncIterator()
    let projects = try #require(try await updates.next())
    #expect(projects.count == 1)
    let project = try #require(projects.first)
    #expect(project.name == "Catalog App" && project.path == "/synthetic/repo")
    #expect(project.repositoryURL == "https://example.invalid/team/app")
    #expect(project.sessions.map(\.session.id) == [b.key, a.key])
}

@Test("SPEC §11.3: activity merges only the selected project's events, ranks by time and observes event-only writes",
      .timeLimit(.minutes(1)))
func projectTimelineStaysBoundedAndLive() async throws {
    let box = try ProjectFixture()
    defer { box.remove() }
    let codex = try box.source(.codex, label: "Codex")
    let claude = try box.source(.claudeCode, label: "Claude")
    let primary = box.session(.codex, codex, "client", "/synthetic/client", activity: 80)
    let peer = box.session(.claudeCode, claude, "peer", "/synthetic/client", activity: 70)
    let other = box.session(.codex, codex, "other", "/synthetic/other", activity: 90)
    try box.store.write([.session(primary), .session(peer), .session(other),
        box.event(primary.key, "earlier", 5, 15, .user),
        box.event(peer.key, "tool", 1, 25, .toolResult),
        box.event(primary.key, "later-tie", 1, 25, .assistant),
        box.event(primary.key, "unknown", 2, 60, .unknown),
        box.event(peer.key, "no-time", 2, 0, .assistant),
        box.event(other.key, "outside", 1, 99, .assistant)])
    var catalog = box.store.indexedProjectUpdates().makeAsyncIterator()
    let projects = try #require(try await catalog.next())
    let project = try #require(projects.first { $0.path == "/synthetic/client" })
    var updates = try box.store.indexedProjectActivityUpdates(project.activityScope, limit: 2).makeAsyncIterator()
    let before = try #require(try await updates.next())
    #expect(before.map(\.id) == ["later-tie", "tool"])
    #expect(before.map(\.session.agent) == [.codex, .claudeCode])
    #expect(before.last?.kind == .toolResult)

    try box.store.write([box.event(peer.key, "new-action", 3, 35, .assistant)])
    let after = try #require(try await updates.next())
    #expect(after.map(\.id) == ["new-action", "later-tie"])
    #expect(after.first?.session == peer.key)
    #expect(throws: IndexedProjectFailure.invalidLimit) {
        _ = try box.store.indexedProjectActivityUpdates(project.activityScope, limit: 0)
    }
}

private struct ProjectFixture {
    let directory: URL
    let store: AgentStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    }

    func source(_ agent: AgentKind, label: String, environment: String = "Local",
                mappings: [PathMapping] = []) throws -> Int64 {
        try store.upsertSource(.init(agent: agent, label: label,
            rootURL: directory.appendingPathComponent(agent.rawValue + "-" + label),
            environment: environment, pathMappings: mappings))
    }

    func session(_ agent: AgentKind, _ source: Int64, _ id: String, _ path: String, activity: Int64,
                 environment: String = "Local", branch: String? = nil) -> SessionRecord {
        .init(key: .init(agent: agent, nativeID: id), sourceID: source, environment: environment,
              cwd: path, title: id, startedAt: 1, lastEventAt: activity, gitBranch: branch)
    }

    func event(_ session: SessionKey, _ key: String, _ sequence: Int64,
               _ timestamp: Int64, _ kind: EventKind) -> NormalizedRecord {
        .event(.init(session: session, sequence: sequence, timestamp: timestamp,
                     kind: kind, text: key, dedupeKey: key))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
