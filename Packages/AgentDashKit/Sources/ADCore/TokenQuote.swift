import Foundation

/// Accounting fields used for a quote. Does not expose a session key or transcript.
public struct TokenQuoteInput: Sendable {
    public let model: String?
    public let timestamp: Int64
    public let precision: TokenPrecision
    public let counts: TokenCounts

    public init(model: String?, timestamp: Int64, precision: TokenPrecision, counts: TokenCounts) {
        self.model = model; self.timestamp = timestamp; self.precision = precision; self.counts = counts
    }
}

/// Durable copy of the exact selected rates, shared by events in the app index.
public struct TokenRateBasis: Hashable, Sendable {
    public let reference: String
    public let bytes: Data

    public init(reference: String, bytes: Data) {
        self.reference = reference; self.bytes = bytes
    }
}

public struct TokenQuote: Sendable {
    public enum Status: String, Sendable { case priced, approximate = "approx" }
    public let microUSD: Int64
    public let status: Status
    public let basis: TokenRateBasis
    public let cacheSavingsMicroUSD: Int64?

    public init(microUSD: Int64, status: Status, basis: TokenRateBasis, cacheSavingsMicroUSD: Int64? = nil) {
        self.microUSD = microUSD; self.status = status; self.basis = basis
        self.cacheSavingsMicroUSD = cacheSavingsMicroUSD
    }
}

/// A nil basis requests a quote from the active table. A supplied basis pins a
/// corrected event to its original rates. Nil result leaves an event unpriced.
public typealias TokenQuoter = @Sendable (TokenQuoteInput, TokenRateBasis?) -> TokenQuote?
