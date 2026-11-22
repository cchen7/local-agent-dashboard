import ADCore
import Foundation
import GRDB
import Testing
@testable import ADStore

@Test("FR-SR: titles follow indexed prompt, agent and durable user precedence without changing transcripts",
      .timeLimit(.minutes(1)))
func sessionTitlePriorityAndPersistence() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("title-index-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: url)
    let source = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic", rootURL: folder))
    let key = SessionKey(agent: .claudeCode, nativeID: "title-session")
    let session = SessionRecord(key: key, sourceID: source, environment: "Local",
                                cwd: "/synthetic/title-project", startedAt: 1000, status: .waiting)
    func event(_ sequence: Int64, _ kind: EventKind, _ text: String) -> NormalizedRecord {
        .event(.init(session: key, sequence: sequence, timestamp: 1000+sequence, kind: kind,
                     text: text, dedupeKey: "synthetic:title:\(sequence)"))
    }
    func row(from store: AgentStore) async throws -> IndexedSession {
        var snapshots = store.indexedSessionUpdates().makeAsyncIterator()
        return try #require(try await snapshots.next()?.first { $0.id == key })
    }
    try store.write([
        .session(session),
        event(0, .user, " \n\t /clear"),
        event(1, .user, "<environment_context>injected"),
        event(2, .user, "/synthetic/work.swift is missing a test"),
        event(3, .user, "A second prompt"),
    ])
    let fallback = try await row(from: store)
    #expect(fallback.title == "/synthetic/work.swift is missing a test")
    #expect(fallback.titleSource == .firstPrompt)

    try store.write([event(4, .summary, "Indexed agent summary")])
    let agent = try await row(from: store)
    #expect(agent.title == "Indexed agent summary" && agent.titleSource == .agent)
    try await store.setCustomSessionTitle("  本地自定义标题  ", for: key)
    var replay = session
    replay.title = "New supplied title"
    try store.write([.session(replay)])

    let reopened = try AgentStore(databaseURL: url)
    let custom = try await row(from: reopened)
    #expect(custom.title == "本地自定义标题" && custom.titleSource == .user)
    let menu = try reopened.menuUsage(now: 2000, timeZone: .gmt)
    #expect(menu.sessions.first?.session.title == custom.title)
    var projects = reopened.indexedProjectUpdates(hostHome: "/synthetic").makeAsyncIterator()
    let project = try #require(try await projects.next()?.first)
    #expect(project.sessions.first?.session.title == custom.title)

    try await reopened.setCustomSessionTitle(nil, for: key)
    let automatic = try await row(from: reopened)
    #expect(automatic.title == "New supplied title" && automatic.titleSource == .agent)
    #expect(try reopened.transcriptPage(in: key)?.events.count == 5)
}

@Test("SEC-8: title writes and existing overrides follow the index redaction setting")
func sessionTitleValidationAndIndexRedaction() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("title-redaction-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try AgentStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: folder))
    let key = SessionKey(agent: .codex, nativeID: "title-redact")
    try store.write([.session(.init(key: key, sourceID: source, environment: "Local"))])
    await #expect(throws: SessionTitleFailure.invalidTitle) {
        try await store.setCustomSessionTitle("first\nsecond", for: key)
    }
    await #expect(throws: SessionTitleFailure.invalidTitle) {
        try await store.setCustomSessionTitle(String(repeating: "中", count: 81), for: key)
    }
    try await store.setCustomSessionTitle("API_TOKEN=synthetic-title-secret", for: key)
    #expect(try store.setIndexSecretRedactionEnabled(true))
    let existing = try await store.databasePool.read { db in
        try String.fetchOne(db, sql: "SELECT user_title FROM sessions")
    }
    #expect(existing == "API_TOKEN=••••••")
    try await store.setCustomSessionTitle("API_TOKEN=synthetic-future-title", for: key)
    let later = try await store.databasePool.read { db in
        try String.fetchOne(db, sql: "SELECT user_title FROM sessions")
    }
    #expect(later == existing)
}
