import ADCore
@testable import ADPricing
import Foundation
import Testing

private func baselineTable() throws -> PriceTable {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    return try PriceTable.decode(Data(contentsOf: root.appending(path: "pricing/pricing.json")))
}

private func baselineQuote(_ table: PriceTable, _ model: String, on day: String = "2026-11-20",
                           counts: TokenCounts) throws -> CostEstimate {
    try table.estimate(.init(session: .init(agent: .codex, nativeID: "synthetic-baseline"),
                             timestamp: UTCDate(day).epochDay * 86_400_000, model: model,
                             counts: counts, dedupeKey: "synthetic:baseline"))
}

@Test("FR-COST: the official baseline applies published whole-prompt price boundaries")
func officialPriceBaselineBoundaries() throws {
    let table = try baselineTable()
    let openAIShort = try baselineQuote(table, "gpt-6.2-sol", counts: .init(inputFresh: 271_000, cacheRead: 1_000, output: 100))
    let openAILong = try baselineQuote(table, "gpt-6.2-sol", counts: .init(inputFresh: 271_001, cacheRead: 1_000, output: 100))
    #expect(openAIShort.costMicroUSD == 543_100 && openAIShort.appliedTierThreshold == nil)
    #expect(openAILong.costMicroUSD == 1_085_704 && openAILong.appliedTierThreshold == 272_000)

    let xAIShort = try baselineQuote(table, "grok-4.7", counts: .init(inputFresh: 199_899, cacheRead: 100, output: 10))
    let xAILong = try baselineQuote(table, "grok-4.7", counts: .init(inputFresh: 199_900, cacheRead: 100, output: 10))
    #expect(xAIShort.costMicroUSD == 399_908 && xAIShort.appliedTierThreshold == nil)
    #expect(xAILong.costMicroUSD == 799_820 && xAILong.appliedTierThreshold == 199_999)

    let claudeShort = try baselineQuote(table, "claude-haiku-5-5", counts: .init(inputFresh: 99_100, cacheRead: 600,
                                                                               cacheWrite: 200, cacheWrite1h: 100, output: 100))
    let claudeLong = try baselineQuote(table, "claude-haiku-5-5", counts: .init(inputFresh: 99_101, cacheRead: 600,
                                                                              cacheWrite: 200, cacheWrite1h: 100, output: 100))
    #expect(claudeShort.costMicroUSD == 10_011 && claudeShort.appliedTierThreshold == nil)
    #expect(claudeLong.costMicroUSD == 50_056 && claudeLong.appliedTierThreshold == 100_000)
}

@Test("FR-COST: the official baseline keeps verified rate history and does not guess unmapped pricing")
func officialPriceBaselineHistoryAndGaps() throws {
    let table = try baselineTable()
    let oldClaude = try baselineQuote(table, "claude-sonnet-5-5", on: "2026-10-06", counts: .init(cacheRead: 100))
    let newClaude = try baselineQuote(table, "claude-sonnet-5-5", on: "2026-10-07", counts: .init(cacheRead: 100))
    #expect(oldClaude.costMicroUSD == 20 && newClaude.costMicroUSD == 10)
    #expect(table.match(model: "claude-sonnet-4-5")?.model.id == "claude-sonnet-4-5-20250929")

    let beforeEvidence = try baselineQuote(table, "gpt-6.2-sol", on: "2026-11-19", counts: .init(inputFresh: 10))
    let unknown = try baselineQuote(table, "gpt-6.2-sol-not-an-official-model", counts: .init(inputFresh: 10))
    let unsupportedTTL = try baselineQuote(table, "gpt-6.2-sol", counts: .init(cacheWrite: 10))
    #expect(beforeEvidence.status == .unpriced(.noEffectivePrice))
    #expect(unknown.status == .unpriced(.noMatchingModel))
    #expect(unsupportedTTL.status == .approximate([.missingCacheWrite5mPrice]))
}

@Test("FR-COST: Grok Build 0.1 uses its own rates and switches tiers at 200,000 prompt tokens")
func officialPriceBaselineGrokBuild() throws {
    let table = try baselineTable()
    let short = try baselineQuote(table, "grok-build-0.1", counts: .init(inputFresh: 199_899, cacheRead: 100, output: 10))
    let long = try baselineQuote(table, "grok-build-0.1", counts: .init(inputFresh: 199_900, cacheRead: 100, output: 10))
    #expect(short.status == .priced && short.costMicroUSD == 199_939 && short.appliedTierThreshold == nil)
    #expect(long.status == .priced && long.costMicroUSD == 399_880 && long.appliedTierThreshold == 199_999)
    let earlier = try baselineQuote(table, "grok-build-0.1", on: "2026-11-19", counts: .init(inputFresh: 100))
    #expect(earlier.status == .unpriced(.noEffectivePrice))
}

@Test("FR-COST: GPT-5.6 alias follows its dated standard rates but never extends the promotion")
func officialPriceBaselineSolPromotion() throws {
    let table = try baselineTable()
    let counts = TokenCounts(inputFresh: 1_000, cacheRead: 100, output: 10)
    #expect(table.match(model: "gpt-5.6")?.model.id == "gpt-5.6-sol")
    let initial = try baselineQuote(table, "gpt-5.6", on: "2026-08-20", counts: counts)
    let firstPromo = try baselineQuote(table, "gpt-5.6", on: "2026-08-21", counts: counts)
    let lastPromo = try baselineQuote(table, "gpt-5.6-sol", on: "2026-11-30", counts: counts)
    let afterPromo = try baselineQuote(table, "gpt-5.6", on: "2026-12-01", counts: counts)
    #expect(initial.status == .priced && initial.costMicroUSD == 5_350)
    #expect(firstPromo.status == .priced && firstPromo.costMicroUSD == 4_240)
    #expect(lastPromo.status == .priced && lastPromo.costMicroUSD == 4_240)
    #expect(afterPromo.status == .unpriced(.noEffectivePrice) && afterPromo.unpricedTokens == 1_110)
}

@Test("FR-COST: Fable 5.1 includes the rates published on its September launch")
func officialPriceBaselineFableHistory() throws {
    let table = try baselineTable()
    let counts = TokenCounts(inputFresh: 1_000, cacheRead: 200, cacheWrite: 40, cacheWrite1h: 25, output: 20)
    let before = try baselineQuote(table, "claude-fable-5-1", on: "2026-08-31", counts: counts)
    let launch = try baselineQuote(table, "claude-fable-5-1", on: "2026-09-01", counts: counts)
    let later = try baselineQuote(table, "claude-fable-5-1", on: "2026-11-19", counts: counts)
    #expect(before.status == .unpriced(.noEffectivePrice))
    #expect(launch.status == .priced && launch.costMicroUSD == 12_050)
    #expect(later == launch)
}
