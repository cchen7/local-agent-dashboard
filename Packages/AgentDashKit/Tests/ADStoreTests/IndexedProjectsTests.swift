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
    var updates = box.store.indexedProjectUpdates(hostHome: "/host").makeAsyncIterator()
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
    var catalog = box.store.indexedProjectUpdates(hostHome: "/host").makeAsyncIterator()
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

@Test("SPEC §11.3 / FR-SRC-2: a permission-only regrant keeps the project ID and all its sessions",
      .timeLimit(.minutes(1)))
func regrantDoesNotSplitLocalWorkspace() async throws {
    let box = try ProjectFixture()
    defer { box.remove() }
    let codex = try box.source(.codex, label: "Codex")
    let claude = try box.source(.claudeCode, label: "Claude")
    let custom = try box.store.upsertSource(.init(agent: .claudeCode, label: "Custom",
        rootURL: box.directory.appendingPathComponent("custom-root"), access: .bookmark(Data([0x33]))))
    let path = "/host/work/client"
    let primary = box.session(.codex, codex, "codex-client", path, activity: 100)
    let peer = box.session(.claudeCode, claude, "claude-client", path, activity: 110)
    let separate = box.session(.claudeCode, custom, "custom-client", path, activity: 90)
    try box.store.write([.session(primary), .session(peer), .session(separate)])
    let before = try await projects(in: box.store)
    try #require(before.count == 2)
    var source = try #require(try box.store.sources().first { $0.id == claude })
    source.access = .bookmark(Data([0x42])) // database metadata only; no bookmark is resolved
    #expect(try box.store.upsertSource(source) == claude)
    let updated = try await projects(in: box.store)
    #expect(updated == before)
    #expect(updated.first?.sessions.map(\.session.id) == [peer.key, primary.key])
    #expect(updated.last?.sessions.map(\.session.id) == [separate.key])
}

@Test("SPEC §11.3: normalize dot and repeated separators before grouping or applying path mappings",
      .timeLimit(.minutes(1)))
func projectsNormalizeUnambiguousWorkspaceSpellings() async throws {
    let box = try ProjectFixture()
    defer { box.remove() }
    let source = try box.source(.codex, label: "Codex")
    let vm = try box.source(.copilot, label: "Container", environment: "Container",
                            mappings: [.init(from: "/workspace/current", to: "/host/work/shared")])
    let clean = box.session(.codex, source, "clean", "/host/work/shared", activity: 50)
    let dot = box.session(.codex, source, "dot", "/host/work/./shared", activity: 40)
    let repeated = box.session(.codex, source, "repeated", "/host/work//shared", activity: 30)
    let triple = box.session(.codex, source, "triple", "///host/work/shared", activity: 25)
    let parent = box.session(.codex, source, "parent", "/host/work/side/../shared", activity: 20)
    let doubleSlash = box.session(.codex, source, "double-slash", "//host/work/shared", activity: 10)
    let mapped = box.session(.copilot, vm, "explicit", "/workspace//./current/", activity: 60, environment: "Container")
    try box.store.write([clean, dot, repeated, triple, parent, doubleSlash, mapped].map(NormalizedRecord.session))

    let grouped = try await projects(in: box.store)
    let host = try #require(grouped.first { $0.path == "/host/work/shared" })
    #expect(host.sessions.map(\.session.id) == [mapped.key, clean.key, dot.key, repeated.key, triple.key])
    #expect(grouped.count == 3)
    #expect(grouped.first { $0.path == "/host/work/side/../shared" }?.sessions.map(\.session.id) == [parent.key])
    #expect(grouped.first { $0.path == "//host/work/shared" }?.sessions.map(\.session.id) == [doubleSlash.key])
}

@Test("SPEC §11.3: unique host roots preserve mapped membership across partial catalog attribution",
      .timeLimit(.minutes(1)), arguments: [false, true])
func catalogAttributionKeepsMappedSessionsTogether(worktree: Bool) async throws {
    let box = try ProjectFixture()
    defer { box.remove() }
    let parent = "/host/work/client"
    let catalogRoot = worktree ? parent + "/.claude/worktrees/preview" : parent
    let conflictingRoot = worktree ? parent + "/.claude/worktrees/other" : "/host//work/client"
    let localAgent: AgentKind = worktree ? .claudeCode : .codex
    let mappedAgent: AgentKind = worktree ? .codex : .claudeCode
    let local = try box.source(localAgent, label: "Local")
    let mapped = try box.source(mappedAgent, label: "VM", environment: "VM",
                                mappings: [.init(from: "/workspace", to: parent)])
    let unrelated = try box.source(.copilot, label: "Unmapped", environment: "Remote")
    let a = box.session(localAgent, local, "host", catalogRoot, activity: 100)
    let b = box.session(mappedAgent, mapped, "mapped", "/workspace", activity: 90, environment: "VM")
    let c = box.session(.copilot, unrelated, "isolated", parent, activity: 80, environment: "Remote")
    try box.store.write([.session(a), .session(b), .session(c),
                         box.event(a.key, "host-event", 1, 25, .assistant),
                         box.event(b.key, "mapped-event", 1, 30, .assistant),
                         box.event(c.key, "isolated-event", 1, 40, .assistant)])
    let before = try await projects(in: box.store)
    #expect(before.count == 2 && before.first?.sessions.map(\.session.id) == [a.key, b.key])
    try await box.store.databasePool.write { db in
        try db.execute(sql: """
            INSERT INTO projects(id,key,display_name,root_path)
            VALUES(1,'https://example.invalid/team/app','Catalog Client',?);
            UPDATE sessions SET project_id=1 WHERE native_id='host'
            """, arguments: [catalogRoot])
    }

    let partial = try await projects(in: box.store)
    let shared = try #require(partial.first)
    #expect(partial.count == 2)
    #expect(shared.name == "Catalog Client" && shared.sessions.map(\.session.id) == [a.key, b.key])
    #expect(shared.path == catalogRoot)
    #expect(shared.sessions.first?.worktree == (worktree ? "preview" : nil))
    var updates = try box.store.indexedProjectActivityUpdates(shared.activityScope, limit: 3).makeAsyncIterator()
    let timeline = try #require(try await updates.next())
    #expect(timeline.map(\.id) == ["mapped-event", "host-event"])

    try await box.store.databasePool.write { db in
        try db.execute(sql: "UPDATE sessions SET project_id=1 WHERE native_id='mapped'")
    }
    #expect(try await projects(in: box.store) == partial)
    try await box.store.databasePool.write { db in
        try db.execute(sql: """
            INSERT INTO projects(id,key,display_name,root_path)
            VALUES(2,'https://example.invalid/team/other','Conflicting Root',?);
            UPDATE sessions SET project_id=NULL WHERE native_id='mapped'
            """, arguments: [conflictingRoot])
    }
    let ambiguous = try await projects(in: box.store)
    #expect(ambiguous.map { $0.sessions.map(\.session.id) } == [[a.key], [b.key], [c.key]])
}

private func projects(in store: AgentStore) async throws -> [IndexedProject] {
    var updates = store.indexedProjectUpdates(hostHome: "/host").makeAsyncIterator()
    return try #require(try await updates.next())
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
        let root = environment == "Local"
            ? URL(fileURLWithPath: "/host").appendingPathComponent(agent.defaultSourceDirectoryName)
            : directory.appendingPathComponent(agent.rawValue + "-" + label)
        return try store.upsertSource(.init(agent: agent, label: label,
            rootURL: root, environment: environment, pathMappings: mappings))
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
