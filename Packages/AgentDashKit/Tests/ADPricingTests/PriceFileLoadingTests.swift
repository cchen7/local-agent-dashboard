import ADPricing
import Foundation
import Testing

@Test("FR-COST: the validated file supplies dated display rates without changing micro-USD")
func verifiedDisplayCurrency() throws {
    let data = Data(#"{"schemaVersion":1,"currency":"USD","unit":"per_million_tokens","updatedAt":"2026-11-19","displayCurrencies":[{"code":"CNY","ratePerUSD":7.25,"asOf":"2026-11-18"}],"models":[]}"#.utf8)
    var resolver = PriceFileResolver()
    let status = resolver.refresh(external: .bytes(data), bundled: .missing)
    let choices = PriceDisplayCurrency.choices(status.displayCurrencies)
    #expect(choices.map(\.code) == ["USD", "CNY"])
    let chinese = try #require(choices.last)
    #expect(chinese.asOf == (try UTCDate("2026-11-18")))
    #expect(chinese.amount(microUSD: 5_000_000) == Decimal(string: "36.25"))
    #expect(PriceDisplayCurrency.usd.amount(microUSD: 5_000_000) == 5)
    let invalid = resolver.refresh(external: .bytes(Data()), bundled: .missing)
    #expect(PriceDisplayCurrency.choices(invalid.displayCurrencies) == choices)
}

private func sampleTable(_ date: String) -> Data {
    Data(#"{"schemaVersion":1,"currency":"USD","unit":"per_million_tokens","updatedAt":"\#(date)","models":[{"id":"synthetic/model","vendor":"synthetic","displayName":"Synthetic","prices":[{"effectiveFrom":"2020-01-01","input":1,"output":2,"source":"https://synthetic.invalid/","checkedAt":"2020-01-01"}]}]}"#.utf8)
}

@Test("FR-COST: invalid external input falls back, and invalid candidates cannot replace verified bytes")
func verifiedTableFallback() throws {
    var resolver = PriceFileResolver()
    let external = sampleTable("2020-01-01"), bundled = sampleTable("2020-01-02")
    let externalStatus = resolver.refresh(external: .bytes(external), bundled: .bytes(bundled))
    #expect(externalStatus.origin == .external && externalStatus.modelCount == 1)
    let invalid = PriceFileCandidate.bytes(Data("not JSON".utf8))
    let fallback = resolver.refresh(external: invalid, bundled: .bytes(bundled))
    #expect(fallback.origin == .lastVerified && fallback.issues == [.init(origin: .external, failure: .invalid(.invalidJSON))])
    #expect(fallback.fingerprint == externalStatus.fingerprint && resolver.verifiedBytes == external)
    let retained = resolver.refresh(external: .unreadable, bundled: .missing)
    #expect(retained.origin == .lastVerified && retained.fingerprint == fallback.fingerprint)
    #expect(resolver.verifiedBytes == external)

    var cold = PriceFileResolver()
    #expect(cold.refresh(external: invalid, bundled: .bytes(bundled)).origin == .bundled)
    var reopened = PriceFileResolver(lastVerified: .bytes(external))
    #expect(reopened.refresh(external: invalid, bundled: .bytes(bundled)).fingerprint == retained.fingerprint)
    #expect(reopened.refresh(external: .missing, bundled: .bytes(bundled)).origin == .bundled)
    var unavailable = PriceFileResolver(lastVerified: .bytes(Data()))
    #expect(unavailable.refresh(external: .missing, bundled: .missing).origin == .none)
}

@Test("FR-COST: price file reads are bounded and reject symlinks")
func boundedPriceFileRead() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-price-reader-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let url = temp.appendingPathComponent("pricing.json")
    if case .missing = PriceFileReader.read(url) {} else { Issue.record("Expected missing candidate") }
    let data = sampleTable("2020-01-01")
    try data.write(to: url)
    if case .bytes(let read) = PriceFileReader.read(url) { #expect(read == data) } else { Issue.record("Expected stable bytes") }
    if case .unreadable = PriceFileReader.read(url, maxBytes: 32) {} else { Issue.record("Expected bounded rejection") }
    let link = temp.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    if case .unreadable = PriceFileReader.read(link) {} else { Issue.record("Expected symlink rejection") }
    try FileManager.default.removeItem(at: url)
    if case .missing = PriceFileReader.read(url) {} else { Issue.record("Expected deletion at the same URL to look missing") }
    try data.write(to: url, options: .atomic)
    if case .bytes(let read) = PriceFileReader.read(url) { #expect(read == data) } else { Issue.record("Expected replacement bytes") }
}
