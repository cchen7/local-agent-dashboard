import ADCore
import Foundation
import GRDB
import Testing
@testable import ADStore

/// An opt-in exporter for the signed native benchmark. Nothing here is
/// linked into the app, and a caller cannot supply an output path.
@Test("NFR-10: export a verified one-million-row native repricing fixture",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_NATIVE_REPRICE_EXPORT"] != nil))
func exportNativeRepricingFixture() throws {
    let identifier = try #require(ProcessInfo.processInfo.environment["AGENTDASH_NATIVE_REPRICE_EXPORT"]
        .flatMap(UUID.init(uuidString:)))
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("agentdash-reprice-fixture-\(identifier.uuidString)", isDirectory: true)
    let files = FileManager.default
    try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    var complete = false
    defer { if !complete { try? files.removeItem(at: root) } }

    let index = root.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: index)
    // The million rows are spaced 100 ms apart. Keep the entire sequence
    // in the past while retaining the varied minute rollup workload.
    let origin = Int64(Date().timeIntervalSince1970 * 1_000) - 100_600_000
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic price workload",
        rootURL: root.appendingPathComponent("unused-source")))
    let key = SessionKey(agent: .codex, nativeID: "native-repricing")
    try store.write([.session(.init(key: key, sourceID: source, environment: "Synthetic",
                                    title: "Synthetic usage before a price change", startedAt: origin))])
    let basis = TokenRateBasis(reference: "native-repricing-old-quote", bytes: Data([1, 9]))
    _ = try store.activatePricing { input, _ in
        input.model == "synthetic-history" ? TokenQuote(microUSD: 19, status: .priced, basis: basis) : nil
    }
    try store.write([.tokens(.init(session: key, timestamp: origin, model: "synthetic-history",
                                   counts: .init(output: 3), dedupeKey: "native-repricing-history"))])
    try store.databasePool.write { db in
        let row = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE native_id=?", arguments: [key.nativeID]))
        try db.execute(sql: """
            WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000000)
            INSERT INTO token_events(session_id,agent,model,ts,input_fresh,cache_read,output,precision,dedupe_key)
            SELECT ?, 'codex', CASE WHEN n%5=0 THEN 'synthetic-added' ELSE 'synthetic-primary' END,
                   ?+n*100, 1+n%17,n%7,1+n%41, CASE WHEN n%23=0 THEN 'checkpoint' ELSE 'call' END,
                   'native-reprice-'||n
            FROM seq
            """, arguments: [row, origin])
        try UsageChartChanges.publish(db)
    }
    let proof = try store.databasePool.read { db in
        let aggregate = try Row.fetchOne(db, sql: """
            SELECT count(*) AS records,sum(input_fresh+cache_read+output) AS tokens,
                sum(CASE WHEN price_status='unpriced' THEN input_fresh+cache_read+output ELSE 0 END) AS unpriced,
                sum(cost_micro_usd) AS before,
                sum(CASE WHEN model='synthetic-history' THEN cost_micro_usd
                         WHEN model='synthetic-added' THEN (input_fresh+output)*3+cache_read
                         ELSE (input_fresh+output)*5+cache_read END) AS after
            FROM token_events
            """)
        let row = try #require(aggregate)
        let facts: [String: Int64] = ["records": row["records"], "tokens": row["tokens"], "unpriced": row["unpriced"],
                                     "before": row["before"], "after": row["after"], "origin": origin]
        try #require(facts["records"] == 1_000_001 && facts["before"] == 19 && (facts["after"] ?? 0) > 19)
        return facts
    }
    _ = try store.databasePool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    try store.databasePool.close()
    var manifest = proof
    let attributes = try files.attributesOfItem(atPath: index.path)
    manifest["bytes"] = try #require((attributes[.size] as? NSNumber)?.int64Value)
    try JSONEncoder().encode(manifest).write(to: root.appendingPathComponent("proof.json"), options: .withoutOverwriting)
    complete = true
}
