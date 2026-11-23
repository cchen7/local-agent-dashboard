import ADCore
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("§10.3, §10.5 / ADP-3: structured files aggregate and replay replaces an event instead of recounting it")
func structuredFilesDoNotDoubleCountOnReplay() async throws {
    let box = try ActionFixture()
    defer { box.remove() }
    let file = ToolFileAction(path: "synthetic/tracked.swift", operation: .edit, added: 3, removed: 1)
    let first = box.event("file", at: 80_000, action: .init(files: [file]))
    let second = box.event("file-2", at: 81_000, action: .init(files: [
        .init(path: file.path, operation: .edit, added: 2, removed: 2)
    ]))
    try box.store.write([first, second, first, second])
    var view = try await box.overview()
    let total = try #require(view.files.first)
    #expect(view.files.count == 1 && total.path == file.path)
    #expect(total.count == 2 && total.added == 5 && total.removed == 3 && total.timestamp == 81_000)
    #expect(view.recentActions.filter { if case .file = $0 { true } else { false } }.count == 2)
    let scope = IndexedSearchScope(now: 90_000, timeZone: .gmt)
    #expect(try box.store.searchIndex(SearchQuery.parse("file:tracked.swift"), scope: scope).matchCount > 0)

    try box.store.write([box.event("file-2", at: 81_000, action: .init(files: [
        .init(path: "synthetic/other.swift", operation: .read)
    ]))])
    view = try await box.overview()
    #expect(view.files.first { $0.path == file.path }?.count == 1)
    #expect(view.files.first { $0.path == file.path }?.timestamp == 80_000)
    #expect(view.files.first { $0.path.hasSuffix("other.swift") }?.added == nil)
    try box.store.write([box.event("file", at: 80_000, action: nil)])
    #expect(try await box.overview().files.map(\.path) == ["synthetic/other.swift"])
}

@Test("§10.3: an explicit command result is scoped to a unique call and keeps unknown evidence empty")
func structuredCommandMatchesOnlyExplicitUniqueCall() async throws {
    let box = try ActionFixture()
    defer { box.remove() }
    let meta = #"{"call_id":"synthetic-1"}"#
    let command = ToolActionEvidence(command: "synthetic command")
    try box.store.write([box.event("cmd", at: 80_000, seq: 1, meta: meta, action: command)])
    let pending = try await box.overview().commands.first
    #expect(pending?.exitCode == nil && pending?.durationMS == nil && pending?.success == nil)
    let completion = ToolActionEvidence(completion: .init(exitCode: 2, durationMS: 710, success: false))
    let result = box.event("outcome", at: 80_001, seq: 2, kind: .system, meta: meta, action: completion)
    try box.store.write([result, result])
    let finished = try #require(try await box.overview().commands.first)
    #expect(finished.exitCode == 2 && finished.durationMS == 710 && finished.success == false)
    try box.store.write([box.event("second-call", at: 80_002, seq: 3, meta: meta, action: command)])
    #expect(try await box.overview().commands.count == 2)
    #expect(try await box.overview().commands.allSatisfy { $0.exitCode == nil && $0.durationMS == nil && $0.success == nil })
}

@Test("SEC-8: redacting the index scrubs structured commands and reprojects structured file paths")
func structuredActionsFollowIndexRedaction() async throws {
    let box = try ActionFixture()
    defer { box.remove() }
    let token = "sk-synthetic_credential_12345"
    try box.store.write([
        box.event("file", at: 80_000, action: .init(files: [.init(path: "/synthetic/\(token)/file", operation: .read)])),
        box.event("cmd", at: 80_001, action: .init(command: "API_TOKEN=\(token)")),
    ])
    _ = try box.store.setIndexSecretRedactionEnabled(true)
    let safe = try await box.overview()
    #expect(safe.files.count == 1)
    #expect(safe.files.first?.path == "/synthetic/••••••/file")
    #expect(safe.commands.first?.text == "API_TOKEN=••••••")
}

@Test("ADP-CC / §10.5: a resume copy fills missing action evidence without reordering the original")
func claudeResumeEvidenceUsesOriginalEventIdentity() async throws {
    let box = try ActionFixture(agent: .claudeCode)
    defer { box.remove() }
    let id = "claude:event:synthetic-producer-id:0"
    try box.store.write([box.event(id, at: 80_000, seq: 10, action: nil)])
    let copy = box.event(id, at: 99_000, seq: 70, action: .init(files: [
        .init(path: "synthetic/resumed.swift", operation: .edit, added: 1, removed: 1)
    ]), ownership: .inherited)
    try box.store.write([copy, copy])
    let view = try await box.overview()
    #expect(view.files.first?.count == 1)
    #expect(view.files.first?.timestamp == 80_000)
    #expect(try box.store.events(in: box.key).first?.sequence == 10)
}

@Test("ADP-CP / FR-STO-1: replay fills immutable evidence and index clear removes all projections")
func copilotReplayAndClearKeepActionProjectionsConsistent() async throws {
    let box = try ActionFixture(agent: .copilot)
    defer { box.remove() }
    let before = box.event("recorded-command", at: 80_000, action: nil)
    try box.store.write([before])
    let expected = try box.store.events(in: box.key)
    let evidence = ToolActionEvidence(command: "synthetic command")
    let later = box.event("recorded-command", at: 81_000, action: evidence)
    let file = box.event("recorded-target", at: 80_001, action: .init(files: [
        .init(path: "/synthetic/file", operation: .read)
    ]))
    try box.store.write([later, later, file])
    let view = try await box.overview()
    #expect(view.commands.count == 1 && view.commands.first?.timestamp == 80_000)
    #expect(view.files.count == 1)
    #expect(try box.store.events(in: box.key).first == expected.first)
    let plan = try box.store.prepareIndexClear(.everything, hostHome: nil)
    #expect(try box.store.clearIndex(plan, hostHome: nil).removedSessions == 1)
    let retained = try await box.store.databasePool.read { db in
        try Int.fetchOne(db, sql: """
            SELECT (SELECT count(*) FROM file_touches)
                 + (SELECT count(*) FROM action_file_events)
                 + (SELECT count(*) FROM commands)
            """)
    }
    #expect(retained == 0)
}

private struct ActionFixture {
    let directory: URL
    let store: AgentStore
    let key: SessionKey

    init(agent: AgentKind = .codex) throws {
        key = SessionKey(agent: agent, nativeID: "synthetic-action-index")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("action-fixture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let source = try store.upsertSource(.init(agent: agent, label: "Synthetic", rootURL: directory))
        try store.write([.session(.init(key: key, sourceID: source, environment: "Test"))])
    }

    func event(_ id: String, at time: Int64, seq: Int64 = 1, kind: EventKind = .toolCall,
               meta: String? = nil, action: ToolActionEvidence?,
               ownership: RecordedSessionOwnership? = nil) -> NormalizedRecord {
        .event(.init(session: key, sequence: seq, timestamp: time, kind: kind, toolName: "synthetic",
                     text: "synthetic action", metadataJSON: meta, dedupeKey: id,
                     recordedOwnership: ownership, toolAction: action))
    }

    func overview() async throws -> IndexedSessionOverview {
        var snapshots = store.sessionOverviewUpdates(in: key).makeAsyncIterator()
        return try #require(try await snapshots.next() ?? nil)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
