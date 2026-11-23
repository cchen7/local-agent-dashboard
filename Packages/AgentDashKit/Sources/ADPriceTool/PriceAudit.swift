import ADCore
import ADPricing
import ADPrivacy

enum PriceHistoryFailure: Error { case removedEntry, changedEntry, aggregateOverflow }

func preservePrices(in previous: PriceTable, with candidate: PriceTable) throws {
    let current = Dictionary(uniqueKeysWithValues: candidate.models.map {
        ($0.id, Dictionary(uniqueKeysWithValues: $0.prices.map { ($0.effectiveFrom, $0) }))
    })
    for model in previous.models {
        for rate in model.prices {
            guard let existing = current[model.id]?[rate.effectiveFrom] else { throw PriceHistoryFailure.removedEntry }
            guard rate == existing else { throw PriceHistoryFailure.changedEntry }
        }
    }
}

struct HistoricalPriceImpact: Encodable {
    private(set) var records: Int64 = 0
    private(set) var changedQuotes: Int64 = 0
    private(set) var storedMicroUSD: Int64 = 0
    private(set) var beforeMicroUSD: Int64 = 0
    private(set) var candidateMicroUSD: Int64 = 0
    private(set) var oldUnpricedTokens: Int64 = 0
    private(set) var candidateUnpricedTokens: Int64 = 0
    private(set) var projectedStoredMicroUSD: Int64 = 0
    private(set) var projectedUnpricedTokens: Int64 = 0
    private(set) var backfillableRecords: Int64 = 0

    mutating func include(_ row: IndexedPriceUsage, before: PriceTable, candidate: PriceTable) throws {
        let old = try before.estimate(model: row.model, at: row.timestamp, counts: row.counts, precision: row.precision)
        let new = try candidate.estimate(model: row.model, at: row.timestamp, counts: row.counts, precision: row.precision)
        records = try adding(records, 1)
        if old.status != new.status || old.costMicroUSD != new.costMicroUSD { changedQuotes = try adding(changedQuotes, 1) }
        storedMicroUSD = try adding(storedMicroUSD, row.storedMicroUSD)
        beforeMicroUSD = try adding(beforeMicroUSD, old.costMicroUSD)
        candidateMicroUSD = try adding(candidateMicroUSD, new.costMicroUSD)
        oldUnpricedTokens = try adding(oldUnpricedTokens, old.unpricedTokens)
        candidateUnpricedTokens = try adding(candidateUnpricedTokens, new.unpricedTokens)
        projectedStoredMicroUSD = try adding(projectedStoredMicroUSD, row.wasUnpriced ? new.costMicroUSD : row.storedMicroUSD)
        if row.wasUnpriced {
            if case .unpriced = new.status {
                projectedUnpricedTokens = try adding(projectedUnpricedTokens, new.unpricedTokens)
            } else {
                backfillableRecords = try adding(backfillableRecords, 1)
            }
        }
    }
}

struct PriceInventory {
    struct Key: Encodable, Hashable { let agent: AgentKind; let model: String? }
    struct Entry: Encodable { let key: Key; var tokens: Int64 = 0; var unpricedTokens: Int64 = 0 }
    private var entries: [Key: Entry] = [:]
    var sorted: [Entry] {
        entries.values.sorted {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            if $0.key.agent != $1.key.agent { return $0.key.agent.rawValue < $1.key.agent.rawValue }
            return ($0.key.model ?? "") < ($1.key.model ?? "")
        }
    }

    mutating func include(_ row: IndexedPriceUsage, table: PriceTable) throws {
        let checked = try table.estimate(model: row.model, at: row.timestamp, counts: row.counts, precision: row.precision)
        let key = Key(agent: row.agent, model: row.model.flatMap(Self.safeModelID))
        var entry = entries[key] ?? Entry(key: key)
        // The estimate has already checked component signs and aggregate overflow.
        entry.tokens = try adding(entry.tokens, row.counts.total)
        entry.unpricedTokens = try adding(entry.unpricedTokens, checked.unpricedTokens)
        entries[key] = entry
    }

    private static func safeModelID(_ id: String) -> String? {
        guard id.utf8.count <= 120, id.utf8.first.map({ isAlphanumeric($0) }) == true,
              id.utf8.allSatisfy({ isAlphanumeric($0) || [45, 46, 47, 58, 95].contains($0) }),
              !id.contains("//"), !id.contains(".."), SecretMasker.mask(id) == id else { return nil }
        return id
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

private func adding(_ left: Int64, _ right: Int64) throws -> Int64 {
    let (value, overflow) = left.addingReportingOverflow(right)
    guard !overflow else { throw PriceHistoryFailure.aggregateOverflow }
    return value
}
