import ADCore
import Foundation
import GRDB
import Testing
@testable import ADStore

@Test("NFR-5: period query latency and exact totals on one million token events",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_USAGE_BENCHMARK"] == "1"
          || ProcessInfo.processInfo.environment["AGENTDASH_COST_BENCHMARK"] == "1"))
func millionUsagePeriodQueries() throws {
    let metric: UsageMetric = ProcessInfo.processInfo.environment["AGENTDASH_COST_BENCHMARK"] == "1" ? .cost : .tokens
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-usage-bench-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let cx = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp.appendingPathComponent("cx")))
    let saved = try store.upsertSource(.init(agent: .copilot, label: "Synthetic", rootURL: temp.appendingPathComponent("cp")))
    let base: Int64 = 1_791_000_000_000
    try store.databasePool.write { db in
        try db.execute(sql: """
            WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<2000)
            INSERT INTO sessions(id,agent,native_id,source_id,environment,status)
            SELECT n,CASE n%2 WHEN 1 THEN 'codex' ELSE 'copilot' END,'synthetic-'||n,
                   CASE n%2 WHEN 1 THEN ? ELSE ? END,'Synthetic','completed' FROM seq
            """, arguments: [cx, saved])
        try db.execute(sql: """
            WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM seq WHERE n<1000000)
            INSERT INTO token_events(session_id,agent,model,ts,input_fresh,cache_read,output,precision,dedupe_key,
                                     cost_micro_usd,price_status,cache_savings_micro_usd)
            SELECT 1+n%2000,CASE n%2 WHEN 0 THEN 'codex' ELSE 'copilot' END,'synthetic-'||(n%8),
                   ?+n*7776,10,2,3,CASE WHEN n%15=0 THEN 'checkpoint' ELSE 'call' END,'synthetic-token-'||n,
                   CASE WHEN ? AND n%7<>0 THEN 10+n%31 ELSE 0 END,
                   CASE WHEN NOT ? OR n%7=0 THEN 'unpriced' WHEN n%15=0 THEN 'approx' ELSE 'priced' END,
                   CASE WHEN ? AND n%7<>0 THEN 2+n%5 END
            FROM seq
            """, arguments: [base, metric == .cost, metric == .cost, metric == .cost])
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events") == 1_000_000)
        try UsageChartChanges.publish(db)
    }
    let now = base + 7_776_000_001
    let custom = try UsageRange(lowerBound: base + 2_500_000_017, upperBound: base + 5_000_000_019)
    let displayZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let clock = ContinuousClock()
    for period in UsagePeriod.allCases {
        let window = try UsageWindow.make(period, now: now, firstTimestamp: base + 7776, custom: custom, timeZone: displayZone)
        let count = try store.databasePool.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events WHERE ts>=? AND ts<?",
                             arguments: [window.range.lowerBound, window.range.upperBound]) ?? 0
        }
        let expected = try store.databasePool.read { db -> (cost: Int64, savings: Int64, measured: Int64) in
            let row = try Row.fetchOne(db, sql: """
                SELECT coalesce(sum(cost_micro_usd),0) AS cost,coalesce(sum(cache_savings_micro_usd),0) AS savings,
                    coalesce(sum(cache_read) FILTER(WHERE cache_savings_micro_usd IS NOT NULL),0) AS measured
                FROM token_events WHERE ts>=? AND ts<?
                """, arguments: [window.range.lowerBound, window.range.upperBound])
            return (row?["cost"] ?? 0, row?["savings"] ?? 0, row?["measured"] ?? 0)
        }
        _ = try store.usage(window: window, metric: metric)
        var samples: [Double] = []
        for _ in 0..<10 {
            let start = clock.now
            let report = try store.usage(window: window, metric: metric)
            let duration = start.duration(to: clock.now).components
            samples.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            #expect(report.totals.records == count && report.totals.counts.total == Int64(count) * 15)
            #expect(report.points.reduce(0) { $0 + $1.totals.counts.total } == report.totals.counts.total)
            #expect(report.totals.costMicroUSD == expected.cost)
            #expect(report.points.reduce(0) { $0 + $1.totals.costMicroUSD } == expected.cost)
            #expect(report.cacheSavings?.microUSD == expected.savings)
            #expect(report.cacheSavings?.measuredCacheReadTokens == expected.measured)
        }
        let p95 = samples.sorted()[9]
        print("Synthetic usage \(metric.rawValue) \(period.rawValue): P95 \(p95.formatted(.number.precision(.fractionLength(1)))) ms")
        #expect(p95 < 100)
    }
    let chart = try store.usageChart(period: .quarter, now: now, timeZone: displayZone)
    let next = now + 5_000
    let full = try store.usageChart(period: .quarter, now: next, timeZone: displayZone)
    var chartTimes: [Double] = []
    for _ in 0..<10 {
        let start = clock.now
        let refreshed = try store.usageChart(period: .quarter, now: next, timeZone: displayZone, reusing: chart)
        let duration = start.duration(to: clock.now).components
        chartTimes.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
        #expect(refreshed == full && refreshed.reusedBuckets.count >= 85)
    }
    let chartP95 = chartTimes.sorted()[9]
    print("Synthetic live 90D chart: P95 \(chartP95.formatted(.number.precision(.fractionLength(1)))) ms")
    #expect(chartP95 < 100)
}
