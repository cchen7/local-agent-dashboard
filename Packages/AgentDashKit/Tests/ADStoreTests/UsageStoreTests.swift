import ADCore
import Foundation
import GRDB
import Testing
@testable import ADStore

@Test("FR-COST: spend peaks ignore unpriced and coarse events, including partial minutes")
func usageCostMetric() throws {
    try withUsageStore { store, a, b in
        let basis = TokenRateBasis(reference: "synthetic-basis", bytes: Data([1]))
        _ = try store.activatePricing { input, original in
            let amount: Int64
            switch input.model {
            case "synthetic-free": amount = 0
            case "synthetic-priced": amount = input.counts.output * 1_000
            default: return nil
            }
            return TokenQuote(microUSD: amount, status: input.precision == .call ? .priced : .approximate,
                              basis: original ?? basis)
        }
        try store.write([
            .tokens(.init(session: a, timestamp: 60_000, model: "synthetic-free",
                          counts: .init(output: 1), dedupeKey: "synthetic-free")),
            .tokens(.init(session: a, timestamp: 120_000, model: "synthetic-missing",
                          counts: .init(output: 20), dedupeKey: "synthetic-missing")),
            .tokens(.init(session: a, timestamp: 119_000, model: "synthetic-priced",
                          counts: .init(output: 2), dedupeKey: "synthetic-precise-earlier")),
            .tokens(.init(session: a, timestamp: 179_999, model: "synthetic-priced",
                          counts: .init(output: 2), dedupeKey: "synthetic-precise")),
            .tokens(.init(session: b, timestamp: 179_998, model: "synthetic-priced",
                          counts: .init(output: 99), precision: .checkpoint, dedupeKey: "synthetic-coarse")),
            .tokens(.init(session: a, timestamp: 181_000, model: "synthetic-priced",
                          counts: .init(output: 1), dedupeKey: "synthetic-edge")),
            .tokens(.init(session: a, timestamp: 181_001, model: "synthetic-priced",
                          counts: .init(output: 50), dedupeKey: "synthetic-outside")),
        ])
        let window = try UsageWindow.make(.week, now: 181_001, timeZone: .gmt)
        let agents = try store.usage(window: window, metric: .cost)
        let models = try store.usage(window: window, metric: .cost, grouping: .model)
        #expect(agents.peak == UsagePeak(timestamp: 60_000, value: 2_000))
        #expect(models.peak == agents.peak)
        #expect(agents.totals.value(.cost) == 104_000 && agents.totals.unpricedTokens == 20)
        #expect(agents.sessionCount == 2 && models.sessionCount == 2)
        #expect(models.breakdown.map(\.peak?.value) == [2_000, 0, nil])
        #expect(models.breakdown.map(\.totals.hasPricedUsage) == [true, true, false])
    }
}

@Test("FR-COST: very large scoped spend peaks preserve exact value and the earlier tie")
func largeUsageCostPeak() throws {
    try withUsageStore { store, a, _ in
        let basis = TokenRateBasis(reference: "synthetic-large", bytes: Data([1]))
        let amount: Int64 = 1_000_000_000_000_000_000
        _ = try store.activatePricing { _, original in
            TokenQuote(microUSD: amount, status: .priced, basis: original ?? basis)
        }
        try store.write([
            .tokens(.init(session: a, timestamp: 121_000, model: "synthetic-large",
                          counts: .init(output: 1), dedupeKey: "synthetic-late-large")),
            .tokens(.init(session: a, timestamp: 61_000, model: "synthetic-large",
                          counts: .init(output: 1), dedupeKey: "synthetic-early-large")),
        ])
        let window = try UsageWindow.make(.week, now: 181_001, timeZone: .gmt)
        let report = try store.usage(window: window, metric: .cost)
        #expect(report.peak == UsagePeak(timestamp: 60_000, value: amount))
        #expect(report.breakdown.first?.peak == report.peak)
        #expect(report.totals.costMicroUSD == amount * 2)
    }
}

private func withUsageStore(_ body: (AgentStore, SessionKey, SessionKey) throws -> Void) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let cx = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp.appendingPathComponent("cx")))
    let cp = try store.upsertSource(.init(agent: .copilot, label: "Synthetic", rootURL: temp.appendingPathComponent("cp")))
    let a = SessionKey(agent: .codex, nativeID: "synthetic-a"), b = SessionKey(agent: .copilot, nativeID: "synthetic-b")
    try store.write([
        .session(.init(key: a, sourceID: cx, environment: "Synthetic", cwd: "/synthetic/usage")),
        .session(.init(key: b, sourceID: cp, environment: "Synthetic", cwd: "/synthetic/usage")),
    ])
    try body(store, a, b)
}

@Test("FR-TK: minute rollups subtract corrections and move existing usage with its project")
func durableMinuteDeltas() throws {
    try withUsageStore { store, a, b in
        var call = TokenEvent(session: a, timestamp: -1, model: "synthetic-x", counts: .init(inputFresh: 10, cacheRead: 2, output: 4),
                              dedupeKey: "synthetic-call")
        let coarse = TokenEvent(session: b, timestamp: -1, model: "synthetic-y", counts: .init(cacheWrite: 5, output: 20),
                                precision: .checkpoint, dedupeKey: "synthetic-coarse")
        try store.write([.tokens(call), .tokens(call), .tokens(coarse)])
        try store.databasePool.read { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_minute WHERE bucket=-1") == 2)
            #expect(try Int.fetchOne(db, sql: "SELECT sum(records) FROM token_minute") == 2)
        }
        call.timestamp = 60_000
        call.counts = .init(inputFresh: 1, cacheRead: 2, output: 3)
        try store.write([.tokens(call)])
        try store.databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO projects(id,key,display_name) VALUES(1,'synthetic-project','Synthetic');
                UPDATE sessions SET project_id=1
                """)
        }
        let projectID: Int64 = 1
        try store.databasePool.read { db throws -> Void in
            #expect(try Int64.fetchAll(db, sql: "SELECT DISTINCT project_id FROM token_minute") == [projectID])
            #expect(try Int.fetchOne(db, sql: "SELECT unpriced_tokens FROM token_minute WHERE bucket=1 AND precision='call'") == 6)
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_minute WHERE precision='call' AND bucket=-1") == 0)
        }
        try store.databasePool.write { db in try db.execute(sql: "DELETE FROM token_events WHERE dedupe_key='synthetic-coarse'") }
        try store.databasePool.read { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_minute") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT sum(output) FROM token_minute") == 3)
        }
    }
}

@Test("FR-TK: windows use exact partial minutes, split coarse data and compare like durations")
func exactUsageWindow() throws {
    try withUsageStore { store, a, b in
        let events: [TokenEvent] = [
            .init(session: a, timestamp: -1, counts: .init(inputFresh: 9, output: 3), dedupeKey: "previous-a"),
            .init(session: b, timestamp: 14_999, counts: .init(output: 4), dedupeKey: "previous-b"),
            .init(session: a, timestamp: 15_000, model: "synthetic-a", counts: .init(inputFresh: 10, cacheRead: 4, cacheWrite: 2, cacheWrite1h: 1, output: 5, reasoning: 3), dedupeKey: "edge-a"),
            .init(session: b, timestamp: 59_999, model: "synthetic-b", counts: .init(output: 1000), precision: .checkpoint, dedupeKey: "coarse"),
            .init(session: b, timestamp: 60_010, model: "synthetic-b", counts: .init(inputFresh: 2, output: 30), dedupeKey: "minute-b"),
            .init(session: a, timestamp: 119_999, model: "synthetic-a", counts: .init(output: 9), dedupeKey: "minute-a"),
            .init(session: a, timestamp: 120_000, model: "synthetic-a", counts: .init(output: 13), dedupeKey: "edge-b"),
            .init(session: a, timestamp: 135_000, counts: .init(output: 99), dedupeKey: "outside"),
        ]
        try store.write(events.map(NormalizedRecord.tokens))
        let range = try UsageRange(lowerBound: 15_000, upperBound: 135_000)
        let window = try UsageWindow.make(.custom, now: 135_000, custom: range, timeZone: .gmt)
        let report = try store.usage(window: window)
        #expect(report.totals.counts.total == 1076 && report.totals.unpricedTokens == 1076)
        #expect(report.totals.counts.reasoning == 3)
        #expect(report.previous?.counts.total == 16)
        #expect(report.peak == UsagePeak(timestamp: 60_000, value: 41))
        #expect(report.points.filter(\.coarse).reduce(0) { $0 + $1.totals.counts.total } == 1000)
        #expect(report.breakdown.map(\.sessions) == [1, 1])
        let smaller = try store.usage(window: window, filter: .init(agent: .codex), metric: .output, grouping: .model)
        #expect(smaller.totals.counts.total == 44 && smaller.totals.counts.output == 27)
        #expect(smaller.peak == UsagePeak(timestamp: 120_000, value: 13))
        #expect(smaller.breakdown.map(\.label) == ["synthetic-a"])
    }
}

@Test("FR-TK: quota headroom uses the newest scope observation and excludes expired windows")
func quotaHeadroom() throws {
    try withUsageStore { store, _, _ in
        try store.write([
            .rateLimit(.init(agent: .codex, limitID: "synthetic-one", window: .primary, timestamp: 100, usedPercent: 90, resetsAt: 2000)),
            .rateLimit(.init(agent: .codex, limitID: "synthetic-one", window: .primary, timestamp: 200, usedPercent: 20, resetsAt: 2000)),
            .rateLimit(.init(agent: .codex, limitID: "synthetic-two", window: .primary, timestamp: 300, usedPercent: 50, resetsAt: 3000)),
            .rateLimit(.init(agent: .codex, limitID: "synthetic-expired", window: .primary, timestamp: 400, usedPercent: 99, resetsAt: 500)),
            .rateLimit(.init(agent: .codex, limitID: "synthetic-two", window: .secondary, timestamp: 300, usedPercent: 75, resetsAt: 4000)),
        ])
        let limits = try store.codexHeadroom(now: 1000)
        #expect(limits.map(\.window) == [.primary, .secondary])
        #expect(limits.map(\.remaining) == [0.5, 0.25])
        #expect(limits.map(\.resetAt) == [3000, 4000])
    }
}

@Test("FR-TK: daily report bars clip exact rolling edges and split at local midnight",
      arguments: [
        ("Asia/Shanghai", "2026-11-18T16:00:00Z", "2026-11-19T16:00:00Z"),
        ("Asia/Kolkata", "2026-11-18T18:30:00Z", "2026-11-19T18:30:00Z"),
        ("America/Los_Angeles", "2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z"),
        ("America/Los_Angeles", "2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z"),
      ])
func localDayUsage(sample: (zone: String, start: String, end: String)) throws {
    let zone = try #require(TimeZone(identifier: sample.zone))
    let formatter = ISO8601DateFormatter()
    let start = Int64(try #require(formatter.date(from: sample.start)).timeIntervalSince1970) * 1_000
    let end = Int64(try #require(formatter.date(from: sample.end)).timeIntervalSince1970) * 1_000
    let window = try UsageWindow.make(.month, now: end + 17, timeZone: zone)
    let first = try window.bucketRange(containing: window.range.lowerBound).lowerBound
    let previousDay = try window.bucketRange(containing: start - 1).lowerBound
    try withUsageStore { store, a, b in
        let tokens: [(SessionKey, Int64, Int64, TokenPrecision)] = [
            (a, window.range.lowerBound - 1, 200, .call),
            (a, window.range.lowerBound, 2, .call),
            (a, start - 1, 3, .call),
            (a, start, 5, .call),
            (a, start + 30 * 60_000, 7, .call),
            (b, end - 1, 11, .checkpoint),
            (a, end, 13, .call),
            (a, end + 17, 100, .call),
        ]
        try store.write(tokens.enumerated().map { index, token in
            .tokens(.init(session: token.0, timestamp: token.1, counts: .init(output: token.2),
                          precision: token.3, dedupeKey: "synthetic-daily-\(index)"))
        })
        let fast = try store.usage(window: window)
        let exact = try store.usage(window: window, grouping: .model)
        #expect(fast.points == exact.points)
        #expect(fast.totals.counts.total == 41)
        #expect(fast.previous?.counts.total == 200)
        #expect(fast.points.map(\.timestamp) == [first, previousDay, start, start, end])
        #expect(fast.points.map { $0.totals.counts.output } == [2, 3, 12, 11, 13])
        #expect(fast.points.filter(\.coarse).map(\.agent) == [.copilot])
    }
}

@Test("FR-TK: hour projection agrees with exact minute coverage, including corrected peaks and edges")
func exactHourlyProjection() throws {
    try withUsageStore { store, a, b in
        var call = TokenEvent(session: a, timestamp: 3_600_001, model: "synthetic", counts: .init(inputFresh: 9, cacheRead: 2, output: 4),
                              dedupeKey: "hour-call")
        try store.write([
            .tokens(.init(session: a, timestamp: 12, counts: .init(output: 50), dedupeKey: "early-edge")),
            .tokens(call),
            .tokens(.init(session: b, timestamp: 3_600_002, counts: .init(output: 20), dedupeKey: "peer-call")),
            .tokens(.init(session: b, timestamp: 3_600_003, counts: .init(output: 200), precision: .checkpoint, dedupeKey: "hour-fallback")),
            .tokens(.init(session: a, timestamp: 2_500_000_000, counts: .init(output: 10), dedupeKey: "late-hour")),
        ])
        call.counts = .init(inputFresh: 99, cacheRead: 2, output: 4)
        try store.write([.tokens(call), .tokens(call)])
        let range = try UsageRange(lowerBound: 10, upperBound: 2_592_000_123)
        let window = try UsageWindow.make(.custom, now: range.upperBound, custom: range, timeZone: .gmt)
        guard case .fixed(let width) = window.bucket else { Issue.record("Expected a fixed custom bucket"); return }
        #expect(width >= 3_600_000 && width % 3_600_000 == 0)
        let fast = try store.usage(window: window)
        let exact = try store.usage(window: window, grouping: .model)
        #expect(fast.totals == exact.totals && fast.points == exact.points && fast.previous == exact.previous)
        #expect(fast.peak == exact.peak && fast.peak == UsagePeak(timestamp: 3_600_000, value: 125))
        #expect(fast.breakdown.first { $0.agent == .codex }?.peak?.value == 105)
        #expect(fast.breakdown.first { $0.agent == .copilot }?.peak?.value == 20)
    }
}

@Test("FR-TK-1: the optional menu label uses the same trailing minute and accounting as the full panel",
      .timeLimit(.minutes(1)))
func nativeMenuBarThroughputMatchesThePanelAndExpires() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("menu-rate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = try AgentStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: folder))
    let session = SessionKey(agent: .codex, nativeID: "synthetic-bar-rate")
    let now: Int64 = 1_797_000_000_000
    try store.write([.session(.init(key: session, sourceID: source, environment: "Synthetic"))])
    var changes = store.menuBarThroughputChanges().makeAsyncIterator()
    _ = try await changes.next()
    #expect(try await store.menuBarThroughput(now: now) == 0)
    #expect(try await store.menuBarThroughputReading(now: now).nextChangeAt == nil)
    try store.write([
        .tokens(.init(session: session, timestamp: now - 60_001, counts: .init(output: 91), dedupeKey: "older")),
        .tokens(.init(session: session, timestamp: now - 60_000,
                      counts: .init(inputFresh: 2, cacheRead: 3, cacheWrite: 1, output: 4, reasoning: 1),
                      dedupeKey: "inclusive")),
        .tokens(.init(session: session, timestamp: now - 1, counts: .init(output: 7), dedupeKey: "latest")),
        .tokens(.init(session: session, timestamp: now, counts: .init(output: 13), dedupeKey: "exclusive")),
        .tokens(.init(session: session, timestamp: now - 1, counts: .init(output: 111), precision: .snapshot,
                      dedupeKey: "coarse")),
    ])
    _ = try await changes.next()
    #expect(try await store.menuBarThroughput(now: now) == 17)
    let panel = try store.menuUsage(now: now, timeZone: .gmt)
    #expect(panel.currentTokens == 17)
    #expect(panel.nextChangeAt == now + 1)
    #expect(try await store.menuBarThroughput(now: now + 1) == 20)
    #expect(try await store.menuBarThroughputReading(now: now + 1).nextChangeAt == now + 60_000)
    #expect(try await store.menuBarThroughput(now: now + 60_001) == 0)
    #expect(try await store.menuBarThroughputReading(now: now + 60_001).nextChangeAt == nil)
}

@Test("NFR-7: quota resets, fallback winners and freshness publish the next actual limit change")
func usageLimitDeadlines() throws {
    try withUsageStore { store, _, _ in
        let now: Int64 = 200_000_000
        #expect(try store.usageLimitReadings(now: now, agent: nil, includeThroughput: true).nextChangeAt == nil)
        try store.write([
            .rateLimit(.init(agent: .codex, limitID: "slow", window: .primary, timestamp: now - 1_000,
                             usedPercent: 50)),
            .rateLimit(.init(agent: .codex, limitID: "tight", window: .primary, timestamp: now,
                             usedPercent: 90, resetsAt: now + 10_000)),
            .rateLimit(.init(agent: .codex, limitID: "future", window: .secondary, timestamp: now + 15_000,
                             usedPercent: 70, resetsAt: now + 20_000)),
        ])
        func read(_ at: Int64) throws -> UsageLimitReadings {
            try store.usageLimitReadings(now: at, agent: .codex, includeThroughput: false)
        }
        let before = try read(now)
        #expect(before.codex.map(\.usedPercent) == [90])
        #expect(before.nextChangeAt == now + 10_000)
        let reset = try read(now + 10_000)
        #expect(reset.codex.map(\.usedPercent) == [50])
        #expect(reset.nextChangeAt == now + 15_000)
        let arrived = try read(now + 15_000)
        #expect(arrived.codex.count == 2 && arrived.nextChangeAt == now + 20_000)
        let freshness = now - 1_000 + 86_400_000
        #expect(try read(now + 20_000).nextChangeAt == freshness)
        let stale = try read(freshness)
        #expect(stale.codex.isEmpty && stale.nextChangeAt == nil)
        #expect(try store.usageLimitReadings(now: now, agent: .copilot, includeThroughput: false).nextChangeAt == nil)
    }
}

@Test("NFR-7: a limit-only commit wakes headroom without waiting for usage or a clock tick",
      .timeLimit(.minutes(1)))
func limitOnlyCommitWakesHeadroom() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-limits-wake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    var changes = store.usageLimitChanges(includeThroughput: false).makeAsyncIterator()
    let initial: Void? = try await changes.next()
    #expect(initial != nil)
    try store.write([.rateLimit(.init(agent: .codex, limitID: "synthetic", window: .secondary,
                                     timestamp: 900, usedPercent: 40))])
    let wake: Void? = try await changes.next()
    #expect(wake != nil)
    #expect(try store.usageLimitReadings(now: 901, agent: .codex, includeThroughput: false).codex.first?.usedPercent == 40)
}

@Test("NFR-7: menu wakes at midnight for Today's data; an empty day waits for a real change")
func menuDeadlines() throws {
    try withUsageStore { store, a, _ in
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let formatter = ISO8601DateFormatter()
        let beforeDate = try #require(formatter.date(from: "2026-03-09T06:59:59Z"))
        let nextDate = try #require(formatter.date(from: "2026-03-09T07:00:00Z"))
        let before = Int64(beforeDate.timeIntervalSince1970 * 1_000)
        let midnight = Int64(nextDate.timeIntervalSince1970 * 1_000)
        #expect(try store.menuUsage(now: before, timeZone: zone).nextChangeAt == nil)
        try store.write([.tokens(.init(session: a, timestamp: before - 5_000, counts: .init(output: 31),
                                       precision: .checkpoint, dedupeKey: "synthetic-day-total"))])
        let today = try store.menuUsage(now: before, timeZone: zone)
        #expect(today.today.counts.total == 31 && today.currentTokens == 0)
        #expect(today.nextChangeAt == midnight)
        let tomorrow = try store.menuUsage(now: midnight, timeZone: zone)
        #expect(tomorrow.today.counts.total == 0 && tomorrow.nextChangeAt == nil)

        let sources = try store.sources()
        let agent = try #require(sources.first { $0.agent == .codex })
        let began = midnight + 1_000
        try store.write([.session(.init(key: a, sourceID: try #require(agent.id), environment: "Synthetic",
                                        startedAt: began, status: .waiting))])
        let active = try store.menuUsage(now: began + 11_000, timeZone: zone)
        #expect(active.sessionsToday == 1 && active.sessions.map(\.id) == [a])
        #expect(active.nextChangeAt == began + 60_000)
    }
}

@Test("NFR-7: live chart deadlines distinguish recent expiry from report and comparison boundaries")
func usageChartDeadlines() throws {
    try withUsageStore { store, a, b in
        let now: Int64 = 10_800_000, hour: Int64 = 3_600_000, minute: Int64 = 60_000
        let filter = UsageFilter(agent: .codex)
        func report(_ at: Int64) throws -> UsageReport {
            let window = try UsageWindow.make(.hour, now: at, timeZone: .gmt)
            return try store.usage(window: window, filter: filter, liveAt: at)
        }
        func row(_ session: SessionKey, _ key: String, _ timestamp: Int64, _ tokens: Int64) -> NormalizedRecord {
            .tokens(.init(session: session, timestamp: timestamp, counts: .init(output: tokens), dedupeKey: key))
        }
        try store.write([
            row(a, "synthetic-recent", now - minute, 11),
            row(a, "synthetic-current", now - hour + 3_000, 50),
            row(a, "synthetic-previous", now - 2 * hour + 2_000, 90),
            row(b, "synthetic-other-agent", now, 120),
        ])
        let initial = try report(now)
        #expect(initial.chart.nextRecentChangeAt == now + 1)
        #expect(initial.chart.nextRangeChangeAt == now + 2_001)
        let recentExpired = try report(now + 1)
        #expect(recentExpired.chart.recent?.counts.total == 0 && recentExpired.chart.nextRecentChangeAt == nil)
        #expect(recentExpired.totals == initial.totals && recentExpired.previous == initial.previous)
        let comparisonExpired = try report(now + 2_001)
        #expect(comparisonExpired.previous?.counts.total == 0)
        #expect(comparisonExpired.chart.nextRangeChangeAt == now + 3_001)
        let moved = try report(now + 3_001)
        #expect(moved.totals.counts.total == 11 && moved.previous?.counts.total == 50)
        try store.write([row(a, "synthetic-future", now + 4_000, 6)])
        let pending = try report(now + 4_000)
        #expect(pending.chart.nextRangeChangeAt == now + 4_001)
        #expect(try report(now + 4_001).totals.counts.total == 17)
        let all = try store.usageChart(period: .all, now: now + 4_001, timeZone: .gmt, filter: filter)
        #expect(all.nextRangeChangeAt == nil)
        let custom = try UsageRange(lowerBound: 0, upperBound: now + 5_000)
        let fixed = try store.usageChart(period: .custom, now: now, timeZone: .gmt, filter: filter, custom: custom)
        #expect(fixed.nextRangeChangeAt == nil && fixed.nextRecentChangeAt == nil)
    }
}

@Test("NFR-5: scope rollups keep sub-hour series, exact edges and minute peaks")
func scopeRollupsKeepFineUsageFacts() throws {
    try withUsageStore { store, codex, copilot in
        let start: Int64 = 3_600_123
        let end = start + 3_600_000
        let peakMinute = start + 60_000
        func usage(_ key: SessionKey, _ id: String, _ time: Int64, _ tokens: Int64,
                   precision: TokenPrecision = .call) -> NormalizedRecord {
            .tokens(.init(session: key, timestamp: time, model: id, counts: .init(output: tokens),
                          precision: precision, dedupeKey: id))
        }
        try store.write([
            usage(codex, "before", start - 1, 90),
            usage(codex, "lower-edge", start, 4),
            usage(codex, "first-precise", peakMinute, 15),
            usage(copilot, "second-precise", peakMinute + 1, 20),
            usage(codex, "coarse", peakMinute + 2, 7, precision: .checkpoint),
            usage(copilot, "upper-edge", end - 1, 3),
            usage(copilot, "after", end, 95),
        ])
        let window = try UsageWindow.make(.hour, now: end, timeZone: .gmt)
        let scoped = try store.usage(window: window, grouping: .agent, liveAt: end)
        let detailed = try store.usage(window: window, grouping: .model, liveAt: end)
        #expect(scoped.totals == detailed.totals && scoped.totals.counts.total == 49)
        #expect(scoped.previous == detailed.previous && scoped.previous?.counts.total == 90)
        #expect(scoped.peak == detailed.peak && scoped.peak?.value == 35)
        #expect(scoped.chart.cumulative(.tokens) == 49)
        #expect(scoped.points.first { $0.coarse }?.totals.counts.total == 7)
        let onlyCodex = try store.usage(window: window, filter: .init(agent: .codex), liveAt: end)
        #expect(onlyCodex.totals.counts.total == 26 && onlyCodex.peak?.value == 15)
        #expect(onlyCodex.points.allSatisfy { $0.agent == .codex })
    }
}

@Test("NFR-5: bounded ranked peak seeks preserve in-range ties and exact range fallback")
func rankedMiddlePeaksStayExact() throws {
    try withUsageStore { store, codex, copilot in
        let start: Int64 = 1_728_000_000
        let range = try UsageRange(lowerBound: start, upperBound: start + 1_209_600_000)
        let window = try UsageWindow.make(.custom, now: start, custom: range, timeZone: .gmt)
        let basis = TokenRateBasis(reference: "synthetic-ranked-peak", bytes: Data([3, 7]))
        _ = try store.activatePricing { input, _ in
            guard input.model != "unpriced" else { return nil }
            return TokenQuote(microUSD: input.counts.output, status: .priced, basis: basis)
        }
        func row(_ key: SessionKey, _ id: String, offset: Int64, output: Int64,
                 model: String = "synthetic", precision: TokenPrecision = .call) -> NormalizedRecord {
            .tokens(.init(session: key, timestamp: start + offset, model: model, counts: .init(output: output),
                          precision: precision, dedupeKey: id))
        }
        var events = [
            row(codex, "outside-tie", offset: -60_000, output: 100),
            row(codex, "first-inside", offset: 60_000, output: 100),
            row(codex, "second-inside", offset: 120_000, output: 100),
            row(codex, "unquoted", offset: 180_000, output: 9, model: "unpriced"),
            row(codex, "coarse", offset: 240_000, output: 500, precision: .checkpoint),
            row(copilot, "smaller", offset: 300_000, output: 11),
            row(copilot, "copilot-peak", offset: 360_000, output: 12),
        ]
        // Combined and Copilot have enough higher out-of-range levels to
        // exhaust the bounded fast path. Codex's highest level can seek.
        for i in 0..<12 {
            events.append(row(copilot, "outside-\(i)", offset: -Int64(i + 2) * 60_000, output: Int64(200 + i)))
        }
        try store.write(events)
        for metric in [UsageMetric.tokens, .output, .cost] {
            let all = try store.usage(window: window, metric: metric)
            #expect(all.peak?.value == 100 && all.peak?.timestamp == start + 60_000)
            #expect(all.breakdown.first { $0.agent == .copilot }?.peak?.value == 12)
            let filtered = try store.usage(window: window, filter: .init(agent: .codex), metric: metric)
            #expect(filtered.peak?.value == 100 && filtered.peak?.timestamp == start + 60_000)
        }
    }
}
