import ADCore
import ADInsights
import ADStore
import Foundation
import Testing

@Test("FR-COST: cost chart normalizes an hourly rate but accumulates exact known micro-USD")
func plotCostRates() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-cost-plot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp))
    let session = SessionKey(agent: .codex, nativeID: "synthetic-cost-plot")
    let basis = TokenRateBasis(reference: "synthetic-basis", bytes: Data([1]))
    _ = try store.activatePricing { input, original in
        guard input.model == "synthetic-priced" else { return nil }
        return TokenQuote(microUSD: input.counts.output * 1_000, status: input.precision == .call ? .priced : .approximate,
                          basis: original ?? basis)
    }
    try store.write([
        .session(.init(key: session, sourceID: source, environment: "Synthetic")),
        .tokens(.init(session: session, timestamp: 1, model: "synthetic-priced",
                      counts: .init(output: 3), dedupeKey: "synthetic-cost")),
        .tokens(.init(session: session, timestamp: 2, model: "synthetic-priced",
                      counts: .init(output: 2), precision: .checkpoint, dedupeKey: "synthetic-hatched")),
        .tokens(.init(session: session, timestamp: 60_000, model: "synthetic-unknown",
                      counts: .init(output: 5), dedupeKey: "synthetic-unpriced")),
    ])
    let window = try UsageWindow.make(.hour, now: 3_600_000, timeZone: .gmt)
    let report = try store.usage(window: window, metric: .cost)
    let plot = UsagePlot(report: report, period: .hour, metric: .cost)
    #expect(plot.axisUnit == .costHour)
    let samples = plot.samples.filter { $0.agent == nil }
    let initial = try #require(samples.first)
    #expect(initial.throughput == 180_000 && initial.coarseThroughput == 120_000)
    #expect(initial.hasPricedUsage && !initial.hasUnpricedUsage)
    let second = try #require(samples.first { $0.timestamp == 60_000 })
    #expect(!second.hasPricedUsage && second.hasUnpricedUsage)
    #expect(samples.last?.cumulative == 5_000)
    let daily = try UsageWindow.make(.month, now: 3_600_000, timeZone: .gmt)
    let dailyPlot = UsagePlot(report: try store.usage(window: daily, metric: .cost), period: .month, metric: .cost)
    #expect(dailyPlot.axisUnit == .costDay)
    #expect(dailyPlot.samples.last(where: { $0.agent == nil })?.throughput == 3_000)
}

@Test("FR-TK: hour smoothing fills empty minutes without changing raw totals or cumulative usage")
func plotSmoothingAndCoarseLane() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-usage-plot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp))
    let key = SessionKey(agent: .codex, nativeID: "synthetic-plot")
    try store.write([
        .session(.init(key: key, sourceID: source, environment: "Synthetic")),
        .tokens(.init(session: key, timestamp: 1000, counts: .init(output: 9), dedupeKey: "synthetic-first")),
        .tokens(.init(session: key, timestamp: 121_000, counts: .init(output: 3), dedupeKey: "synthetic-third")),
        .tokens(.init(session: key, timestamp: 121_001, counts: .init(output: 300), precision: .checkpoint, dedupeKey: "synthetic-fallback")),
    ])
    let window = try UsageWindow.make(.hour, now: 3_600_000, timeZone: .gmt)
    let report = try store.usage(window: window)
    let plot = UsagePlot(report: report, period: .hour, metric: .tokens)
    let combined = plot.samples.filter { $0.agent == nil }
    #expect(Array(combined.prefix(3)).map(\.throughput) == [9, 4.5, 4])
    #expect(combined.first(where: { $0.timestamp == 120_000 })?.coarseThroughput == 300)
    #expect(combined.last?.cumulative == 312 && report.totals.counts.total == 312)
    #expect(report.peak?.value == 9)
}

@Test("FR-TK: daily display keeps exact tokens per calendar day across DST")
func plotLocalDayBounds() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-usage-plot-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp))
    let key = SessionKey(agent: .codex, nativeID: "synthetic-dst")
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let formatter = ISO8601DateFormatter()
    let start = Int64(try #require(formatter.date(from: "2026-03-08T08:00:00Z")).timeIntervalSince1970) * 1_000
    let end = Int64(try #require(formatter.date(from: "2026-03-09T07:00:00Z")).timeIntervalSince1970) * 1_000
    try store.write([
        .session(.init(key: key, sourceID: source, environment: "Synthetic")),
        .tokens(.init(session: key, timestamp: end - 1, counts: .init(output: 23), dedupeKey: "synthetic-dst-last")),
        .tokens(.init(session: key, timestamp: end, counts: .init(output: 24), dedupeKey: "synthetic-dst-next"))
    ])
    let window = try UsageWindow.make(.quarter, now: end + 1, timeZone: zone)
    let plot = UsagePlot(report: try store.usage(window: window), period: .quarter, metric: .tokens)
    let combined = plot.samples.filter { $0.agent == nil }
    let shortDay = try #require(combined.first(where: { $0.timestamp == start }))
    #expect(shortDay.endTimestamp == end && shortDay.throughput == 23)
    #expect(combined.last?.timestamp == end && combined.last?.throughput == 24)
    #expect(combined.last?.cumulative == 47)
}
