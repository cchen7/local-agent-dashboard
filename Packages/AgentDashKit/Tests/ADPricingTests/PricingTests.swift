import Foundation
import Testing
import ADCore
import ADPricing

/// Entirely synthetic in-memory documents; no vendor prices or source/config files.
private func price(_ date: String = "2026-01-01", input: String = "2", output: String = "7",
                   cache: String = ",\"cacheRead\":0.25,\"cacheWrite5m\":3,\"cacheWrite1h\":4",
                   tiers: String = "") -> String {
    """
    {"effectiveFrom":"\(date)","input":\(input),"output":\(output)\(cache)\(tiers),
     "source":"https://example.invalid/synthetic","checkedAt":"2026-11-19"}
    """
}

private func model(_ id: String = "openai/synthetic-alpha", matches: String = "[]",
                   prices: String = price()) -> String {
    """
    {"id":"\(id)","vendor":"synthetic","displayName":"Synthetic",
     "match":\(matches),"prices":[\(prices)]}
    """
}

private func document(models: String = model(), aliases: String = "{}", extra: String = "") -> Data {
    Data("""
    {"schemaVersion":1,"currency":"USD","unit":"per_million_tokens","updatedAt":"2026-11-19",
     "aliases":\(aliases),"models":[\(models)]\(extra)}
    """.utf8)
}

private func event(model: String? = "synthetic-alpha", timestamp: Int64 = 1_767_225_600_000,
                   counts: TokenCounts = .init(inputFresh: 11, cacheRead: 23, cacheWrite: 5,
                                              cacheWrite1h: 7, output: 13, reasoning: 3),
                   precision: TokenPrecision = .call) -> TokenEvent {
    TokenEvent(session: .init(agent: .codex, nativeID: "synthetic"), timestamp: timestamp,
               model: model, counts: counts, precision: precision, dedupeKey: "synthetic")
}

@Suite("FR-COST: pure synthetic pricing")
struct ADPricingTests {
    @Test("Typed decode preserves Decimal, dates, static display rates and metadata")
    func typedDecode() throws {
        let table = try PriceTable.decode(document(extra: """
        ,"displayCurrencies":[{"code":"CNY","ratePerUSD":7.125,"asOf":"2026-11-18"}]
        """))
        #expect(table.schemaVersion == 1)
        #expect(table.currency == "USD")
        #expect(table.unit == "per_million_tokens")
        #expect(table.updatedAt == (try UTCDate("2026-11-19")))
        #expect(table.models.first?.prices.first?.rates.cacheRead == Decimal(string: "0.25"))
        #expect(table.displayCurrencies.first?.ratePerUSD == Decimal(string: "7.125"))
        #expect(table.models.first?.prices.first?.source == "https://example.invalid/synthetic")
        // Precision checks apply to numeric values, with leading/trailing zeroes excluded.
        let tiny = try PriceTable.decode(document(models: model(prices:
            price(input: "0.00000000000000000000000000000000000000001"))))
        #expect(tiny.models.first?.prices.first?.rates.input == Decimal(string: "1e-41"))
        let quoted = String(decoding: document(), as: UTF8.self).replacingOccurrences(
            of: "\"displayName\":\"Synthetic\"",
            with: #""displayName":"Synthetic \"999999999999999999999999999999999999999999\"""#)
        #expect(try PriceTable.decode(Data(quoted.utf8)).models.first?.displayName.hasPrefix("Synthetic") == true)
    }

    @Test("Alias first, then canonical exact, then most specific glob; stable ties")
    func matching() throws {
        let models = [
            model("openai/synthetic-broad", matches: #"["synthetic-*"]"#),
            model("anthropic/synthetic-alpha", matches: #"["synthetic-alpha-*"]"#),
            model("xai/synthetic-tie", matches: #"["synthetic-alpha-?"]"#)
        ].joined(separator: ",")
        let table = try PriceTable.decode(document(models: models, aliases: #"{"OLD":"anthropic/synthetic-alpha"}"#))
        #expect(table.match(model: " OpenAI/OLD ")?.kind == .alias)
        #expect(table.match(model: "old")?.model.id == "anthropic/synthetic-alpha")
        #expect(table.match(model: "ANTHROPIC/SYNTHETIC-ALPHA")?.kind == .exact)
        #expect(table.match(model: "synthetic-alpha-x")?.model.id == "anthropic/synthetic-alpha")
        #expect(table.match(model: "synthetic-alpha-x")?.kind == .glob)
        #expect(table.match(model: "synthetic-else")?.model.id == "openai/synthetic-broad")
        #expect(table.match(model: "other") == nil)
        // A literal match entry wins over a less specific glob.
        let exact = try PriceTable.decode(document(models: models + "," +
            model("synthetic-literal", matches: #"["synthetic-alpha-x"]"#)))
        #expect(exact.match(model: "synthetic-alpha-x")?.model.id == "synthetic-literal")
        #expect(exact.match(model: "synthetic-alpha-x")?.kind == .exact)
    }

    @Test("Globs are anchored, support zero-length star and one-character question mark")
    func globBoundaries() throws {
        let table = try PriceTable.decode(document(models: model(matches: #"["unit-*-?"]"#)))
        for value in ["unit--a", "unit-middle-b", "unit-a-b-c"] {
            #expect(table.match(model: value) != nil)
        }
        for value in ["xunit--a", "unit--", "unit--ab", "unit-middle"] {
            #expect(table.match(model: value) == nil)
        }
        let all = try PriceTable.decode(document(models: model(matches: #"["*"]"#)))
        #expect(all.match(model: " ") == nil)
        #expect(all.match(model: "synthetic-other") != nil)
    }

    @Test("Latest effective date is selected in UTC, independent of JSON order")
    func dates() throws {
        let table = try PriceTable.decode(document(models: model(prices:
            price("2026-02-01", input: "5") + "," + price())))
        let boundary: Int64 = 1_769_904_000_000 // 2026-02-01T00:00:00Z
        #expect(table.price(model: "synthetic-alpha", at: boundary - 1)?.price.rates.input == 2)
        #expect(table.price(model: "synthetic-alpha", at: boundary)?.price.rates.input == 5)
        #expect(table.price(model: "synthetic-alpha", at: 1_767_225_599_999) == nil)
        #expect(table.price(model: "synthetic-alpha", at: Int64.max)?.price.rates.input == 5)
        let epoch = try PriceTable.decode(document(models: model(prices: price("1970-01-01"))))
        #expect(epoch.price(model: "synthetic-alpha", at: -1) == nil)
        #expect(epoch.price(model: "synthetic-alpha", at: 0) != nil)
        let old = try PriceTable.decode(document(models: model(prices: price("1969-12-31"))))
        #expect(old.price(model: "synthetic-alpha", at: -1) != nil)
        #expect(old.price(model: "synthetic-alpha", at: Int64.min) == nil)
    }

    @Test("All cache components count once; reasoning is already inside output")
    func goldenCost() throws {
        let table = try PriceTable.decode(document())
        let input = event()
        let result = try table.estimate(input)
        // 11*2 + 23*0.25 + 5*3 + 7*4 + 13*7 = 161.75 micro-USD -> 162.
        #expect(result.costMicroUSD == 162)
        #expect(result.status == .priced)
        #expect(result.unpricedTokens == 0)
        #expect(result.appliedTierThreshold == nil)
        #expect(input == event())
    }

    @Test("Round once per event: nearest micro-USD, nonnegative half up",
          arguments: [("0.1", "0.2", Int64(0)), ("0.25", "0.25", 1),
                      ("0.75", "0.75", 2), ("0.49", "0", 0), ("0.5", "0", 1)])
    func rounding(values: (String, String, Int64)) throws {
        let table = try PriceTable.decode(document(models: model(prices:
            price(input: values.0, output: values.1))))
        let result = try table.estimate(event(counts: .init(inputFresh: 1, output: 1)))
        #expect(result.costMicroUSD == values.2)
    }

    @Test("Per-call tiers are strictly above, include every prompt component, and price the whole call")
    func tiers() throws {
        let tiers = #", "tiers":[{"whenPromptTokensAbove":10,"input":5,"output":11,"cacheRead":1,"cacheWrite5m":7,"cacheWrite1h":9},{"whenPromptTokensAbove":20,"input":10,"output":20,"cacheRead":2,"cacheWrite5m":14,"cacheWrite1h":18}]"#
        let table = try PriceTable.decode(document(models: model(prices: price(tiers: tiers))))
        let counts = TokenCounts(inputFresh: 1, cacheRead: 2, cacheWrite: 3, cacheWrite1h: 4, output: 100)
        let exact = try table.estimate(event(counts: counts))
        #expect(exact.appliedTierThreshold == nil) // prompt=10, output never triggers a tier
        #expect(exact.costMicroUSD == 728) // 2 + .5 + 9 + 16 + 700 = 727.5
        var over = counts
        over.cacheWrite1h = 5 // prompt=11; all rates become tier rates
        let first = try table.estimate(event(counts: over))
        #expect(first.appliedTierThreshold == 10)
        #expect(first.costMicroUSD == 1173) // 5 + 2 + 21 + 45 + 1100
        over.inputFresh = 10 // prompt=20, still first tier
        #expect(try table.estimate(event(counts: over)).appliedTierThreshold == 10)
        over.inputFresh = 11 // prompt=21, highest qualifying tier
        #expect(try table.estimate(event(counts: over)).costMicroUSD == 2246)
        #expect(try table.estimate(event(counts: over)).appliedTierThreshold == 20)
        for precision in [TokenPrecision.snapshot, .checkpoint] {
            let coarse = try table.estimate(event(counts: over, precision: precision))
            #expect(coarse.costMicroUSD == 752) // 22 + .5 + 9 + 20 + 700 = 751.5
            #expect(coarse.appliedTierThreshold == nil)
            #expect(coarse.status == .approximate([.coarsePrecision]))
        }
    }

    @Test("Only consumed missing cache prices fall back to selected input and mark approximate")
    func missingCache() throws {
        let table = try PriceTable.decode(document(models: model(prices: price(cache: ""))))
        let result = try table.estimate(event())
        #expect(result.costMicroUSD == 183) // (11+23+5+7)*2 + 13*7
        #expect(result.status == .approximate([.missingCacheReadPrice, .missingCacheWrite5mPrice,
                                               .missingCacheWrite1hPrice]))
        #expect(try table.estimate(event(counts: .init(output: 1))).status == .priced)
        let tier = #", "tiers":[{"whenPromptTokensAbove":0,"input":10,"output":20}]"#
        let tiered = try PriceTable.decode(document(models: model(prices: price(tiers: tier))))
        #expect(try tiered.estimate(event()).costMicroUSD == 720) // prompt=46 at 10 + 13*20
        #expect(try tiered.estimate(event()).status == result.status)
        #expect(try table.estimate(event(precision: .snapshot)).status == .approximate([
            .coarsePrecision, .missingCacheReadPrice, .missingCacheWrite5mPrice, .missingCacheWrite1hPrice
        ]))
        let explicitZero = try PriceTable.decode(document(models: model(prices:
            price(cache: #", "cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0"#))))
        #expect(try explicitZero.estimate(event()).costMicroUSD == 113)
        #expect(try explicitZero.estimate(event()).status == .priced)
    }

    @Test("Missing model, unmatched model and not-yet-effective price are explicit unpriced results")
    func unpriced() throws {
        let table = try PriceTable.decode(document())
        for (value, reason) in [(event(model: nil), UnpricedReason.missingModel),
                                (event(model: "  "), .missingModel),
                                (event(model: "unknown"), .noMatchingModel),
                                (event(timestamp: 0), .noEffectivePrice)] {
            let result = try table.estimate(value)
            #expect(result.status == .unpriced(reason))
            #expect(result.costMicroUSD == 0)
            #expect(result.unpricedTokens == 59)
            #expect(result.selection == nil)
        }
        let free = try PriceTable.decode(document(models: model(prices: price(input: "0", output: "0", cache: ""))))
        let zero = try free.estimate(event(counts: .init(inputFresh: 3)))
        #expect(zero.costMicroUSD == 0)
        #expect(zero.status == .priced)
        #expect(zero.unpricedTokens == 0)
    }

    @Test("Invalid and overflowing event counts fail without trapping, including unpriced events")
    func invalidCounts() throws {
        let table = try PriceTable.decode(document())
        for counts in [TokenCounts(inputFresh: -1), .init(cacheRead: -1), .init(cacheWrite: -1),
                       .init(cacheWrite1h: -1), .init(output: -1), .init(reasoning: -1),
                       .init(output: 1, reasoning: 2)] {
            #expect(throws: PricingError.invalidTokenCounts) { try table.estimate(event(counts: counts)) }
        }
        #expect(throws: PricingError.tokenCountOverflow) {
            try table.estimate(event(model: nil, counts: .init(inputFresh: .max, output: 1)))
        }
        let large = try PriceTable.decode(document(models: model(prices: price(input: "1", output: "0"))))
        #expect(try large.estimate(event(counts: .init(inputFresh: .max))).costMicroUSD == Int64.max)
        #expect(throws: PricingError.unrepresentableCost) {
            try table.estimate(event(counts: .init(inputFresh: .max)))
        }
        let precision = try PriceTable.decode(document(models: model(prices:
            price(input: "0.12345678901234567890123456789012345678"))))
        #expect(throws: PricingError.unrepresentableCost) {
            try precision.estimate(event(counts: .init(inputFresh: .max)))
        }
        // A wide coefficient still fits exactly when multiplying by one or a power of ten.
        #expect(try precision.estimate(event(counts: .init(inputFresh: 1))).costMicroUSD == 0)
        #expect(try precision.estimate(event(counts: .init(inputFresh: 1_000_000_000_000_000_000)))
            .costMicroUSD == 123_456_789_012_345_679)
        let addition = try PriceTable.decode(document(models: model(prices:
            price(input: "1", output: "1e-128"))))
        #expect(throws: PricingError.unrepresentableCost) {
            try addition.estimate(event(counts: .init(inputFresh: Int64.max - 1, output: 1)))
        }
    }

    @Test("Required fields and numeric types cannot be bypassed by nulls or strings")
    func decodingFailures() {
        let valid = String(decoding: document(), as: UTF8.self)
        for (old, new) in [("\"input\":2", "\"input\":null"),
                           ("\"input\":2", "\"input\":\"2\""),
                           ("\"output\":7", "\"output\":true"),
                           ("\"input\":2", "\"input\":1e999"),
                           ("\"input\":2", "\"input\":0.9999999999999999999999999999999999999999"),
                           ("\"source\":\"https://example.invalid/synthetic\",", ""),
                           ("\"checkedAt\":\"2026-11-19\"", "\"private/path/SECRET\":\"hidden\"")] {
            let data = Data(valid.replacingOccurrences(of: old, with: new).utf8)
            #expect(throws: PricingError.invalidJSON) { try PriceTable.decode(data) }
        }
    }

    @Test("Pricing JSON is UTF-8; both other endian forms fail before Decimal decoding")
    func inputEncoding() throws {
        let excessive = "0." + String(repeating: "9", count: 40)
        let invalid = document(models: model(prices: price(input: excessive)))
        #expect(throws: PricingError.invalidJSON) { try PriceTable.decode(invalid) }
        for data in [document(), invalid] {
            let source = String(decoding: data, as: UTF8.self)
            for (encoding, bom): (String.Encoding, [UInt8]) in [
                (.utf16LittleEndian, [0xFF, 0xFE]), (.utf16BigEndian, [0xFE, 0xFF]),
                (.utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00]), (.utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF])
            ] {
                let encoded = try #require(source.data(using: encoding))
                for bytes in [encoded, Data(bom) + encoded] {
                    #expect(throws: PricingError.invalidJSON) { try PriceTable.decode(bytes) }
                }
            }
        }
        #expect(try PriceTable.decode(document()).models.count == 1)
    }

    @Test("Conflicting prices and aliases cannot hide behind duplicate member names")
    func duplicateMembers() {
        for (first, second) in [(1, 9), (9, 1)] {
            let row = price(input: String(first), cache: ",\"input\":\(second)")
            #expect(throws: PricingError.invalidJSON) {
                try PriceTable.decode(document(models: model(prices: row)))
            }
        }
        let escapedTier = price(tiers: #", "tiers":[{"whenPromptTokensAbove":1,"in\u0070ut":1,"input":9,"output":1}]"#)
        let aliases = #"{"old":"synthetic-alpha","ol\u0064":"synthetic-beta"}"#
        #expect(throws: PricingError.invalidJSON) {
            try PriceTable.decode(document(models: model(prices: escapedTier)))
        }
        #expect(throws: PricingError.invalidJSON) {
            try PriceTable.decode(document(models: model() + "," + model("synthetic-beta"), aliases: aliases))
        }
    }

    @Test("Validation rejects semantic conflicts with content-free typed errors")
    func validation() throws {
        let bad: [(Data, PricingError)] = [
            (Data(#"{"private/path":"SECRET"}"#.utf8), .invalidJSON),
            (document(models: model(prices: price() + "," + price())), .duplicateEffectiveDate),
            (document(models: model() + "," + model("ANTHROPIC/SYNTHETIC-ALPHA")), .duplicateModel),
            (document(models: model(matches: #"["XAI/shared-*"]"#) + "," +
                      model("synthetic-other", matches: #"["shared-*"]"#)), .conflictingMatch),
            (document(models: model("synthetic-a", matches: #"["synthetic-b"]"#) + "," + model("synthetic-b")), .conflictingMatch),
            (document(aliases: #"{"alias":"missing"}"#), .invalidAlias),
            (document(aliases: #"{"ALIAS":"synthetic-alpha","openai/alias":"synthetic-alpha"}"#), .invalidAlias),
            (document(aliases: #"{"a":"b","b":"a"}"#), .invalidAlias),
            (document(models: model("")), .invalidModel),
            (document(models: model(prices: "")), .emptyPrices),
            (document(models: model(matches: #"[""]"#)), .invalidMatchPattern),
            (document(models: model(prices: price(input: "-0.1"))), .invalidPrice),
            (document(models: model(prices: price(cache: #", "cacheRead":-1"#))), .invalidPrice),
            (document(models: model(prices: price("2026-02-29"))), .invalidDate),
            (document(models: model(prices: price(tiers: #", "tiers":[{"whenPromptTokensAbove":2,"input":1,"output":1},{"whenPromptTokensAbove":1,"input":1,"output":1}]"#))), .invalidTier),
            (document(models: model(prices: price(tiers: #", "tiers":[{"whenPromptTokensAbove":1,"input":1,"output":1},{"whenPromptTokensAbove":1,"input":1,"output":1}]"#))), .invalidTier),
            (document(models: model(prices: price(tiers: #", "tiers":[{"whenPromptTokensAbove":-1,"input":1,"output":1}]"#))), .invalidTier),
            (document(extra: #", "displayCurrencies":[{"code":"CNY","ratePerUSD":0,"asOf":"2026-11-19"}]"#), .invalidDisplayCurrency)
        ]
        for (data, error) in bad {
            #expect(throws: error) { try PriceTable.decode(data) }
        }
        for (old, new, error) in [("\"schemaVersion\":1", "\"schemaVersion\":2", PricingError.unsupportedSchemaVersion),
                                  ("\"currency\":\"USD\"", "\"currency\":\"CNY\"", .invalidCurrency),
                                  ("per_million_tokens", "per_token", .invalidUnit)] {
            let data = Data(String(decoding: document(), as: UTF8.self).replacingOccurrences(of: old, with: new).utf8)
            #expect(throws: error) { try PriceTable.decode(data) }
        }
    }

    @Test("Strict Gregorian UTC dates, including leap century boundaries")
    func dateValidation() throws {
        for valid in ["0001-01-01", "2000-02-29", "2024-02-29", "9999-12-31"] {
            #expect(try UTCDate(valid).rawValue == valid)
        }
        for invalid in ["0000-01-01", "1900-02-29", "2026-04-31", "2026-13-01", "2026-00-01",
                        "2026-1-01", "2026-01-00", "2026-01-01Z", " 2026-01-01", "２０２６-01-01"] {
            #expect(throws: PricingError.invalidDate) { try UTCDate(invalid) }
        }
    }
}
