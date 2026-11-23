import Foundation

/// Deliberately carries no input values, file paths, coding paths or underlying errors.
public enum PricingError: Error, Equatable, Sendable {
    case invalidJSON, unsupportedSchemaVersion, invalidCurrency, invalidUnit, invalidDate
    case invalidModel, duplicateModel, emptyPrices, invalidPrice, duplicateEffectiveDate
    case invalidTier, invalidMatchPattern, conflictingMatch, invalidAlias, invalidDisplayCurrency
    case invalidTokenCounts, tokenCountOverflow, unrepresentableCost
}

/// A strict proleptic Gregorian YYYY-MM-DD date, independent of locale/time zone.
public struct UTCDate: Equatable, Hashable, Comparable, Sendable {
    public let rawValue: String
    let epochDay: Int64

    public init(_ value: String) throws(PricingError) {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }),
              let year = Int(value.prefix(4)), let month = Int(value.dropFirst(5).prefix(2)),
              let day = Int(value.suffix(2)), (1...9999).contains(year), (1...12).contains(month)
        else { throw .invalidDate }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let monthDays = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...monthDays[month - 1]).contains(day) else { throw .invalidDate }
        let previousYear = year - 1
        let ordinal = 365 * previousYear + previousYear / 4 - previousYear / 100 + previousYear / 400
            + monthDays.prefix(month - 1).reduce(0, +) + day
        rawValue = value
        epochDay = Int64(ordinal - 719_163) // 1970-01-01 is Gregorian ordinal 719163.
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.epochDay < rhs.epochDay }
}

/// USD per million tokens, represented as Decimal throughout accounting.
public struct PriceRates: Codable, Equatable, Sendable {
    public let input: Decimal
    public let output: Decimal
    public let cacheRead: Decimal?
    public let cacheWrite5m: Decimal?
    public let cacheWrite1h: Decimal?

    func validate() throws(PricingError) {
        for value in [input, output] + [cacheRead, cacheWrite5m, cacheWrite1h].compactMap({ $0 }) {
            guard !value.isNaN, value >= 0 else { throw .invalidPrice }
        }
    }
}

public struct PriceTier: Codable, Equatable, Sendable {
    public let whenPromptTokensAbove: Int64
    public let rates: PriceRates
}

public struct EffectivePrice: Equatable, Sendable {
    public let effectiveFrom: UTCDate
    /// First UTC date this entry no longer applies, if the vendor set a cutoff.
    public let effectiveUntil: UTCDate?
    public let rates: PriceRates
    public let tiers: [PriceTier]
    public let source: String
    public let checkedAt: UTCDate
}

public struct PriceModel: Equatable, Sendable {
    public let id: String
    public let vendor: String
    public let displayName: String
    public let match: [String]
    public let prices: [EffectivePrice]
}

/// Static display metadata only; estimating a TokenEvent always returns micro-USD.
public struct DisplayCurrency: Equatable, Sendable {
    public let code: String
    public let ratePerUSD: Decimal
    public let asOf: UTCDate
}

public enum ModelMatchKind: Equatable, Sendable { case alias, exact, glob }

public struct ModelMatch: Equatable, Sendable {
    public let model: PriceModel
    public let kind: ModelMatchKind
}

public struct PriceSelection: Equatable, Sendable {
    public let match: ModelMatch
    public let price: EffectivePrice
}

public enum ApproximationReason: Hashable, Sendable {
    case coarsePrecision, missingCacheReadPrice, missingCacheWrite5mPrice, missingCacheWrite1hPrice
}

public enum UnpricedReason: Equatable, Sendable { case missingModel, noMatchingModel, noEffectivePrice }

public enum PricingStatus: Equatable, Sendable {
    case priced
    case approximate(Set<ApproximationReason>)
    case unpriced(UnpricedReason)
}

public struct CostEstimate: Equatable, Sendable {
    public let costMicroUSD: Int64
    public let unpricedTokens: Int64
    public let status: PricingStatus
    public let selection: PriceSelection?
    public let appliedTierThreshold: Int64?
}
