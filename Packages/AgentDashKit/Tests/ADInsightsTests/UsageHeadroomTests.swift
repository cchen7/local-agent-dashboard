import ADCore
import ADInsights
import ADStore
import Foundation
import Testing

@Test("FR-TK: redline settings persist atomically without replacing other app metadata")
func savesUsageRedlines() throws {
    try withHeadroomIndex { store, url, _ in
        let previous = Data("synthetic verified metadata".utf8)
        try store.rememberVerifiedPriceBytes(previous)
        try store.setUsageRedlines([.codex: 70, .claudeCode: 100])
        #expect(throws: StoreError.invalidUsageRedline) { try store.setUsageRedlines([.codex: 0]) }
        let reopened = try AgentStore(databaseURL: url)
        #expect(try reopened.usageRedlines() == [.codex: 70, .claudeCode: 100])
        try reopened.setUsageRedlines([.claudeCode: 99])
        #expect(try store.usageRedlines() == [.claudeCode: 99])
        #expect(try reopened.lastVerifiedPriceBytes() == previous)
    }
}

@Test("FR-TK: headroom uses trailing exact usage and prefers current Codex limits")
func measuredUsageHeadroom() throws {
    try withHeadroomIndex { store, _, root in
        let now: Int64 = 120_003
        func session(_ agent: AgentKind) throws -> SessionKey {
            let source = try store.upsertSource(.init(agent: agent, label: "Synthetic", rootURL: root))
            let key = SessionKey(agent: agent, nativeID: "synthetic-session")
            try store.write([.session(.init(key: key, sourceID: source, environment: "Synthetic"))])
            return key
        }
        let claude = try session(.claudeCode), copilot = try session(.copilot)
        try store.write([
            .tokens(.init(session: claude, timestamp: now - 60_000,
                          counts: .init(inputFresh: 20, cacheRead: 20, cacheWrite: 10, cacheWrite1h: 5, output: 5),
                          dedupeKey: "synthetic-inclusive")),
            .tokens(.init(session: claude, timestamp: now - 60_001, counts: .init(output: 999),
                          dedupeKey: "synthetic-before")),
            .tokens(.init(session: claude, timestamp: now, counts: .init(output: 999),
                          dedupeKey: "synthetic-after")),
            .tokens(.init(session: claude, timestamp: now - 1, counts: .init(output: 999),
                          precision: .checkpoint, dedupeKey: "synthetic-coarse")),
            .tokens(.init(session: copilot, timestamp: now - 10_000, counts: .init(output: 20),
                          dedupeKey: "synthetic-copilot")),
            .rateLimit(.init(agent: .codex, limitID: "synthetic-active", window: .primary,
                             timestamp: now - 5, usedPercent: 45, resetsAt: now + 60_000)),
        ])
        let limits: [AgentKind: Int64] = [.claudeCode: 100, .copilot: 5, .codex: 1]
        let combined = try store.usageLimitReadings(now: now, agent: nil, includeThroughput: true)
        #expect(combined.throughput.map(\.tokensPerMinute) == [60, 20])
        if case .codex(let windows, let other) = usageHeadroom(readings: combined, limits: limits) {
            #expect(windows.first?.usedPercent == 45)
            #expect(other?.agent == .claudeCode && other?.tokensPerMinute == 60)
            #expect(abs((other?.remaining ?? 0) - 0.4) < 0.000_001)
        } else { Issue.record("Expected Codex plus the leading other agent") }
        let filtered = try store.usageLimitReadings(now: now, agent: .copilot, includeThroughput: true)
        #expect(filtered.codex.isEmpty)
        if case .manual(let reading) = usageHeadroom(readings: filtered, limits: limits, agent: .copilot) {
            #expect(reading.overRedline && reading.remaining == 0 && reading.tokensPerMinute == 20)
        } else { Issue.record("Expected the selected agent's manual limit") }
        let idle = try store.usageLimitReadings(now: now + 60_001, agent: .codex, includeThroughput: true)
        #expect(usageHeadroom(readings: idle, limits: limits, agent: .codex) == .noRecentUsage)
        #expect(usageHeadroom(readings: idle, limits: [:], agent: .codex) == .notSet)
    }
}

@Test("FR-TK: a redline update refreshes chart guides and menu headroom without changing usage")
func usageRedlinesRefreshBothReadPaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("redline-live-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic", rootURL: directory))
    let key = SessionKey(agent: .claudeCode, nativeID: "synthetic-live-redline")
    let now: Int64 = 1_783_008_020_000
    try store.write([
        .session(.init(key: key, sourceID: source, environment: "Synthetic")),
        .tokens(.init(session: key, timestamp: now - 5_000, counts: .init(inputFresh: 30), dedupeKey: "synthetic-redline-usage")),
    ])
    var redlines = store.usageRedlineUpdates().makeAsyncIterator()
    var menuChanges = store.menuUsageChanges().makeAsyncIterator()
    #expect(try await redlines.next() == [:])
    _ = try await menuChanges.next()
    let before = try store.menuUsage(now: now, timeZone: .gmt)
    try store.setUsageRedlines([.claudeCode: 60])
    let limits = try #require(try await redlines.next())
    let menuWake: Void? = try await menuChanges.next()
    #expect(menuWake != nil)
    let after = try store.menuUsage(now: now, timeZone: .gmt, reusing: before.chart)
    #expect(after.redlines == limits && limits == [.claudeCode: 60])
    #expect(after.today == before.today && after.currentTokens == before.currentTokens)
    let guide = UsageRedlineGuide.make(limits: limits, agent: .claudeCode, window: after.chart.window, unit: .minute)
    #expect(guide.first?.segments.first?.value == 60)
    if case .manual(let headroom) = usageHeadroom(readings: after.limits, limits: after.redlines) {
        #expect(headroom.remaining == 0.5)
    } else { Issue.record("The menu must use the saved Claude redline") }

    try store.setUsageRedlines([:])
    #expect(try await redlines.next() == [:])
    let cleared = try store.menuUsage(now: now, timeZone: .gmt)
    #expect(usageHeadroom(readings: cleared.limits, limits: cleared.redlines) == .notSet)
    #expect(cleared.today == before.today)
}

@Test("FR-TK: redline guide uses actual local-day and partial-bucket durations",
      arguments: [
        ("2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z", 82_800.0),
        ("2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z", 90_000.0),
      ])
func redlineGuideDST(sample: (start: String, end: String, tokens: Double)) throws {
    let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
    let dates = ISO8601DateFormatter()
    let day = try #require(dates.date(from: sample.start))
    let next = try #require(dates.date(from: sample.end))
    let start = Int64(day.timeIntervalSince1970 * 1000), end = Int64(next.timeIntervalSince1970 * 1000)
    let window = try UsageWindow.make(.month, now: end + 3_600_000, timeZone: zone)
    let limits: [AgentKind: Int64] = [.claudeCode: 60, .codex: 100]
    let guide = try #require(UsageRedlineGuide.make(limits: limits, agent: .claudeCode, window: window, unit: .day).first)
    #expect(guide.agent == .claudeCode)
    let short = try #require(guide.segments.first { $0.start == start })
    #expect(short.end == end && short.value == sample.tokens)
    #expect(guide.segments.last?.value == 3_600)
    let hourly = UsageRedlineGuide.make(limits: limits, agent: .claudeCode, window: window, unit: .hour).first
    #expect(hourly?.segments.first?.value == 3_600)
    #expect(UsageRedlineGuide.make(limits: limits, agent: nil, window: window, unit: .costDay).isEmpty)
}

private func withHeadroomIndex(_ body: (AgentStore, URL, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-limits-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let index = directory.appendingPathComponent("index.sqlite")
    try body(AgentStore(databaseURL: index), index, directory)
}
