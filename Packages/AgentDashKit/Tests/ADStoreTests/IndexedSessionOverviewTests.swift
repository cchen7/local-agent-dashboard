import ADCore
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("SPEC §10.3: overview is scoped to one session and follows file order across event-only updates",
      .timeLimit(.minutes(1)))
func sessionOverviewTracksIndexedProgress() async throws {
    let box = try OverviewFixture()
    defer { box.remove() }
    let missing = SessionKey(agent: .codex, nativeID: "missing-overview")
    var missingValues = box.store.sessionOverviewUpdates(in: missing).makeAsyncIterator()
    let noOverview = try await missingValues.next()
    #expect((noOverview ?? nil) == nil)

    try box.store.write([
        box.session(box.key), box.session(box.other),
        box.event(box.key, "s0", .summary, 1, 200, "earlier summary"),
        box.event(box.key, "s1", .summary, 2, 100, "latest summary"),
        box.event(box.key, "last-user", .user, 4, 45, "latest prompt"),
        box.event(box.key, "last-reply", .assistant, 5, 50, "latest reply"),
        box.event(box.key, "tool", .toolResult, 6, 60, "tool finished", tool: "Synthetic"),
        box.event(box.other, "other", .assistant, 100, 100, "outside the session"),
    ])
    var snapshots = box.store.sessionOverviewUpdates(in: box.key).makeAsyncIterator()
    let first = try await snapshots.next()
    let before = try #require(first ?? nil)
    #expect(before.summary == "latest summary")
    #expect(before.lastPrompt == "latest prompt")
    #expect(before.lastReply == "latest reply")
    #expect(before.recentActions == [.tool(kind: .toolResult, name: "Synthetic", text: "tool finished", timestamp: 60)])
    try box.store.write([box.event(box.key, "last-reply", .assistant, 5, 50, "edited reply")])
    let next = try await snapshots.next()
    let updated = try #require(next ?? nil)
    #expect(updated.lastReply == "edited reply")
    #expect(updated.summary == before.summary)
}

@Test("SPEC §10.2–3: overview bounds structured records and omits oversized text before display",
      .timeLimit(.minutes(1)))
func sessionOverviewBoundsActionsAndText() async throws {
    let box = try OverviewFixture()
    defer { box.remove() }
    try box.store.write([
        box.session(box.key),
        box.event(box.key, "tool", .toolResult, 4, 999, "fallback tool"),
        box.event(box.key, "overflow", .user, 5, 1000, String(repeating: "wide ", count: 210_000)),
    ])
    try await box.store.databasePool.write { db in
        let target = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE native_id='overview'"))
        try db.execute(sql: "UPDATE sessions SET latest_summary='agent metadata summary' WHERE id=?", arguments: [target])
        try db.execute(sql: """
            INSERT INTO session_keywords(session_id,term,weight) VALUES(?,'rotation',4),(?,'lookup',2)
            """, arguments: [target, target])
        for number in 1...12 {
            try db.execute(sql: """
                INSERT INTO file_touches(session_id,path,op,count,lines_added,lines_removed,last_ts)
                VALUES(?,?,'edit',?,?,1,?)
                """, arguments: [target, "src/\(number).swift", 20 - number, number, number * 10])
            try db.execute(sql: """
                INSERT INTO commands(session_id,ts,command,exit_code,duration_ms) VALUES(?,?,?,?,?)
                """, arguments: [target, number * 10 + 1, "synthetic \(number)", 0, number])
        }
    }
    var snapshots = box.store.sessionOverviewUpdates(in: box.key).makeAsyncIterator()
    let value = try await snapshots.next()
    let result = try #require(value ?? nil)
    #expect(result.summary == "agent metadata summary")
    #expect(result.lastPrompt == nil)
    #expect(result.topics.isEmpty)
    #expect(result.files.count == 10 && result.files.first?.path == "src/1.swift")
    #expect(result.commands.count == 10 && result.commands.first?.text == "synthetic 12")
    #expect(result.recentActions.map(\.time) == [999, 121, 120, 111, 110])
}

@Test("SPEC §10.3: live tool calls survive partial structured attribution, with only exact duplicates removed",
      .timeLimit(.minutes(1)))
func sessionOverviewMergesLiveToolActions() async throws {
    let box = try OverviewFixture()
    defer { box.remove() }
    try box.store.write([box.session(box.key)])
    try await box.store.databasePool.write { db in
        let target = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE native_id='overview'"))
        try db.execute(sql: """
            INSERT INTO file_touches(session_id,path,op,count,last_ts) VALUES(?,'/synthetic/change','edit',1,50);
            INSERT INTO commands(session_id,ts,command) VALUES(?,55,'synthetic original')
            """, arguments: [target, target])
    }
    var snapshots = box.store.sessionOverviewUpdates(in: box.key).makeAsyncIterator()
    let initial = try await snapshots.next()
    let before = try #require(initial ?? nil)
    try #require(before.recentActions.map(\.time) == [55, 50])
    try box.store.write([
        box.event(box.key, "duplicate-command", .toolCall, 1, 55, "synthetic original", tool: "Bash"),
        box.event(box.key, "same-time-repeat", .toolCall, 2, 55, "synthetic original", tool: "Bash"),
        box.event(box.key, "same-time-result", .toolResult, 3, 55, "synthetic original", tool: "Bash"),
        box.event(box.key, "duplicate-edit", .toolCall, 4, 50, "/synthetic/change", tool: "Edit"),
        box.event(box.key, "later", .toolCall, 5, 200, "synthetic later", tool: "Bash"),
    ])
    let update = try await snapshots.next()
    let latest = try #require(update ?? nil)
    #expect(latest.recentActions == [
        .tool(kind: .toolCall, name: "Bash", text: "synthetic later", timestamp: 200),
        before.recentActions[0],
        .tool(kind: .toolResult, name: "Bash", text: "synthetic original", timestamp: 55),
        .tool(kind: .toolCall, name: "Bash", text: "synthetic original", timestamp: 55),
        before.recentActions[1],
    ])
}

@Test("SPEC §10.2: summary and path-only topics are absent unless literal search can retrieve this session",
      .timeLimit(.minutes(1)))
func sessionOverviewOnlyShowsRetrievableTopics() async throws {
    let box = try OverviewFixture()
    defer { box.remove() }
    try box.store.write([
        box.session(box.key), box.session(box.other),
        box.event(box.key, "indexed-topic", .user, 1, 10, "syntheticeventtopic"),
        box.event(box.other, "external-topic", .assistant, 1, 10, "syntheticsummarytopic"),
        box.event(box.key, "history-topic", .promptHistory, 2, 11, "syntheticfiletopic"),
    ])
    try await box.store.databasePool.write { db in
        let id = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE native_id='overview'"))
        try db.execute(sql: "UPDATE sessions SET latest_summary='syntheticsummarytopic' WHERE id=?", arguments: [id])
        try db.execute(sql: """
            INSERT INTO file_touches(session_id,path,op,count,last_ts)
            VALUES(?,'/synthetic/syntheticfiletopic.swift','read',1,10)
            """, arguments: [id])
        try db.execute(sql: """
            INSERT INTO session_keywords(session_id,term,weight) VALUES
              (?,'syntheticsummarytopic',9),(?,'syntheticfiletopic',8),(?,'syntheticeventtopic',7)
            """, arguments: [id, id, id])
    }
    var values = box.store.sessionOverviewUpdates(in: box.key).makeAsyncIterator()
    let snapshot = try await values.next()
    let overview = try #require(snapshot ?? nil)
    #expect(overview.summary == "syntheticsummarytopic")
    #expect(overview.files.first?.path == "/synthetic/syntheticfiletopic.swift")
    #expect(overview.topics == ["syntheticeventtopic"])
    let scope = IndexedSearchScope(now: 100, timeZone: .gmt)
    func sessions(_ term: String) throws -> [SessionKey] {
        try box.store.searchIndex(SearchQuery.parse(SearchQuery.quotedLiteral(term)), scope: scope).groups.map(\.session)
    }
    #expect(try sessions("syntheticsummarytopic") == [box.other])
    #expect(try sessions("syntheticfiletopic").isEmpty)
    #expect(try sessions("syntheticeventtopic") == [box.key])

    try box.store.write([box.event(box.key, "later-topic", .toolCall, 3, 12, "syntheticfiletopic")])
    let update = try await values.next()
    let updated = try #require(update ?? nil)
    #expect(updated.topics == ["syntheticfiletopic", "syntheticeventtopic"])
    #expect(try sessions("syntheticfiletopic") == [box.key])
}

private struct OverviewFixture {
    let directory: URL
    let store: AgentStore
    let sourceID: Int64
    let key = SessionKey(agent: .codex, nativeID: "overview")
    let other = SessionKey(agent: .codex, nativeID: "other-overview")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-overview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic",
            rootURL: directory.appendingPathComponent("unused-source")))
    }

    func session(_ session: SessionKey) -> NormalizedRecord {
        .session(.init(key: session, sourceID: sourceID, environment: "Synthetic"))
    }

    func event(_ session: SessionKey, _ key: String, _ kind: EventKind, _ sequence: Int64,
               _ timestamp: Int64, _ text: String, tool: String? = nil) -> NormalizedRecord {
        .event(.init(session: session, sequence: sequence, timestamp: timestamp,
                     kind: kind, toolName: tool, text: text, dedupeKey: key))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
