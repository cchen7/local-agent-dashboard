import ADCore
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("§10.2 / FR-STO-1: document frequency changes once per session and survives a scoped clear")
func topicLedgerTracksExactDocumentFrequency() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topic-frequency-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let one = try store.upsertSource(.init(agent: .codex, label: "Synthetic A", rootURL: directory.appendingPathComponent("a")))
    let two = try store.upsertSource(.init(agent: .codex, label: "Synthetic B", rootURL: directory.appendingPathComponent("b")))
    let a = SessionKey(agent: .codex, nativeID: "synthetic-first")
    let b = SessionKey(agent: .codex, nativeID: "synthetic-second")
    let aEvent = NormalizedRecord.event(.init(session: a, sequence: 1, timestamp: 1, kind: .user,
                                            text: "alpha", dedupeKey: "synthetic:a"))
    try store.write([
        .session(.init(key: a, sourceID: one, environment: "Synthetic")),
        .session(.init(key: b, sourceID: two, environment: "Synthetic")),
        aEvent,
        .event(.init(session: b, sequence: 1, timestamp: 1, kind: .user, text: "beta", dedupeKey: "synthetic:b")),
    ])
    let scoring = IndexTopicScoring(counts: { input in
        guard case let .prompt(text) = input else { return [:] }
        return ["shared": 2, text: 1]
    }, top: { _, _, _ in [] })
    #expect(try store.applyTopicUpdates(store.prepareTopicUpdates(scoring: scoring, afterID: 0)) == 2)
    try store.write([aEvent])
    #expect(try store.prepareTopicUpdates(scoring: scoring, afterID: 0).isEmpty)
    let before = try await store.databasePool.read { db in
        try Int.fetchOne(db, sql: "SELECT df FROM term_df WHERE term='shared'")
    }
    #expect(before == 2)
    let clear = try store.prepareIndexClear(.source(one), hostHome: nil)
    #expect(try store.clearIndex(clear, hostHome: nil).removedSessions == 1)
    let after = try await store.databasePool.read { db in
        try Row.fetchAll(db, sql: "SELECT term,df FROM term_df ORDER BY term").map { row in
            "\(row["term"] as String):\(row["df"] as Int)"
        }
    }
    #expect(after == ["beta:1", "shared:1"])
}
