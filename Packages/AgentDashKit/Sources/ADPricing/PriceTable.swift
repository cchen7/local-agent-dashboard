import Foundation

/// An immutable, validated schema-v1 table. Construction and lookup perform no I/O.
public struct PriceTable: Sendable {
    public let schemaVersion: Int
    public let currency: String
    public let unit: String
    public let updatedAt: UTCDate
    public let displayCurrencies: [DisplayCurrency]
    public let aliases: [String: String]
    public let models: [PriceModel]
    private let modelIDs: [String: Int]
    private let aliasTargets: [String: Int]
    private let matchers: [Matcher]

    /// Decode and validate atomically. Decoder diagnostics never cross this boundary.
    public static func decode(_ data: Data) throws(PricingError) -> Self {
        let decoder = JSONDecoder()
        try preflightJSON(data, decoder: decoder)
        let raw: Document
        do { raw = try decoder.decode(Document.self, from: data) }
        catch { throw .invalidJSON }
        return try Self(raw)
    }

    private init(_ raw: Document) throws(PricingError) {
        guard raw.schemaVersion == 1 else { throw .unsupportedSchemaVersion }
        guard raw.currency == "USD" else { throw .invalidCurrency }
        guard raw.unit == "per_million_tokens" else { throw .invalidUnit }
        schemaVersion = raw.schemaVersion
        currency = raw.currency
        unit = raw.unit
        updatedAt = try UTCDate(raw.updatedAt)
        var currencies = [DisplayCurrency]()
        var currencyCodes = Set<String>()
        for entry in raw.displayCurrencies ?? [] {
            guard entry.code.utf8.count == 3, entry.code.utf8.allSatisfy({ (65...90).contains($0) }),
                  currencyCodes.insert(entry.code).inserted, !entry.ratePerUSD.isNaN, entry.ratePerUSD > 0,
                  entry.code != "USD" || entry.ratePerUSD == 1 else { throw .invalidDisplayCurrency }
            currencies.append(.init(code: entry.code, ratePerUSD: entry.ratePerUSD, asOf: try UTCDate(entry.asOf)))
        }
        displayCurrencies = currencies

        var decodedModels = [PriceModel]()
        var ids = [String: Int]()
        for (index, model) in raw.models.enumerated() {
            let id = Self.normalize(model.id)
            guard !id.isEmpty, !Self.hasWildcard(id), !Self.blank(model.vendor), !Self.blank(model.displayName)
            else { throw .invalidModel }
            guard ids.updateValue(index, forKey: id) == nil else { throw .duplicateModel }
            guard !model.prices.isEmpty else { throw .emptyPrices }
            var dates = Set<UTCDate>()
            var prices = [EffectivePrice]()
            for entry in model.prices {
                let date = try UTCDate(entry.effectiveFrom)
                guard dates.insert(date).inserted else { throw .duplicateEffectiveDate }
                guard !Self.blank(entry.source) else { throw .invalidPrice }
                try entry.rates.validate()
                var previous: Int64 = -1
                var tiers = [PriceTier]()
                for tier in entry.tiers ?? [] {
                    guard tier.whenPromptTokensAbove >= 0, tier.whenPromptTokensAbove > previous
                    else { throw .invalidTier }
                    try tier.rates.validate()
                    previous = tier.whenPromptTokensAbove
                    tiers.append(.init(whenPromptTokensAbove: tier.whenPromptTokensAbove, rates: tier.rates))
                }
                prices.append(.init(effectiveFrom: date, rates: entry.rates, tiers: tiers,
                                    source: entry.source, checkedAt: try UTCDate(entry.checkedAt)))
            }
            decodedModels.append(.init(id: model.id, vendor: model.vendor, displayName: model.displayName,
                                       match: model.match ?? [], prices: prices.sorted { $0.effectiveFrom < $1.effectiveFrom }))
        }
        models = decodedModels
        modelIDs = ids

        var selectors = ids
        var compiled = [Matcher]()
        for (index, model) in decodedModels.enumerated() {
            for pattern in model.match {
                let pattern = Self.normalize(pattern)
                guard !pattern.isEmpty else { throw .invalidMatchPattern }
                // Identical normalized selectors cannot name different models. Broader
                // overlapping globs are valid: specificity and table order resolve them.
                if let owner = selectors[pattern], owner != index { throw .conflictingMatch }
                selectors[pattern] = index
                compiled.append(.init(pattern: Array(pattern), modelIndex: index))
            }
        }
        matchers = compiled.sorted {
            if $0.specificity != $1.specificity { return $0.specificity > $1.specificity }
            return $0.modelIndex < $1.modelIndex
        }

        var targets = [String: Int]()
        for (key, target) in raw.aliases ?? [:] {
            let alias = Self.normalize(key)
            guard !alias.isEmpty, !Self.hasWildcard(alias), let index = ids[Self.normalize(target)],
                  targets[alias] == nil, ids[alias] == nil || ids[alias] == index else { throw .invalidAlias }
            targets[alias] = index // Direct canonical targets only; no chains/cycles.
        }
        aliases = raw.aliases ?? [:]
        aliasTargets = targets
    }

    /// Aliases precede exact normalized IDs; glob ties prefer the earlier model.
    public func match(model: String) -> ModelMatch? {
        let normalized = Self.normalize(model)
        guard !normalized.isEmpty else { return nil }
        if let index = aliasTargets[normalized] { return .init(model: models[index], kind: .alias) }
        if let index = modelIDs[normalized] { return .init(model: models[index], kind: .exact) }
        let characters = Array(normalized)
        guard let matcher = matchers.first(where: { $0.matches(characters) }) else { return nil }
        return .init(model: models[matcher.modelIndex], kind: matcher.isGlob ? .glob : .exact)
    }

    /// Timestamp is UTC epoch milliseconds. Dates before the first entry have no price.
    public func price(model: String, at timestamp: Int64) -> PriceSelection? {
        guard let match = match(model: model) else { return nil }
        // Integer floor division also handles pre-epoch milliseconds and Int64 extrema.
        let day = timestamp / 86_400_000 - (timestamp % 86_400_000 < 0 ? 1 : 0)
        guard let price = match.model.prices.last(where: { $0.effectiveFrom.epochDay <= day }) else { return nil }
        return .init(match: match, price: price)
    }

    static func normalize(_ value: String) -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["anthropic/", "openai/", "xai/"] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    private static func blank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasWildcard(_ value: String) -> Bool { value.contains("*") || value.contains("?") }
}

/// Reject ambiguity that can disappear during typed decoding: duplicate member
/// names and Decimal literals outside the supported precision. Both passes use
/// the same UTF-8 bytes; JSONDecoder still validates the document grammar.
private func preflightJSON(_ data: Data, decoder: JSONDecoder) throws(PricingError) {
    let bytes = Array(data)
    // UTF-16/32 without a BOM can also pass a UTF-8 validity check because JSON
    // punctuation becomes ASCII interleaved with NUL. Raw NUL is never valid JSON.
    guard !bytes.contains(0), String(bytes: bytes, encoding: .utf8) != nil else { throw .invalidJSON }
    var objects: [Set<String>?] = [] // One entry per container; arrays have no member names.
    var index = 0
    while index < bytes.count {
        switch bytes[index] {
        case 123, 91: // '{' or '['
            objects.append(bytes[index] == 123 ? [] : nil)
            index += 1
        case 125, 93: // '}' or ']'
            guard !objects.isEmpty else { throw .invalidJSON }
            objects.removeLast()
            index += 1
        case 34: // A string; in valid JSON, only member names are followed by ':'.
            let start = index
            index += 1
            while index < bytes.count && bytes[index] != 34 {
                index += bytes[index] == 92 ? 2 : 1 // Skip an escape and its next byte.
            }
            guard index < bytes.count else { throw .invalidJSON }
            index += 1
            let end = index
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            if index < bytes.count, bytes[index] == 58, !objects.isEmpty, objects[objects.count - 1] != nil {
                let key: String
                // Compare decoded names so e.g. "input" and "in\\u0070ut" collide.
                do { key = try decoder.decode(String.self, from: Data(bytes[start..<end])) }
                catch { throw .invalidJSON }
                guard objects[objects.count - 1]?.insert(key).inserted == true else { throw .invalidJSON }
            }
        case 45, 48...57:
            let start = index
            while index < bytes.count {
                let byte = bytes[index]
                guard (48...57).contains(byte) || [43, 45, 46, 69, 101].contains(byte) else { break }
                index += 1
            }
            let digits = bytes[start..<index].prefix { $0 != 69 && $0 != 101 }.filter { (48...57).contains($0) }
            if let first = digits.firstIndex(where: { $0 != 48 }), let last = digits.lastIndex(where: { $0 != 48 }),
               last - first + 1 > 38 { throw .invalidJSON }
        default: index += 1
        }
    }
}

private struct Matcher: Sendable {
    let pattern: [Character]
    let modelIndex: Int
    var specificity: Int { pattern.filter { $0 != "*" && $0 != "?" }.count }
    var isGlob: Bool { pattern.contains("*") || pattern.contains("?") }

    /// Anchored glob: '*' matches zero or more characters, '?' exactly one.
    /// All other characters are literal. No regex compilation or recursive matching.
    func matches(_ text: [Character]) -> Bool {
        var p = 0, t = 0
        var star: Int?, retry = 0
        while t < text.count {
            if p < pattern.count, pattern[p] != "*", pattern[p] == "?" || pattern[p] == text[t] {
                p += 1; t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                star = p; p += 1; retry = t
            } else if let star, retry < text.count {
                retry += 1; t = retry; p = star + 1
            } else { return false }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}

// Wire types are private so only validated tables are constructible by clients.
private struct Document: Decodable {
    let schemaVersion: Int
    let currency, unit, updatedAt: String
    let displayCurrencies: [RawCurrency]?
    let aliases: [String: String]?
    let models: [RawModel]
}

private struct RawCurrency: Decodable {
    let code: String
    let ratePerUSD: Decimal
    let asOf: String
}

private struct RawModel: Decodable {
    let id, vendor, displayName: String
    let match: [String]?
    let prices: [RawPrice]
}

private struct RawPrice: Decodable {
    let effectiveFrom, source, checkedAt: String
    let input, output: Decimal
    let cacheRead, cacheWrite5m, cacheWrite1h: Decimal?
    let tiers: [RawTier]?
    var rates: PriceRates {
        .init(input: input, output: output, cacheRead: cacheRead, cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h)
    }
}

private struct RawTier: Decodable {
    let whenPromptTokensAbove: Int64
    let input, output: Decimal
    let cacheRead, cacheWrite5m, cacheWrite1h: Decimal?
    var rates: PriceRates {
        .init(input: input, output: output, cacheRead: cacheRead, cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h)
    }
}
