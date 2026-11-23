import ADCore
import Testing

@Test("SPEC §10.6: measured capacity takes priority and the longest literal fallback wins")
func resolvesContextWindowFromItsMeasuredModel() throws {
    let rules = [ModelContextWindow(prefix: "model-", tokens: 100),
                 .init(prefix: "model-pro", tokens: 200)]
    let reported = try #require(SessionContextUsage(input: 50, recordedCapacity: 400, model: "model-pro-1", rules: rules))
    #expect(reported.source == .recorded && reported.fraction == 0.125)
    let fallback = try #require(SessionContextUsage(input: 50, recordedCapacity: nil, model: "model-pro-1", rules: rules))
    #expect(fallback.source == .configured && fallback.fraction == 0.25)
    #expect(SessionContextUsage(input: 50, recordedCapacity: nil, model: "Model-pro-1", rules: rules) == nil)
    #expect(SessionContextUsage(input: nil, recordedCapacity: 200, model: "model-pro-1", rules: rules) == nil)
    #expect(!ModelContextWindow.areValid(rules + [.init(prefix: "model-pro", tokens: 200)]))
    #expect(!ModelContextWindow.areValid([.init(prefix: "model pro", tokens: 100)]))
}
