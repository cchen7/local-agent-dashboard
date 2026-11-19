import Foundation
import ADCore

extension PriceTable {
    /// Estimate one event without mutating it. Validate counts even for unpriced models.
    /// Sum all Decimal (count * USD-per-million) products in micro-USD, then round
    /// once to the nearest integer with .plain (nonnegative ties round up).
    /// No Double conversion, per-component rounding, saturation or silent precision loss.
    public func estimate(_ event: TokenEvent) throws(PricingError) -> CostEstimate {
        let counts = event.counts
        let components = [counts.inputFresh, counts.cacheRead, counts.cacheWrite, counts.cacheWrite1h, counts.output]
        guard components.allSatisfy({ $0 >= 0 }), counts.reasoning >= 0, counts.reasoning <= counts.output
        else { throw .invalidTokenCounts }
        var total: Int64 = 0, prompt: Int64 = 0
        for (index, count) in components.enumerated() {
            let (sum, overflow) = total.addingReportingOverflow(count)
            guard !overflow else { throw .tokenCountOverflow }
            total = sum
            if index < 4 { prompt = sum }
        }
        func unpriced(_ reason: UnpricedReason) -> CostEstimate {
            .init(costMicroUSD: 0, unpricedTokens: total, status: .unpriced(reason),
                  selection: nil, appliedTierThreshold: nil)
        }
        guard let model = event.model, !Self.normalize(model).isEmpty else { return unpriced(.missingModel) }
        guard match(model: model) != nil else { return unpriced(.noMatchingModel) }
        guard let selection = price(model: model, at: event.timestamp) else { return unpriced(.noEffectivePrice) }
        let tier = event.precision == .call
            ? selection.price.tiers.last(where: { prompt > $0.whenPromptTokensAbove }) : nil
        let rates = tier?.rates ?? selection.price.rates
        var reasons = Set<ApproximationReason>()
        if event.precision != .call { reasons.insert(.coarsePrecision) }
        let cacheRates: [(Decimal?, ApproximationReason)] = [
            (rates.cacheRead, .missingCacheReadPrice), (rates.cacheWrite5m, .missingCacheWrite5mPrice),
            (rates.cacheWrite1h, .missingCacheWrite1hPrice)
        ]
        for (index, cache) in cacheRates.enumerated() where components[index + 1] > 0 && cache.0 == nil {
            reasons.insert(cache.1)
        }
        let prices = [rates.input, rates.cacheRead ?? rates.input, rates.cacheWrite5m ?? rates.input,
                      rates.cacheWrite1h ?? rates.input, rates.output]
        var sum = Decimal.zero
        // USD-per-million * token count equals micro-USD; the 1e6 factors cancel.
        for (count, price) in zip(components, prices) where count != 0 {
            guard productFitsDecimal(count, price) else { throw .unrepresentableCost }
            var count = Decimal(count), price = price, product = Decimal.zero, next = Decimal.zero
            guard NSDecimalMultiply(&product, &count, &price, .plain) == .noError,
                  NSDecimalAdd(&next, &sum, &product, .plain) == .noError else { throw .unrepresentableCost }
            sum = next
        }
        var rounded = Decimal.zero
        NSDecimalRound(&rounded, &sum, 0, .plain)
        guard !rounded.isNaN, rounded >= 0, rounded <= Decimal(Int64.max) else { throw .unrepresentableCost }
        let microUSD = NSDecimalNumber(decimal: rounded).int64Value
        guard Decimal(microUSD) == rounded else { throw .unrepresentableCost }
        return .init(costMicroUSD: microUSD, unpricedTokens: 0,
                     status: reasons.isEmpty ? .priced : .approximate(reasons), selection: selection,
                     appliedTierThreshold: tier?.whenPromptTokensAbove)
    }
}

/// Some Foundation implementations truncate multiplication while returning .noError.
/// Check the exact integer coefficient's significant-digit count before multiplying.
/// The usual case needs only the digit-count bound; the slow path is at most 19x39
/// small digit products and permits exact trailing-zero cancellation (e.g. 10^18).
private func productFitsDecimal(_ count: Int64, _ rate: Decimal) -> Bool {
    guard rate != 0 else { return true }
    var rate = rate
    NSDecimalCompact(&rate)
    let left = String(count).utf8.reversed().map { Int($0) - 48 }
    let right = NSDecimalNumber(decimal: rate.significand).stringValue.utf8.reversed().map { Int($0) - 48 }
    if left.count + right.count <= 38 { return true }
    var digits = [Int](repeating: 0, count: left.count + right.count)
    for i in left.indices {
        for j in right.indices { digits[i + j] += left[i] * right[j] }
    }
    for i in 0..<(digits.count - 1) {
        digits[i + 1] += digits[i] / 10
        digits[i] %= 10
    }
    guard let first = digits.firstIndex(where: { $0 != 0 }),
          let last = digits.lastIndex(where: { $0 != 0 }) else { return true }
    return last - first + 1 <= 38
}
