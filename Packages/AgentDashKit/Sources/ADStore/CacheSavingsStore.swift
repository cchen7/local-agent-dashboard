import ADCore
import Foundation
import GRDB

public struct UsageCacheSavings: Equatable, Sendable {
    public let microUSD: Int64
    public let measuredCacheReadTokens: Int64
}

public struct CacheSavingsSweep: Sendable {
    fileprivate let throughID: Int64
    fileprivate let afterID: Int64
}

public struct CacheSavingsBatch: Sendable {
    public let next: CacheSavingsSweep?
    public let measured: Int
}

private let legacyHorizonKey = "cache_savings_legacy_through"

public extension AgentStore {
    func pendingCacheSavings() throws -> CacheSavingsSweep? {
        try databasePool.read { db in
            try cacheSavingsHorizon(db).map { CacheSavingsSweep(throughID: $0, afterID: 0) }
        }
    }

    /// Once per migration, fill this separate derived metric using each old
    /// event's frozen rates. Never write its cost, status, or price reference.
    func backfillCacheSavings(_ cursor: CacheSavingsSweep, limit: Int = 1_024) throws -> CacheSavingsBatch {
        try databasePool.write { db in
            guard try cacheSavingsHorizon(db) == cursor.throughID else {
                return CacheSavingsBatch(next: nil, measured: 0)
            }
            guard let quote = tokenQuoter.withLock({ $0?.quote }) else { throw StoreError.pricingSuperseded }
            let size = max(1, min(4_096, limit))
            let rows = try Row.fetchAll(db, sql: """
                \(TokenQuoteStore.columns)
                WHERE t.id>? AND t.id<=? AND t.cache_read>0 AND t.cache_savings_micro_usd IS NULL
                  AND t.rate_basis_id IS NOT NULL AND t.price_status<>'unpriced'
                ORDER BY t.id LIMIT ?
                """, arguments: [cursor.afterID, cursor.throughID, size])
            let update = try db.cachedStatement(sql: "UPDATE token_events SET cache_savings_micro_usd=? WHERE id=?")
            var measured = 0
            for row in rows {
                guard let basis = TokenQuoteStore.basis(from: row) else { continue }
                let input = try TokenQuoteStore.input(from: row)
                guard let cost = quote(input, basis), cost.basis == basis,
                      let savings = cost.cacheSavingsMicroUSD, savings != Int64.min else { continue }
                let id: Int64 = row["id"]
                try update.execute(arguments: [savings, id])
                measured += 1
            }
            if rows.count == size, let row = rows.last, let id: Int64 = row["id"], id < cursor.throughID {
                return CacheSavingsBatch(next: CacheSavingsSweep(throughID: cursor.throughID, afterID: id), measured: measured)
            }
            try db.execute(sql: "DELETE FROM app_meta WHERE key=?", arguments: [legacyHorizonKey])
            return CacheSavingsBatch(next: nil, measured: measured)
        }
    }
}

private func cacheSavingsHorizon(_ db: Database) throws -> Int64? {
    guard let text = try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key=?",
                                         arguments: [legacyHorizonKey]),
          let id = Int64(text), id > 0 else { return nil }
    return id
}
