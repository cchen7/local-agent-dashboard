import Foundation

/// A display-only choice. Changing it never changes the input micro-USD ledger.
public struct PriceDisplayCurrency: Identifiable, Equatable, Sendable {
    public let code: String
    public let asOf: UTCDate?
    private let rate: Decimal
    public var id: String { code }

    public static let usd = Self(code: "USD", asOf: nil, rate: 1)

    public static func choices(_ currencies: [DisplayCurrency]) -> [Self] {
        [.usd] + currencies.filter { $0.code != "USD" }.sorted { $0.code < $1.code }
            .map { Self(code: $0.code, asOf: $0.asOf, rate: $0.ratePerUSD) }
    }

    public func amount(microUSD: Decimal) -> Decimal? {
        guard !microUSD.isNaN else { return nil }
        var amount = microUSD / Decimal(1_000_000)
        var rate = self.rate
        var result = Decimal.zero
        guard NSDecimalMultiply(&result, &amount, &rate, .plain) == .noError, !result.isNaN else { return nil }
        return result
    }
}
