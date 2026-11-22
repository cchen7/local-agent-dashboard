import ADCore
import ADStore
import Foundation
import Testing

@Test("SPEC §11.5: menu separates local midnight, rolling throughput, and active status")
func menuUsesLocalDayAndCallLevelTail() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("menu-usage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp.appendingPathComponent("absent")))
    let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let midnight = 1_783_008_000_000 as Int64 // 16:00 UTC, midnight in Shanghai
    let now = midnight + 20_000
    let running = SessionKey(agent: .codex, nativeID: "synthetic-menu-running")
    let waiting = SessionKey(agent: .codex, nativeID: "synthetic-menu-waiting")
    let completed = SessionKey(agent: .codex, nativeID: "synthetic-menu-completed")
    try store.write([
        .session(.init(key: running, sourceID: sourceID, environment: "Synthetic", startedAt: midnight, status: .running)),
        .session(.init(key: waiting, sourceID: sourceID, environment: "Synthetic", startedAt: midnight - 1000, status: .waiting)),
        .session(.init(key: completed, sourceID: sourceID, environment: "Synthetic", startedAt: midnight + 1000, status: .completed)),
        .tokens(.init(session: running, timestamp: midnight - 500, counts: .init(inputFresh: 4, cacheRead: 1), dedupeKey: "menu-before-midnight")),
        .tokens(.init(session: running, timestamp: midnight + 1, counts: .init(inputFresh: 6, output: 1), dedupeKey: "menu-after-midnight")),
        .tokens(.init(session: waiting, timestamp: midnight + 2, counts: .init(inputFresh: 11), precision: .checkpoint, dedupeKey: "menu-coarse")),
        .tokens(.init(session: completed, timestamp: now, counts: .init(inputFresh: 99), dedupeKey: "menu-end-boundary")),
    ])
    try store.setUsageRedlines([.codex: 30])
    let snapshot = try store.menuUsage(now: now, timeZone: zone)
    #expect(snapshot.chart.window.range.lowerBound == midnight)
    #expect(snapshot.today.counts.total == 18)
    #expect(snapshot.today.unpricedTokens == 18)
    #expect(snapshot.currentTokens == 12)
    #expect(snapshot.running == 1 && snapshot.waiting == 1 && snapshot.sessionsToday == 2)
    #expect(Set(snapshot.sessions.map(\.id)) == [running, waiting])
    #expect(snapshot.sessions.first { $0.id == running }?.tokensPerMinute == 12)
    #expect(snapshot.sessions.first { $0.id == waiting }?.tokensPerMinute == 0)
    #expect(snapshot.redlines == [.codex: 30])
    var changes = store.menuUsageChanges().makeAsyncIterator()
    _ = try await changes.next()
    try store.write([.session(.init(key: waiting, sourceID: sourceID, environment: "Synthetic", status: .completed))])
    let wake: Void? = try await changes.next()
    #expect(wake != nil)
    let updated = try store.menuUsage(now: now, timeZone: zone, reusing: snapshot.chart)
    #expect(updated.waiting == 0 && updated.sessions.map(\.id) == [running])
}
