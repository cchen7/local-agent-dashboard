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

@Test("§10.2 / DEV-110: a topic refresh writes only the terms that changed")
func topicRefreshWritesOnlyChangedTerms() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topic-diff-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: directory.appendingPathComponent("s")))
    let key = SessionKey(agent: .codex, nativeID: "synthetic-long-session")
    try store.write([.session(.init(key: key, sourceID: source, environment: "Synthetic"))])
    let sessionID = try #require(try store.databasePool.read { db in
        try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE native_id=?", arguments: [key.nativeID])
    })
    var terms = Dictionary(uniqueKeysWithValues: (0..<2_000).map { ("term\($0)", Double($0 % 7 + 1)) })
    try store.databasePool.write { db in try TopicLedger.replace(terms, sessionID: sessionID, db: db) }

    // One more message: a count grows, a term appears and one disappears.
    terms["term1", default: 0] += 1
    terms["fresh"] = 1
    terms["term2"] = nil
    let changes = try store.databasePool.write { db -> Int in
        let before = db.totalChangesCount
        try TopicLedger.replace(terms, sessionID: sessionID, db: db)
        return db.totalChangesCount - before
    }
    // Update, insert and delete, plus the two document-frequency triggers;
    // replacing every row wrote about 8,000 rows here.
    #expect(changes <= 6)
    try store.databasePool.read { db throws -> Void in
        let ledger = try Row.fetchAll(db, sql: "SELECT term,count FROM topic_term_counts WHERE session_id=?",
                                      arguments: [sessionID])
        #expect(Dictionary(uniqueKeysWithValues: ledger.map { ($0["term"] as String, $0["count"] as Double) }) == terms)
        let df = try Row.fetchAll(db, sql: "SELECT term,df FROM term_df")
        #expect(Dictionary(uniqueKeysWithValues: df.map { ($0["term"] as String, $0["df"] as Int) })
            == terms.mapValues { _ in 1 })
    }
}

