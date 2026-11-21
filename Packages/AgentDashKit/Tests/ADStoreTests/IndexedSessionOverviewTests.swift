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
    #expect(result.topics == ["rotation", "lookup"])
    #expect(result.files.count == 10 && result.files.first?.path == "src/1.swift")
    #expect(result.commands.count == 10 && result.commands.first?.text == "synthetic 12")
    #expect(result.recentActions.map(\.time) == [121, 120, 111, 110, 101])
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
