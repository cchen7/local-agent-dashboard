import ADCore
import Foundation
import GRDB

struct ActiveTokenQuoter: Sendable {
    let revision: UUID
    let quote: TokenQuoter
}

public struct UnpricedTokenSweep: Sendable {
    fileprivate let revision: UUID
    fileprivate let throughID: Int64
    fileprivate let afterID: Int64
}

public struct UnpricedTokenBatch: Sendable {
    public let next: UnpricedTokenSweep?
    public let examined: Int
    public let priced: Int
}

public extension AgentStore {
    /// Activate a verified quote provider in writer order. Subsequent inserts
    /// use it immediately; the returned horizon covers earlier unpriced rows.
    func activatePricing(_ quote: @escaping TokenQuoter) throws -> UnpricedTokenSweep {
        try databasePool.write { db in
            let last = try Int64.fetchOne(db, sql: "SELECT max(id) FROM token_events") ?? 0
            let revision = UUID()
            tokenQuoter.withLock { $0 = ActiveTokenQuoter(revision: revision, quote: quote) }
            return UnpricedTokenSweep(revision: revision, throughID: last, afterID: 0)
        }
    }

    /// Run one bounded background transaction. Each grouped delta and its
    /// individual stored quotes become visible in the same commit.
    func backfillUnpriced(_ cursor: UnpricedTokenSweep, limit: Int = 1_024) throws -> UnpricedTokenBatch {
        try databasePool.write { db in
            guard let active = tokenQuoter.withLock({ $0 }), active.revision == cursor.revision else {
                throw StoreError.pricingSuperseded
            }
            let size = max(1, min(4_096, limit))
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id,model,ts,precision,input_fresh,cache_read,cache_write,cache_write_1h,output,reasoning
                FROM token_events WHERE price_status='unpriced' AND model IS NOT NULL AND id>? AND id<=?
                ORDER BY id LIMIT ?
                """, arguments: [cursor.afterID, cursor.throughID, size])
            // Read only the quoting fields. Finish the cursor before issuing
            // updates against its table in the same writer transaction.
            var pending: [(id: Int64, result: TokenQuote)] = []
            pending.reserveCapacity(size)
            var lastID = cursor.afterID
            var examined = 0
            while let row = try rows.next() {
                lastID = row[0]
                examined += 1
                guard let precision = TokenPrecision(rawValue: row[3]) else { throw StoreError.invalidStoredValue }
                let input = TokenQuoteInput(
                    model: row[1], timestamp: row[2], precision: precision,
                    counts: .init(inputFresh: row[4], cacheRead: row[5], cacheWrite: row[6],
                                  cacheWrite1h: row[7], output: row[8], reasoning: row[9]))
                if let result = active.quote(input, nil) { pending.append((lastID, result)) }
            }
            var writer = try TokenQuoteStore.Writer(quote: active.quote, db: db)
            let updated = try writer.persistUnpricedBatch(pending, db: db)
            let next: UnpricedTokenSweep?
            if examined == size, lastID < cursor.throughID {
                next = UnpricedTokenSweep(revision: cursor.revision, throughID: cursor.throughID, afterID: lastID)
            } else {
                next = nil
            }
            return UnpricedTokenBatch(next: next, examined: examined, priced: updated)
        }
    }
}

enum TokenQuoteStore {
    static let columns = """
        SELECT t.id,t.model,t.ts,t.precision,t.input_fresh,t.cache_read,t.cache_write,t.cache_write_1h,t.output,t.reasoning,
               t.cost_micro_usd,t.price_status,t.rate_basis_id,b.reference,b.bytes,t.cache_savings_micro_usd
        FROM token_events t LEFT JOIN token_rate_bases b ON b.id=t.rate_basis_id
        """

    static func basis(from row: Row) -> TokenRateBasis? {
        guard let reference: String = row["reference"], let bytes: Data = row["bytes"] else { return nil }
        return TokenRateBasis(reference: reference, bytes: bytes)
    }

    static func input(from row: Row) throws -> TokenQuoteInput {
        guard let precision = TokenPrecision(rawValue: row["precision"]) else { throw StoreError.invalidStoredValue }
        return TokenQuoteInput(model: row["model"], timestamp: row["ts"], precision: precision,
                               counts: .init(inputFresh: row["input_fresh"], cacheRead: row["cache_read"],
                                             cacheWrite: row["cache_write"], cacheWrite1h: row["cache_write_1h"],
                                             output: row["output"], reasoning: row["reasoning"]))
    }

    struct Writer {
        let quote: TokenQuoter
        let updateQuote: Statement
        private var savedBases: [TokenRateBasis: Int64] = [:]

        init(quote: @escaping TokenQuoter, db: Database) throws {
            self.quote = quote
            updateQuote = try db.cachedStatement(sql: """
                UPDATE token_events SET cost_micro_usd=?,price_status=?,price_ref=?,rate_basis_id=?,cache_savings_micro_usd=? WHERE id=?
                """)
        }

        /// Apply to accepted in-transaction writes, after dedupe and coarse
        /// reconciliation have settled the exact usage of the affected records.
        mutating func apply(to keys: Set<String>, db: Database) throws {
            let keys = Array(keys)
            for start in stride(from: 0, to: keys.count, by: 500) {
                let part = keys[start..<min(start + 500, keys.count)]
                let marks = Array(repeating: "?", count: part.count).joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: "\(TokenQuoteStore.columns) WHERE t.dedupe_key IN (\(marks))",
                                            arguments: StatementArguments(part))
                for row in rows { _ = try apply(to: row, db: db) }
            }
        }

        mutating func apply(to row: Row, db: Database) throws -> Bool {
            let status: String = row["price_status"]
            let oldBasisID: Int64? = row["rate_basis_id"]
            let original: TokenRateBasis?
            if status == "unpriced" { original = nil }
            else if let basis = TokenQuoteStore.basis(from: row), oldBasisID != nil {
                original = basis
            } else { return false } // retain a legacy priced row without a stored basis

            let input = try TokenQuoteStore.input(from: row)
            let stored: Int64 = row["cost_micro_usd"]
            let oldSavings: Int64? = row["cache_savings_micro_usd"]
            guard let result = quote(input, original),
                  original == nil || result.basis == original,
                  result.microUSD != stored || result.status.rawValue != status || result.cacheSavingsMicroUSD != oldSavings
            else { return false }
            return try persist(result, id: row["id"], basisID: oldBasisID, db: db)
        }

        mutating func persist(_ result: TokenQuote, id: Int64, basisID: Int64?, db: Database) throws -> Bool {
            guard Self.valid(result) else { return false }
            let basisID = try basisID ?? save(result.basis, db: db)
            try updateQuote.execute(arguments: [result.microUSD, result.status.rawValue, result.basis.reference,
                                                basisID, Self.savings(result), id])
            return true
        }

        /// Stage bounded updates by event ID, then apply both exact grouped
        /// deltas and raw quotes on the same writer. Foreground corrections
        /// still use the per-event triggers.
        mutating func persistUnpricedBatch(_ pending: [(id: Int64, result: TokenQuote)], db: Database) throws -> Int {
            guard !pending.isEmpty else { return 0 }
            try db.execute(sql: """
                CREATE TEMP TABLE IF NOT EXISTS pending_token_quotes (
                    id INTEGER PRIMARY KEY,
                    cost INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    reference TEXT NOT NULL,
                    basis_id INTEGER NOT NULL,
                    savings INTEGER
                );
                DELETE FROM temp.pending_token_quotes;
                """)
            let insert = try db.cachedStatement(sql: "INSERT INTO temp.pending_token_quotes VALUES(?,?,?,?,?,?)")
            var count = 0
            for entry in pending where Self.valid(entry.result) {
                let result = entry.result
                let basisID = try save(result.basis, db: db)
                try insert.execute(arguments: [entry.id, result.microUSD, result.status.rawValue, result.basis.reference,
                                               basisID, Self.savings(result)])
                count += 1
            }
            guard count > 0 else { return 0 }
            try db.execute(sql: """
                INSERT INTO quote_batch_gate VALUES(1);
                INSERT INTO token_quote_delta
                SELECT t.ts/60000-(t.ts%60000<0),t.agent,coalesce(t.project_id,0),coalesce(t.model,''),t.precision,
                       sum(q.cost-t.cost_micro_usd),
                       -sum(t.input_fresh+t.cache_read+t.cache_write+t.cache_write_1h+t.output)
                FROM temp.pending_token_quotes q CROSS JOIN token_events t
                WHERE t.id=q.id AND t.price_status='unpriced'
                GROUP BY 1,2,3,4,5;
                INSERT INTO cache_savings_delta
                SELECT t.ts/3600000-(t.ts%3600000<0),t.agent,coalesce(t.project_id,0),
                       sum(coalesce(q.savings,0)-coalesce(t.cache_savings_micro_usd,0)),
                       sum(((q.savings IS NOT NULL)-(t.cache_savings_micro_usd IS NOT NULL))*t.cache_read)
                FROM temp.pending_token_quotes q CROSS JOIN token_events t
                WHERE t.id=q.id AND t.price_status='unpriced' AND t.cache_read>0
                  AND (q.savings IS NOT NULL OR t.cache_savings_micro_usd IS NOT NULL)
                GROUP BY 1,2,3;
                INSERT INTO session_usage_delta
                SELECT t.session_id,0,0,0,0,0,0,sum(q.cost),
                       -sum(t.input_fresh+t.cache_read+t.cache_write+t.cache_write_1h+t.output),
                       0,sum(q.status='approx')
                FROM temp.pending_token_quotes q CROSS JOIN token_events t
                WHERE t.id=q.id AND t.price_status='unpriced'
                GROUP BY t.session_id;
                UPDATE token_events SET (cost_micro_usd,price_status,price_ref,rate_basis_id,cache_savings_micro_usd)=(
                    SELECT q.cost,q.status,q.reference,q.basis_id,q.savings
                    FROM temp.pending_token_quotes q WHERE q.id=token_events.id
                )
                WHERE id IN (SELECT id FROM temp.pending_token_quotes) AND price_status='unpriced';
                """)
            guard db.changesCount == count else { throw StoreError.invalidStoredValue }
            try db.execute(sql: """
                INSERT INTO usage_chart_dirty
                SELECT min(t.ts),max(t.ts) FROM temp.pending_token_quotes q CROSS JOIN token_events t WHERE t.id=q.id;
                DELETE FROM quote_batch_gate;
                DELETE FROM temp.pending_token_quotes;
                """)
            try UsageChartChanges.publish(db)
            return count
        }

        private static func valid(_ result: TokenQuote) -> Bool {
            result.microUSD >= 0 && !result.basis.reference.isEmpty && !result.basis.bytes.isEmpty
        }

        private static func savings(_ result: TokenQuote) -> Int64? {
            result.cacheSavingsMicroUSD == Int64.min ? nil : result.cacheSavingsMicroUSD
        }

        private mutating func save(_ basis: TokenRateBasis, db: Database) throws -> Int64 {
            if let id = savedBases[basis] { return id }
            let arguments: StatementArguments = [basis.reference, basis.bytes]
            try db.cachedStatement(sql: """
                INSERT INTO token_rate_bases(reference,bytes) VALUES(?,?) ON CONFLICT(reference,bytes) DO NOTHING
                """).execute(arguments: arguments)
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM token_rate_bases WHERE reference=? AND bytes=?",
                                              arguments: arguments) else { throw StoreError.invalidStoredValue }
            savedBases[basis] = id
            return id
        }
    }
}
