import ADCore
import ADPricing
import Foundation
import GRDB
import Testing
@testable import ADStore

private let february: Int64 = 1_769_904_000_000

@Test("FR-COST: new usage is priced, the historical sweep only fills unpriced rows, and corrections retain their rates")
func quoteAndBackfillStoredUsage() throws {
    try withQuoteStore { store, index in
        let session = try addQuoteSession(store, index: index, agent: .codex)
        let old = try TokenQuoteEngine.make(table: quoteTable(newRates: false))
        let initialSweep = try store.activatePricing(old)
        func event(_ key: String, _ amount: Int64, model: String? = "synthetic-primary",
                   precision: TokenPrecision = .call) -> TokenEvent {
            .init(session: session, timestamp: february, model: model,
                  counts: .init(output: amount), precision: precision, dedupeKey: key)
        }
        try store.write([
            .tokens(event("synthetic-original", 10)),
            .tokens(event("synthetic-approx", 8, precision: .checkpoint)),
            .tokens(event("synthetic-reprice", 3, model: "synthetic-added")),
            .tokens(event("synthetic-unmatched", 2, model: "synthetic-unknown")),
        ])
        let new = try TokenQuoteEngine.make(table: quoteTable(newRates: true))
        var next = Optional(try store.activatePricing(new))
        #expect(throws: StoreError.pricingSuperseded) { try store.backfillUnpriced(initialSweep) }
        var examined = 0, updated = 0
        while let cursor = next {
            let batch = try store.backfillUnpriced(cursor, limit: 1)
            examined += batch.examined; updated += batch.priced; next = batch.next
        }
        #expect(examined == 2 && updated == 1)
        #expect(try storedQuotes(store).map(\.amount) == [8, 10, 9, 0])
        #expect(try storedQuotes(store).map(\.status) == ["approx", "priced", "priced", "unpriced"])

        // A restart may no longer have the old table in memory.
        let reopened = try AgentStore(databaseURL: index)
        _ = try reopened.activatePricing(new)
        try reopened.write([.tokens(event("synthetic-original", 12)), .tokens(event("synthetic-new", 4))])
        #expect(try storedQuotes(reopened).map(\.amount) == [8, 20, 12, 9, 0])
        let clock = try UsageWindow.make(.hour, now: february + 60_000, timeZone: .gmt)
        let usage = try reopened.usage(window: clock)
        #expect(usage.totals.costMicroUSD == 49 && usage.totals.unpricedTokens == 2)
        #expect(usage.totals.counts.total == 29)
        #expect(try reopened.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM token_rate_bases")
        } == 3)
    }
}

@Test("FR-COST: a Claude ownership correction moves, rather than duplicates, a quote and its rollups")
func claudeOwnerCorrectionKeepsQuoteBasisAndMovesProject() throws {
    try withQuoteStore { store, index in
        let sourceID = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic",
                                                   rootURL: index.deletingLastPathComponent()))
        let copied = SessionKey(agent: .claudeCode, nativeID: "synthetic-copy")
        let original = SessionKey(agent: .claudeCode, nativeID: "synthetic-original")
        try store.write([
            .session(.init(key: copied, sourceID: sourceID, environment: "Synthetic")),
            .session(.init(key: original, sourceID: sourceID, environment: "Synthetic")),
        ])
        try store.databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO projects(id,key,display_name) VALUES(1,'copy','Synthetic Copy'),(2,'original','Synthetic Original');
                UPDATE sessions SET project_id=1 WHERE native_id='synthetic-copy';
                UPDATE sessions SET project_id=2 WHERE native_id='synthetic-original'
                """)
        }
        let eventKey = "synthetic-shared-response"
        func usage(_ owner: SessionKey, output: Int64, ownership: RecordedSessionOwnership? = nil) -> NormalizedRecord {
            .tokens(.init(session: owner, timestamp: february, model: "synthetic-primary",
                          counts: .init(inputFresh: 4, cacheRead: 3, output: output, reasoning: 2),
                          dedupeKey: eventKey, recordedOwnership: ownership))
        }

        _ = try store.activatePricing(TokenQuoteEngine.make(table: quoteTable(newRates: false, cacheRead: 0)))
        try store.write([usage(copied, output: 5)])
        let before = try store.databasePool.read { db in try Int64.fetchOne(db, sql: "SELECT rate_basis_id FROM token_events") }
        let basis = try #require(before)
        let window = try UsageWindow.make(.hour, now: february + 60_000, timeZone: .gmt)
        let originalCharge = try store.usage(window: window, filter: .init(projectID: 1), metric: .cost)
        #expect(originalCharge.totals.counts.total == 12 && originalCharge.totals.costMicroUSD == 9)

        _ = try store.activatePricing(TokenQuoteEngine.make(table: quoteTable(newRates: true, cacheRead: 0)))
        try store.write([usage(original, output: 7, ownership: .original)])
        try store.write([usage(original, output: 5, ownership: .inherited)])
        let unscoped = try store.usage(window: window, metric: .cost)
        let oldProject = try store.usage(window: window, filter: .init(projectID: 1), metric: .cost)
        let newProject = try store.usage(window: window, filter: .init(projectID: 2), metric: .cost)
        #expect(unscoped.totals.counts == TokenCounts(inputFresh: 4, cacheRead: 3, output: 7, reasoning: 2))
        // Original rate still costs 4 fresh + 7 output = 11 µUSD. Cache reads
        // are free in the fixture; the later 5 µUSD rate cannot replace the quote.
        #expect(unscoped.totals.costMicroUSD == 11)
        #expect(oldProject.totals.counts.total == 0 && oldProject.totals.costMicroUSD == 0)
        #expect(newProject.totals == unscoped.totals)
        #expect(newProject.cacheSavings == UsageCacheSavings(microUSD: 3, measuredCacheReadTokens: 3))
        try store.databasePool.read { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events") == 1)
            #expect(try Int64.fetchOne(db, sql: "SELECT rate_basis_id FROM token_events") == basis)
            #expect(try String.fetchOne(db, sql: """
                SELECT s.native_id FROM token_events t JOIN sessions s ON s.id=t.session_id
                """) == original.nativeID)
        }
    }
}

@Test("FR-COST: a failed batch leaves unpriced history, rollups and its gate unchanged")
func cacheBatchRollback() throws {
    try withQuoteStore { store, index in
        let session = try addQuoteSession(store, index: index, agent: .codex)
        try store.write((1...2).map { number in
            .tokens(.init(session: session, timestamp: february, model: "synthetic-primary",
                          counts: .init(cacheRead: 1), dedupeKey: "synthetic-unpriced-\(number)"))
        })
        let basis = TokenRateBasis(reference: "synthetic-basis", bytes: Data([1]))
        let failing = try store.activatePricing { _, _ in
            TokenQuote(microUSD: Int64.max, status: .priced, basis: basis, cacheSavingsMicroUSD: 1)
        }
        #expect(throws: DatabaseError.self) { try store.backfillUnpriced(failing) }
        #expect(try storedQuotes(store).map(\.status) == ["unpriced", "unpriced"])
        #expect(try store.databasePool.read { db in try Int.fetchOne(db, sql: "SELECT count(*) FROM quote_batch_gate") } == 0)
        let valid = try store.activatePricing { _, _ in
            TokenQuote(microUSD: 3, status: .priced, basis: basis, cacheSavingsMicroUSD: 2)
        }
        #expect(try store.backfillUnpriced(valid).priced == 2)
        let time = try UsageWindow.make(.hour, now: february + 60_000, timeZone: .gmt)
        let report = try store.usage(window: time, metric: .cost)
        #expect(report.totals.costMicroUSD == 6)
        #expect(report.cacheSavings == UsageCacheSavings(microUSD: 4, measuredCacheReadTokens: 2))
    }
}

@Test("NFR-10: backfill one million varied usage records with exact rollups",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_PRICE_BENCHMARK"] == "1"
          || ProcessInfo.processInfo.environment["AGENTDASH_SAVINGS_BENCHMARK"] == "1"))
func backfillMillionUnpricedRecords() throws {
    let pricedCache = ProcessInfo.processInfo.environment["AGENTDASH_SAVINGS_BENCHMARK"] == "1"
    try withQuoteStore { store, index in
        let session = try addQuoteSession(store, index: index, agent: .codex)
        try store.databasePool.write { db in
            let id = try #require(try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE native_id=?",
                                                     arguments: [session.nativeID]))
            try db.execute(sql: """
                WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000000)
                INSERT INTO token_events(session_id,agent,model,ts,input_fresh,cache_read,output,precision,dedupe_key)
                SELECT ?, 'codex', CASE WHEN n%5=0 THEN 'synthetic-added' ELSE 'synthetic-primary' END,
                       ?+n*100, 1+n%17,n%7,1+n%41, CASE WHEN n%23=0 THEN 'checkpoint' ELSE 'call' END,
                       'synthetic-cost-'||n
                FROM seq
                """, arguments: [id, february])
        }
        let expected = try store.databasePool.read { db in
            try Int64.fetchOne(db, sql: """
                SELECT sum((input_fresh+output)*(CASE WHEN model='synthetic-added' THEN 3 ELSE 5 END)
                    + cache_read*(CASE WHEN ? THEN 1 WHEN model='synthetic-added' THEN 3 ELSE 5 END))
                FROM token_events
                """, arguments: [pricedCache])
        }
        let initial = try store.activatePricing(TokenQuoteEngine.make(table: quoteTable(newRates: true, cacheRead: pricedCache ? 1 : nil)))
        let clock = ContinuousClock()
        let start = clock.now
        var cursor: UnpricedTokenSweep? = initial
        var applied = 0
        while let page = cursor {
            let result = try store.backfillUnpriced(page)
            applied += result.priced
            cursor = result.next
        }
        let duration = start.duration(to: clock.now)
        print("Synthetic backfill of \(applied) token events: \(duration)")
        #expect(applied == 1_000_000)
        try store.databasePool.read { db throws -> Void in
            #expect(try Int64.fetchOne(db, sql: "SELECT sum(cost_micro_usd) FROM token_events") == expected)
            #expect(try Int64.fetchOne(db, sql: "SELECT sum(cost_micro_usd) FROM token_minute") == expected)
            #expect(try Int64.fetchOne(db, sql: "SELECT sum(unpriced_tokens) FROM token_minute") == 0)
            #expect(try Int64.fetchOne(db, sql: "SELECT sum(cost_micro_usd) FROM token_usage_scope WHERE grain=60") == expected)
            if pricedCache {
                let expectedSavings = try Int64.fetchOne(db, sql: """
                    SELECT sum(cache_read*(CASE WHEN model='synthetic-added' THEN 2 ELSE 4 END)) FROM token_events
                    """)
                #expect(try Int64.fetchOne(db, sql: "SELECT sum(savings_micro_usd) FROM cache_savings_hour") == expectedSavings)
            }
        }
        #expect(duration < .seconds(10))
    }
}

private func withQuoteStore(_ body: (AgentStore, URL) throws -> Void) throws {
    try withQuoteIndex { try body(AgentStore(databaseURL: $0), $0) }
}

private func withQuoteIndex(_ body: (URL) throws -> Void) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-quote-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    try body(temp.appendingPathComponent("index.sqlite"))
}

private func addQuoteSession(_ store: AgentStore, index: URL, agent: AgentKind) throws -> SessionKey {
    let source = try store.upsertSource(.init(agent: agent, label: "Synthetic", rootURL: index.deletingLastPathComponent()))
    let session = SessionKey(agent: agent, nativeID: "synthetic-session")
    try store.write([.session(.init(key: session, sourceID: source, environment: "Synthetic"))])
    return session
}

private func storedQuotes(_ store: AgentStore) throws -> [(amount: Int64, status: String)] {
    try store.databasePool.read { db in
        try Row.fetchAll(db, sql: "SELECT cost_micro_usd,price_status FROM token_events ORDER BY dedupe_key")
            .map { ($0["cost_micro_usd"], $0["price_status"]) }
    }
}

private func quoteTable(newRates: Bool, cacheRead: Int? = nil) throws -> PriceTable {
    func entry(_ day: String, value: Int) -> String {
        let cached = cacheRead.map { #","cacheRead":\#($0)"# } ?? ""
        return #"{"effectiveFrom":"\#(day)","input":\#(value),"output":\#(value),"source":"https://example.invalid/synthetic","checkedAt":"2026-11-19"\#(cached)}"#
    }
    var entries = entry("2026-01-01", value: 1)
    if newRates { entries += "," + entry("2026-02-01", value: 5) }
    var models = #"{"id":"synthetic-primary","vendor":"synthetic","displayName":"Synthetic","prices":[\#(entries)]}"#
    if newRates {
        models += #",{"id":"synthetic-added","vendor":"synthetic","displayName":"Synthetic","prices":[\#(entry("2026-02-01", value: 3))]}"#
    }
    return try PriceTable.decode(Data(#"{"schemaVersion":1,"currency":"USD","unit":"per_million_tokens","updatedAt":"2026-11-19","models":[\#(models)]}"#.utf8))
}

@Test("FR-COST: unpriced-model diagnostics follow quote commits without changing token totals", .timeLimit(.minutes(1)))
func unpricedDiagnosticsFollowCommittedQuotes() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("unpriced-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let index = folder.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: index)
    let session = try addQuoteSession(store, index: index, agent: .codex)
    _ = try store.activatePricing(TokenQuoteEngine.make(table: quoteTable(newRates: false)))
    try store.write([
        .tokens(.init(session: session, timestamp: february, model: "synthetic-added",
                      counts: .init(inputFresh: 2, cacheRead: 1, output: 3), dedupeKey: "future")),
        .tokens(.init(session: session, timestamp: february, model: nil, counts: .init(output: 1), dedupeKey: "unknown")),
    ])
    var observation = store.unpricedUsageUpdates().makeAsyncIterator()
    let initial = try #require(try await observation.next())
    #expect(initial.map(\.model) == ["synthetic-added", nil])
    #expect(initial.map(\.tokens) == [6, 1])

    let sweep = try store.activatePricing(TokenQuoteEngine.make(table: quoteTable(newRates: true)))
    let batch = try store.backfillUnpriced(sweep)
    #expect(batch.priced == 1 && batch.next == nil)
    let updated = try #require(try await observation.next())
    #expect(updated.map(\.model) == [nil] && updated.map(\.tokens) == [1])
    let window = try UsageWindow.make(.hour, now: february + 60_000, timeZone: .gmt)
    let result = try store.usage(window: window)
    #expect(result.totals.counts.total == 7 && result.totals.unpricedTokens == 1)
}
