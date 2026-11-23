import ADCore
import ADInsights
import Foundation
import Testing
@testable import ADStore

@Test("FR-TK: live append refreshes the two edges and reuses clean smoothed lanes")
func incrementalChartAppend() throws {
    try withLiveUsage { store, session in
        func row(_ key: String, _ time: Int64, _ tokens: Int64, _ precision: TokenPrecision = .call) -> NormalizedRecord {
            .tokens(.init(session: session, timestamp: time, counts: .init(output: tokens), precision: precision,
                          dedupeKey: key))
        }
        try store.write([
            row("synthetic-expiring", 5_100, 11),
            row("synthetic-middle", 600_001, 13),
            row("synthetic-prior-tail", 3_600_100, 1),
        ])
        let base = try store.usageChart(period: .hour, now: 3_605_000, timeZone: .gmt)
        let oldPlot = UsagePlot(chart: base, period: .hour, metric: .tokens)
        try store.write([
            row("synthetic-append", 3_606_000, 20),
            row("synthetic-coarse", 3_606_001, 100, .checkpoint),
        ])
        let updated = try store.usageChart(period: .hour, now: 3_610_000, timeZone: .gmt, reusing: base)
        let complete = try store.usageChart(period: .hour, now: 3_610_000, timeZone: .gmt)
        #expect(updated == complete)
        #expect(updated.reusedBuckets.contains(600_000))
        #expect(!updated.reusedBuckets.contains(0) && !updated.reusedBuckets.contains(3_600_000))
        #expect(updated.recent?.counts.total == 21)
        #expect(updated.cumulative(.tokens) == 134)
        let incremental = UsagePlot(chart: updated, period: .hour, metric: .tokens, reusing: oldPlot)
        let rebuilt = UsagePlot(chart: complete, period: .hour, metric: .tokens)
        #expect(incremental == rebuilt)
        #expect(incremental.rebuiltBucketCount < 10 && rebuilt.rebuiltBucketCount > 50)
    }
}

@Test("FR-TK: live charts repair moved events and fall back safely for unpublished mutations")
func incrementalChartCorrection() throws {
    try withLiveUsage { store, session in
        func event(_ key: String, _ time: Int64, _ tokens: Int64) -> NormalizedRecord {
            .tokens(.init(session: session, timestamp: time, counts: .init(output: tokens), dedupeKey: key))
        }
        try store.write([event("synthetic-move", 60_001, 5), event("synthetic-stable", 540_001, 11)])
        let range = try UsageRange(lowerBound: 0, upperBound: 600_000)
        let base = try store.usageChart(period: .custom, now: 610_000, timeZone: .gmt, custom: range)
        try store.write([event("synthetic-move", 240_001, 7)])
        let corrected = try store.usageChart(period: .custom, now: 610_000, timeZone: .gmt, custom: range, reusing: base)
        #expect(corrected.reusedBuckets.contains(540_000))
        #expect(corrected.points.map(\.timestamp) == [240_000, 540_000])
        #expect(corrected.cumulative(.output) == 18)
        #expect(corrected.recent == nil)

        try store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM token_events WHERE dedupe_key='synthetic-stable'")
        }
        let fallback = try store.usageChart(period: .custom, now: 610_000, timeZone: .gmt, custom: range, reusing: corrected)
        #expect(fallback.reusedFrom == nil && fallback.reusedBuckets.isEmpty)
        #expect(fallback.cumulative(.tokens) == 7)
    }
}

@Test("FR-TK: a quote batch invalidates an older day without discarding clean days")
func incrementalChartBatchQuote() throws {
    try withLiveUsage { store, session in
        let day: Int64 = 86_400_000
        try store.write([.tokens(.init(session: session, timestamp: day + 1, model: "synthetic-model",
                                     counts: .init(output: 5), dedupeKey: "synthetic-quote"))])
        let now = day * 3 + 1
        let base = try store.usageChart(period: .month, now: now, timeZone: .gmt)
        let basis = TokenRateBasis(reference: "synthetic-rates", bytes: Data([1]))
        let sweep = try store.activatePricing { _, original in
            TokenQuote(microUSD: 29, status: .priced, basis: original ?? basis)
        }
        #expect(try store.backfillUnpriced(sweep).priced == 1)
        let priced = try store.usageChart(period: .month, now: now, timeZone: .gmt, reusing: base)
        let full = try store.usageChart(period: .month, now: now, timeZone: .gmt)
        #expect(priced == full)
        #expect(!priced.reusedBuckets.contains(day))
        #expect(priced.reusedBuckets.contains(day * 2))
        #expect(priced.cumulative(.cost) == 29)
    }
}

@Test("FR-TK: a chart older than the bounded change journal reads a fresh timeline")
func incrementalChartJournalGap() throws {
    try withLiveUsage { store, session in
        let range = try UsageRange(lowerBound: 0, upperBound: 600_000)
        func write(_ value: Int64) throws {
            try store.write([.tokens(.init(session: session, timestamp: 60_001, counts: .init(output: value),
                                           dedupeKey: "synthetic-rolling-row"))])
        }
        try write(1)
        let base = try store.usageChart(period: .custom, now: range.upperBound, timeZone: .gmt, custom: range)
        for value in 2...130 { try write(Int64(value)) }
        let resumed = try store.usageChart(period: .custom, now: range.upperBound, timeZone: .gmt, custom: range, reusing: base)
        #expect(resumed.reusedBuckets.isEmpty && resumed.reusedFrom == nil)
        #expect(resumed.cumulative(.tokens) == 130)
    }
}

private func withLiveUsage(_ body: (AgentStore, SessionKey) throws -> Void) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-live-chart-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp))
    let session = SessionKey(agent: .codex, nativeID: "synthetic-chart")
    try store.write([.session(.init(key: session, sourceID: source, environment: "Synthetic"))])
    try body(store, session)
}
