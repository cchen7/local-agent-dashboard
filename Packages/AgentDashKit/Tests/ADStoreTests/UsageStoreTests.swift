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
    #expect(try await store.menuBarThroughput(now: now + 1) == 20)
    #expect(try await store.menuBarThroughput(now: now + 60_001) == 0)
}
