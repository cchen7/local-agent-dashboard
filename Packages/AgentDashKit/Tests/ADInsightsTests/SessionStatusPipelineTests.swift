import ADCore
import ADInsights
import ADStore
import Foundation
import Testing

@Test("SPEC §10.4: committed tool activity refreshes a searchable status and ages without new records",
      .timeLimit(.minutes(1)))
func liveStatusRefreshesOnWriteAndDeadline() async throws {
    let fixture = try StatusFixture()
    defer { fixture.remove() }
    let engine = SessionStatusPipeline(store: fixture.store, thresholds: try .init(
        approvalSilenceMilliseconds: 5, recentActivityMilliseconds: 2_400,
        pendingToolLifetimeMilliseconds: 8_000, turnCompletionSilenceMilliseconds: 9_000))
    let worker = Task { try await engine.run() }
    defer { worker.cancel() }
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try fixture.store.write([
        fixture.event(1, now, .toolCall, #"{"tool_use_id":"call"}"#),
    ])
    var sessions = fixture.store.indexedSessionUpdates().makeAsyncIterator()
    var reason: String?
    while let batch = try await sessions.next() {
        reason = batch.first?.statusReason
        if reason == "possiblyNeedsApproval" { break }
    }
    #expect(reason == "possiblyNeedsApproval")
    let waiting = try fixture.store.searchIndex(SearchQuery.parse("status:waiting"), scope: .init(now: now, timeZone: .gmt))
    #expect(waiting.groups.map(\.session) == [fixture.key])

    // The untyped wrapper resolves the call; a later explicit exit code still
    // determines its outcome. The next user action clears the old failure.
    let next = Int64(Date().timeIntervalSince1970 * 1000)
    try fixture.store.write([
        fixture.event(2, next, .toolResult, #"{"call_id":"call"}"#),
        fixture.event(3, next, .system, #"{"call_id":"call","exit_code":3}"#),
    ])
    while let batch = try await sessions.next() {
        reason = batch.first?.statusReason
        if reason == "toolResultError" { break }
    }
    #expect(reason == "toolResultError")
    try fixture.store.write([fixture.event(4, next + 1, .user, nil)])
    while let batch = try await sessions.next() {
        reason = batch.first?.statusReason
        if reason == "inactive" { break }
    }
    #expect(reason == "inactive")
    #expect(!((try fixture.store.hasPendingStatusWork(at: .max))))
    worker.cancel()
    do { try await worker.value } catch is CancellationError {}
}

@Test("SPEC §10.4: the turn deadline changes status without reimport, and a stale evaluation cannot win")
func statusDeadlineAndStaleRevision() async throws {
    let fixture = try StatusFixture()
    defer { fixture.remove() }
    let engine = SessionStatusPipeline(store: fixture.store)
    try fixture.store.write([fixture.event(1, 100, .assistant, #"{"signal":"assistant.turn_end"}"#)])
    let stale = try #require(try fixture.store.statusWork(at: 100).first)
    try fixture.store.write([fixture.event(2, 100, .assistant, #"{"signal":"assistant.turn_end"}"#)])
    #expect(try fixture.store.applyStatuses([
        .init(id: stale.id, revision: stale.revision, status: .failed, reason: "apiError", nextAt: nil),
    ]) == 0)
    #expect(try await engine.refresh(at: 60_100) == 1)
    #expect(try fixture.store.statusWork(at: 60_101).count == 1)
    #expect(try await engine.refresh(at: 1_800_101) == 1)
    var snapshots = fixture.store.indexedSessionUpdates().makeAsyncIterator()
    let current = try #require(try await snapshots.next()?.first)
    #expect(current.status == .completed && current.statusReason == "turnIdleCompleted")
    #expect(!(try fixture.store.hasPendingStatusWork(at: .max)))
}

@Test("SPEC §10.4: changing thresholds reevaluates existing sessions and supersedes an older policy")
func statusPolicyChangesApplyToExistingSessions() async throws {
    let fixture = try StatusFixture()
    defer { fixture.remove() }
    let old = SessionStatusPipeline(store: fixture.store)
    let current = SessionStatusPipeline(store: fixture.store)
    try await old.configure(.default)
    try fixture.store.write([fixture.event(1, 100_000, .toolCall, #"{"tool_use_id":"call"}"#)])
    #expect(try await old.refresh(at: 120_000) == 1)
    let prior = try #require(try fixture.store.statusWork(at: .max).first)
    let changed = try StatusInferenceThresholds(approvalSilenceMilliseconds: 30_000)
    try await current.configure(changed)
    let revised = try #require(try fixture.store.statusWork(at: 120_000).first)
    #expect(revised.revision > prior.revision)
    #expect(try await old.refresh(at: 120_000) == 0)
    #expect(try await current.refresh(at: 120_000) == 1)
    var snapshots = fixture.store.indexedSessionUpdates().makeAsyncIterator()
    let result = try #require(try await snapshots.next()?.first)
    #expect(result.status == .running && result.statusReason == "recentActivity")
    // Reopening with the same values should not dirty or revise the session.
    try await current.configure(changed)
    #expect(try fixture.store.statusWork(at: 120_000).isEmpty)
    #expect(try fixture.store.statusWork(at: 130_001).first?.revision == revised.revision)
}

@Test("§11.2: activity follows matching tool results and disappears at the approval deadline")
func runningActivityUsesCurrentIndexedEvidence() async throws {
    let fixture = try StatusFixture()
    defer { fixture.remove() }
    let pipeline = SessionStatusPipeline(store: fixture.store)

    try fixture.store.write([
        fixture.event(1, 94_000, .toolCall, #"{"call_id":"older","command":"API_TOKEN='synthetic-only' npm test"}"#,
                      tool: "exec_command"),
        fixture.event(2, 97_000, .toolCall, #"{"call_id":"newer"}"#, tool: "search"),
        fixture.event(3, 99_000, .thinking, nil),
    ])
    _ = try await pipeline.refresh(at: 100_000)
    let newest = try #require(try await fixture.currentActivity())
    #expect(newest.action == .pendingTool)
    #expect(newest.toolName == "search")
    #expect(newest.lastEventAt == 97_000)
    #expect(newest.startedAt == 97_000)
    #expect(SessionActivityDisplay(newest, agent: .codex).command == nil)

    try fixture.store.write([fixture.event(4, 101_000, .toolResult, #"{"call_id":"newer","success":true}"#)])
    // Pending computation invalidates the old read immediately.
    #expect(try await fixture.currentActivity() == nil)
    _ = try await pipeline.refresh(at: 102_000)
    let stillPending = try #require(try await fixture.currentActivity())
    let visible = SessionActivityDisplay(stillPending, agent: .codex)
    #expect(visible.startedAt == 94_000 && visible.lastEventAt == 101_000)
    #expect(visible.command == "API_TOKEN='••••••' npm test")
    #expect(SessionActivityDisplay(stillPending, agent: .codex, maskSecrets: false).command ==
            "API_TOKEN='synthetic-only' npm test")
    #expect(SessionActivityDisplay.seconds(since: visible.startedAt, at: 102_000) == 8)
    #expect(SessionActivityDisplay.seconds(since: visible.lastEventAt, at: 102_000) == 1)

    _ = try await pipeline.refresh(at: 116_000)
    #expect(try await fixture.currentActivity()?.action == .pendingTool)
    _ = try await pipeline.refresh(at: 116_001)
    #expect(try await fixture.currentActivity() == nil)

    try fixture.store.write([fixture.event(5, 117_000, .toolResult, #"{"call_id":"older","success":true}"#)])
    _ = try await pipeline.refresh(at: 117_000)
    let finished = try #require(try await fixture.currentActivity())
    #expect(finished.action == .toolFinished && finished.startedAt == nil && finished.toolName == nil)
    #expect(SessionActivityDisplay(finished, agent: .codex).command == nil)
    try fixture.store.write([fixture.event(6, 118_000, .system, #"{"signal":"task_complete"}"#)])
    _ = try await pipeline.refresh(at: 118_001)
    #expect(try await fixture.currentActivity()?.action == .turnFinished)
}

@Test("§11.2: oversized input cannot expose a truncated credential or hide a matching call ID")
func activityOmitsTruncatedInputButKeepsCallEvidence() async throws {
    let fixture = try StatusFixture()
    defer { fixture.remove() }
    let pipeline = SessionStatusPipeline(store: fixture.store)
    let oversized = "API_TOKEN=" + String(repeating: "x", count: 2_039)
    let metadata = try JSONSerialization.data(withJSONObject: ["tool_use_id": "a", "command": oversized])
    try fixture.store.write([
        fixture.event(1, 98_000, .toolCall, String(decoding: metadata, as: UTF8.self), tool: "exec_command"),
    ])
    _ = try await pipeline.refresh(at: 99_000)
    let activity = try #require(try await fixture.currentActivity())
    #expect(activity.action == .pendingTool)
    #expect(activity.startedAt == 98_000)
    #expect(SessionActivityDisplay(activity, agent: .codex, maskSecrets: false).command == nil)
    #expect(SessionActivityDisplay.seconds(since: 100_000, at: 99_000) == nil)
    #expect(SessionActivityDisplay.seconds(since: .min, at: .max) == nil)
}

private struct StatusFixture {
    let directory: URL
    let store: AgentStore
    let key = SessionKey(agent: .codex, nativeID: "synthetic-status-test")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        let sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic",
                                                   rootURL: directory.appendingPathComponent("unused")))
        try store.write([.session(.init(key: key, sourceID: sourceID, environment: "Synthetic"))])
    }

    func event(_ seq: Int64, _ time: Int64, _ kind: EventKind, _ meta: String?, tool: String? = nil) -> NormalizedRecord {
        .event(.init(session: key, sequence: seq, timestamp: time, kind: kind, toolName: tool,
                     text: "synthetic activity", metadataJSON: meta, dedupeKey: "synthetic:status:\(seq)"))
    }

    func currentActivity() async throws -> IndexedSessionActivity? {
        var iterator = store.sessionActivityUpdates(in: key).makeAsyncIterator()
        return try await iterator.next() ?? nil
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
