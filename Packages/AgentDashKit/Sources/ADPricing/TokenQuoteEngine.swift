import ADCore
import Foundation

/// Converts a verified table into quotes the store can persist without depending
/// on table parsing. Corrections can use a persisted basis after the table changes.
public enum TokenQuoteEngine {
    private struct RateData: Codable, Sendable {
        let version: Int
        let base: PriceRates
        let tiers: [PriceTier]
    }

    private struct Key: Hashable, Sendable {
        let model: String
        let date: UTCDate
    }

    private struct PreparedQuote: Sendable {
        let basis: TokenRateBasis
        let rates: RateData
        let base: ScaledRates?
        let tiers: [ScaledRates?]
    }

    /// Common table rates fit an exact bounded fixed-point representation.
    /// Overflow or more precision uses the full Decimal calculation.
    private struct ScaledRates: Sendable {
        let prices: [Int64]
        let divisor: Int64
        let missing: [Bool]

        init?(_ raw: PriceRates) {
            var decimal = [raw.input, raw.cacheRead ?? raw.input, raw.cacheWrite5m ?? raw.input,
                           raw.cacheWrite1h ?? raw.input, raw.output]
            for index in decimal.indices { NSDecimalCompact(&decimal[index]) }
            let digits = decimal.reduce(0) { max($0, $1 == 0 ? 0 : -$1.exponent) }
            guard digits <= 9 else { return nil }
            let divisor = (0..<digits).reduce(Int64(1)) { value, _ in value * 10 }
            var scale = Decimal(divisor)
            var whole: [Int64] = []
            for var rate in decimal {
                var result = Decimal.zero
                guard NSDecimalMultiply(&result, &rate, &scale, .plain) == .noError,
                      result >= 0, result <= Decimal(Int64.max) else { return nil }
                let integer = NSDecimalNumber(decimal: result).int64Value
                guard Decimal(integer) == result else { return nil }
                whole.append(integer)
            }
            self.divisor = divisor
            prices = whole
            missing = [raw.cacheRead == nil, raw.cacheWrite5m == nil, raw.cacheWrite1h == nil]
        }

        func estimate(parts: [Int64], precision: TokenPrecision) -> (Int64, TokenQuote.Status)? {
            var sum: Int64 = 0
            for (count, price) in zip(parts, prices) {
                let product = count.multipliedReportingOverflow(by: price)
                guard !product.overflow else { return nil }
                let next = sum.addingReportingOverflow(product.partialValue)
                guard !next.overflow else { return nil }
                sum = next.partialValue
            }
            let rounded = sum / divisor + (sum % divisor * 2 >= divisor ? 1 : 0)
            let approximate = precision != .call || missing.indices.contains { missing[$0] && parts[$0 + 1] > 0 }
            return (rounded, approximate ? .approximate : .priced)
        }

        func cacheSavings(_ count: Int64) -> Int64? {
            guard count > 0, !missing[0] else { return nil }
            let product = (prices[0] - prices[1]).multipliedReportingOverflow(by: count)
            guard !product.overflow, product.partialValue != Int64.min else { return nil }
            let signed = product.partialValue
            let magnitude = abs(signed)
            let rounded = magnitude / divisor + (magnitude % divisor * 2 >= divisor ? 1 : 0)
            return signed < 0 ? -rounded : rounded
        }
    }

    public static func make(table: PriceTable?) throws -> TokenQuoter {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var prepared: [Key: PreparedQuote] = [:]
        for model in table?.models ?? [] {
            for entry in model.prices {
                let key = Key(model: model.id, date: entry.effectiveFrom)
                let rates = RateData(version: 1, base: entry.rates, tiers: entry.tiers)
                let basis = TokenRateBasis(reference: "\(model.id)@\(entry.effectiveFrom.rawValue)",
                                           bytes: try encoder.encode(rates))
                prepared[key] = PreparedQuote(basis: basis, rates: rates, base: ScaledRates(entry.rates),
                                             tiers: entry.tiers.map { ScaledRates($0.rates) })
            }
        }
        return { [prepared] input, original in
            let rate: RateData
            let basis: TokenRateBasis
            if let original {
                guard let decoded = try? JSONDecoder().decode(RateData.self, from: original.bytes),
                      decoded.version == 1 else { return nil }
                rate = decoded
                basis = original
            } else {
                guard let table, let model = input.model, let price = table.price(model: model, at: input.timestamp),
                      let value = prepared[Key(model: price.match.model.id, date: price.price.effectiveFrom)]
                else { return nil }
                guard let (parts, total) = try? checkedPricingUsage(input.counts) else { return nil }
                let tier = input.precision == .call
                    ? value.rates.tiers.lastIndex(where: { total - input.counts.output > $0.whenPromptTokensAbove }) : nil
                let scaled = if let tier { value.tiers[tier] } else { value.base }
                if let (amount, status) = scaled?.estimate(parts: parts, precision: input.precision) {
                    let savings: Int64?
                    if input.counts.cacheRead > 0 {
                        let effective = if let tier { value.rates.tiers[tier].rates } else { value.rates.base }
                        savings = scaled?.cacheSavings(input.counts.cacheRead) ?? cacheReadSavings(input.counts.cacheRead, rates: effective)
                    } else { savings = nil }
                    return TokenQuote(microUSD: amount, status: status, basis: value.basis, cacheSavingsMicroUSD: savings)
                }
                rate = value.rates
                basis = value.basis
            }
            guard let (parts, total) = try? checkedPricingUsage(input.counts),
                  let quote = try? estimateUsingRates(components: parts, prompt: total - input.counts.output,
                                                     precision: input.precision, base: rate.base, tiers: rate.tiers)
            else { return nil }
            return TokenQuote(microUSD: quote.cost, status: quote.reasons.isEmpty ? .priced : .approximate,
                              basis: basis, cacheSavingsMicroUSD: cacheReadSavings(input.counts.cacheRead, rates: quote.rates))
        }
    }
}
