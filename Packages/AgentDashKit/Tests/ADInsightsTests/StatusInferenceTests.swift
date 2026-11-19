import Testing
import ADCore
import ADInsights

/// SPEC §10.4 / DEV-002. All records and times are synthetic; no file or clock access.
private let now: Int64 = 10_000_000
private let engine = StatusInferenceEngine()

private func signal(_ sequence: Int64, age: Int64?, _ kind: StatusActivitySignal.Kind) -> StatusActivitySignal {
    .init(sequence: sequence, timestampMilliseconds: age.map { now - $0 }, kind: kind)
}

@Test("§10.4: no activity has typed unknown evidence")
func noActivity() {
    let result = engine.infer([], nowMilliseconds: now)
    #expect(result.status == .unknown)
    #expect(result.reason == .noActivity)
    #expect(result.evidence.latestActivity == nil)
    #expect(result.evidence.decisiveSignal == nil)
    #expect(result.evidence.pendingTools.isEmpty)
    #expect(result.evidence.nowMilliseconds == now)
    #expect(result.evidence.thresholds == .default)
}

@Test("§10.4: recent activity includes exactly 60 seconds", arguments: [Int64(59_999), 60_000, 60_001])
func recentBoundary(age: Int64) {
    let result = engine.infer([signal(1, age: age, .activity)], nowMilliseconds: now)
    #expect(result.status == (age <= 60_000 ? .running : .unknown))
    #expect(result.reason == (age <= 60_000 ? .recentActivity : .inactive))
    #expect(result.evidence.latestActivity?.ageMilliseconds == age)
}

@Test("§10.4: approval inference is strictly greater than 15 seconds",
      arguments: [Int64(14_999), 15_000, 15_001])
func strictApprovalBoundary(age: Int64) {
    let result = engine.infer([signal(1, age: age, .toolCall(id: "a"))], nowMilliseconds: now)
    #expect(result.status == (age > 15_000 ? .waiting : .running))
    #expect(result.reason == (age > 15_000 ? .possiblyNeedsApproval : .recentActivity))
    #expect(result.evidence.decisiveSignal?.signal.sequence == 1)
}

@Test("§10.4: pending tools expire strictly after ten minutes",
      arguments: [Int64(599_999), 600_000, 600_001])
func pendingExpiryBoundary(age: Int64) {
    let result = engine.infer([signal(1, age: age, .toolCall(id: "a"))], nowMilliseconds: now)
    #expect(result.status == (age <= 600_000 ? .waiting : .unknown))
    #expect(result.reason == (age <= 600_000 ? .possiblyNeedsApproval : .pendingToolExpired))
    #expect(result.evidence.pendingTools.first?.call.ageMilliseconds == age)
}

@Test("§10.4: normal turn idle boundaries are 60 seconds and 30 minutes inclusive",
      arguments: [Int64(59_999), 60_000, 60_001, 1_799_999, 1_800_000, 1_800_001])
func turnIdleBoundaries(age: Int64) {
    let result = engine.infer([signal(1, age: age, .turnEnded)], nowMilliseconds: now)
    if age < 60_000 {
        #expect(result.status == .running)
        #expect(result.reason == .recentActivity)
    } else if age <= 1_800_000 {
        #expect(result.status == .waiting)
        #expect(result.reason == .waitingForReply)
    } else {
        #expect(result.status == .completed)
        #expect(result.reason == .turnIdleCompleted)
    }
}

@Test("DEV-002: failed beats explicit completion, pending waiting and recent activity",
      arguments: [StatusFailure.apiError, .turnError])
func failurePrecedence(failure: StatusFailure) {
    let result = engine.infer([
        signal(1, age: 20_000, .toolCall(id: "a")),
        signal(2, age: 19_000, .failure(failure)),
        signal(3, age: 18_000, .turnEnded),
        signal(4, age: 17_000, .sessionEnded)
    ], nowMilliseconds: now)
    #expect(result.status == .failed)
    #expect(result.reason == (failure == .apiError ? .apiError : .turnError))
    #expect(result.evidence.decisiveSignal?.signal.sequence == 2)
    #expect(result.evidence.latestActivity?.signal.sequence == 4)
}

@Test("DEV-002: explicit completion beats pending waiting and recent activity")
func completionPrecedence() {
    let result = engine.infer([
        signal(1, age: 20_000, .toolCall(id: "a")),
        signal(2, age: 16_000, .sessionEnded)
    ], nowMilliseconds: now)
    #expect(result.status == .completed)
    #expect(result.reason == .sessionEnded)
    #expect(result.evidence.decisiveSignal?.signal.sequence == 2)
}

@Test("DEV-002: idle completion precedes pending waiting with configurable windows")
func idleCompletionPrecedence() throws {
    let thresholds = try StatusInferenceThresholds(pendingToolLifetimeMilliseconds: 3_600_000)
    let result = StatusInferenceEngine(thresholds: thresholds).infer([
        signal(1, age: 1_900_000, .toolCall(id: "a")),
        signal(2, age: 1_800_001, .turnEnded)
    ], nowMilliseconds: now)
    #expect(result.status == .completed)
    #expect(result.reason == .turnIdleCompleted)
}

@Test("DEV-002: waiting beats recent activity")
func waitingPrecedence() {
    let result = engine.infer([signal(1, age: 15_001, .toolCall(id: "a"))], nowMilliseconds: now)
    #expect(result.status == .waiting)
    #expect(result.reason == .possiblyNeedsApproval)
}

@Test("DEV-002: all later actions supersede old error/end/normal-turn markers",
      arguments: [StatusActivitySignal.Kind.activity, .toolCall(id: "new"),
                  .toolResult(id: "new", outcome: .success), .approvalRequested(toolCallID: nil)])
func resumedActivity(kind: StatusActivitySignal.Kind) {
    let result = engine.infer([
        signal(4, age: 0, kind),
        signal(2, age: 1, .sessionEnded),
        signal(1, age: 2, .failure(.turnError)),
        signal(3, age: 1, .turnEnded)
    ], nowMilliseconds: now)
    if case .approvalRequested = kind {
        #expect(result.status == .waiting)
        #expect(result.reason == .needsApproval)
    } else {
        #expect(result.status == .running)
        #expect(result.reason == .recentActivity)
    }
    #expect(result.evidence.decisiveSignal?.signal.sequence == 4)
}

@Test("DEV-002: resumed activity supersedes old terminal and turn-idle state",
      arguments: [StatusActivitySignal.Kind.failure(.apiError), .sessionEnded, .turnEnded])
func resumedActivityClearsOldTerminals(terminal: StatusActivitySignal.Kind) {
    let result = engine.infer([signal(1, age: 40_000, terminal),
                               signal(2, age: 20_000, .activity)], nowMilliseconds: now)
    #expect(result.status == .running)
    #expect(result.reason == .recentActivity)
    #expect(result.evidence.pendingTools.isEmpty)
    let stale = engine.infer([signal(1, age: 2_000_000, terminal),
                              signal(2, age: 100_000, .activity)], nowMilliseconds: now)
    #expect(stale.status == .unknown)
    #expect(stale.reason == .inactive)
}

@Test("§10.4: tool errors fail until a later action, even if a normal end follows")
func toolError() {
    let events = [signal(1, age: 20_000, .toolCall(id: "a")),
                  signal(2, age: 19_000, .toolResult(id: "a", outcome: .failure)),
                  signal(3, age: 18_000, .turnEnded)]
    let result = engine.infer(events, nowMilliseconds: now)
    #expect(result.status == .failed)
    #expect(result.reason == .toolResultError)
    #expect(result.evidence.decisiveSignal?.signal.sequence == 2)
    #expect(result.evidence.pendingTools.isEmpty)
    #expect(engine.infer(events + [signal(4, age: 0, .activity)], nowMilliseconds: now).status == .running)
}

@Test("§10.4: matched result removes only its own pending call; orphan results do not resolve calls")
func resultCorrelation() {
    let events = [signal(1, age: 40_000, .toolCall(id: "a")),
                  signal(2, age: 30_000, .toolCall(id: "b")),
                  signal(3, age: 20_000, .toolResult(id: "a", outcome: .success)),
                  signal(4, age: 16_000, .toolResult(id: "orphan", outcome: .success))]
    let result = engine.infer(events.reversed(), nowMilliseconds: now)
    #expect(result.status == .waiting)
    #expect(result.reason == .possiblyNeedsApproval)
    #expect(result.evidence.pendingTools.map(\.id) == ["b"])
    #expect(result.evidence.decisiveSignal?.signal.sequence == 2)
    let resolved = engine.infer(events + [signal(5, age: 0, .toolResult(id: "b", outcome: .success))],
                                nowMilliseconds: now)
    #expect(resolved.status == .running)
    #expect(resolved.evidence.pendingTools.isEmpty)
}

@Test("§10.4: interleaved success after an error preserves other unmatched tool IDs")
func interleavedResultsAfterError() {
    let result = engine.infer([signal(1, age: 40_000, .toolCall(id: "a")),
                               signal(2, age: 39_000, .toolCall(id: "b")),
                               signal(3, age: 38_000, .toolCall(id: "c")),
                               signal(4, age: 30_000, .toolResult(id: "a", outcome: .failure)),
                               signal(5, age: 20_000, .toolResult(id: "b", outcome: .success))],
                              nowMilliseconds: now)
    #expect(result.status == .waiting)
    #expect(result.reason == .possiblyNeedsApproval)
    #expect(result.evidence.pendingTools.map(\.id) == ["c"])
    #expect(result.evidence.decisiveSignal?.signal.sequence == 3)
}

@Test("§10.4: an earlier result cannot resolve a later call with the same ID")
func resultBeforeCall() {
    let result = engine.infer([signal(2, age: 16_000, .toolCall(id: "a")),
                               signal(1, age: 17_000, .toolResult(id: "a", outcome: .success))],
                              nowMilliseconds: now)
    #expect(result.reason == .possiblyNeedsApproval)
    #expect(result.evidence.pendingTools.map(\.id) == ["a"])
}

@Test("§10.4: reused tool ID replaces the old call and restarts its lifetime")
func reusedToolID() {
    let result = engine.infer([signal(1, age: 700_000, .toolCall(id: "a")),
                               signal(2, age: 16_000, .toolCall(id: "a"))], nowMilliseconds: now)
    #expect(result.status == .waiting)
    #expect(result.evidence.pendingTools.count == 1)
    #expect(result.evidence.pendingTools.first?.call.signal.sequence == 2)
}

@Test("§10.4: each pending call expires on its own; newest eligible call supplies evidence")
func individualToolExpiry() {
    let result = engine.infer([signal(1, age: 700_000, .toolCall(id: "expired")),
                               signal(2, age: 80_000, .toolCall(id: "older")),
                               signal(3, age: 70_000, .toolCall(id: "newer"))], nowMilliseconds: now)
    #expect(result.status == .waiting)
    #expect(result.evidence.decisiveSignal?.signal.sequence == 3)
    #expect(result.evidence.pendingTools.map(\.id) == ["expired", "older", "newer"])
}

@Test("§10.4: expired tool cannot infer approval after newer activity")
func expiredToolWithNewActivity() {
    let result = engine.infer([signal(1, age: 700_000, .toolCall(id: "expired")),
                               signal(2, age: 16_000, .activity)], nowMilliseconds: now)
    #expect(result.status == .running)
    #expect(result.reason == .recentActivity)
}

@Test("§10.4: explicit approval needs no silence or timestamp",
      arguments: [Int64?.none, .some(0), .some(15_000), .some(700_000)])
func explicitApproval(age: Int64?) {
    let result = engine.infer([signal(1, age: age, .approvalRequested(toolCallID: nil))],
                              nowMilliseconds: now)
    #expect(result.status == .waiting)
    #expect(result.reason == .needsApproval)
    #expect(result.evidence.decisiveSignal?.signal.kind == .approvalRequested(toolCallID: nil))
}

@Test("§10.4: explicit scoped approval survives unrelated results and resolves by ID")
func explicitApprovalCorrelation() {
    let events = [signal(1, age: 40_000, .toolCall(id: "a")),
                  signal(2, age: 30_000, .approvalRequested(toolCallID: "a")),
                  signal(3, age: 0, .toolResult(id: "other", outcome: .success))]
    #expect(engine.infer(events, nowMilliseconds: now).reason == .needsApproval)
    let result = engine.infer(events + [signal(4, age: 0, .toolResult(id: "a", outcome: .success))],
                              nowMilliseconds: now)
    #expect(result.status == .running)
    #expect(result.evidence.pendingTools.isEmpty)
    #expect(engine.infer(events + [signal(4, age: 0, .activity)], nowMilliseconds: now).status == .running)
}

@Test("§10.4: unscoped approval is superseded by resumed tool activity")
func unscopedApprovalResumed() {
    let result = engine.infer([signal(1, age: nil, .approvalRequested(toolCallID: nil)),
                               signal(2, age: 0, .toolCall(id: "a"))], nowMilliseconds: now)
    #expect(result.status == .running)
    #expect(result.reason == .recentActivity)
}

@Test("§10.4: resolving either concurrent approval leaves the other waiting",
      arguments: ["a", "b"])
func concurrentApprovals(first: String) {
    let remaining = first == "a" ? "b" : "a"
    let events = [signal(1, age: 400, .toolCall(id: "a")),
                  signal(2, age: 300, .toolCall(id: "b")),
                  signal(3, age: 200, .approvalRequested(toolCallID: "a")),
                  signal(4, age: 100, .approvalRequested(toolCallID: "b"))]
    let initial = engine.infer(events, nowMilliseconds: now)
    #expect(initial.evidence.decisiveSignal?.signal.kind == .approvalRequested(toolCallID: "b"))

    // An unscoped request can coexist; later tool activity supersedes that
    // request and resolves only the scoped request for the matching call.
    for history in [events, events + [signal(5, age: 50, .approvalRequested(toolCallID: nil))]] {
        let resolvingFirst = history + [signal(6, age: 20, .toolResult(id: first, outcome: .success))]
        let waiting = engine.infer(resolvingFirst, nowMilliseconds: now)
        #expect(waiting.status == .waiting)
        #expect(waiting.reason == .needsApproval)
        #expect(waiting.evidence.pendingTools.map(\.id) == [remaining])
        #expect(waiting.evidence.decisiveSignal?.signal.kind == .approvalRequested(toolCallID: remaining))

        let resolved = engine.infer(resolvingFirst + [signal(7, age: 0, .toolResult(id: remaining, outcome: .success))],
                                    nowMilliseconds: now)
        #expect(resolved.reason == .recentActivity)
        #expect(resolved.evidence.pendingTools.isEmpty)
    }
}

@Test("ADP-5 / §10.4: missing timestamps do not borrow now",
      arguments: [StatusActivitySignal.Kind.activity, .toolCall(id: "a"), .turnEnded])
func missingTimestamp(kind: StatusActivitySignal.Kind) {
    let result = engine.infer([signal(1, age: nil, kind)], nowMilliseconds: now)
    #expect(result.status == .unknown)
    #expect(result.reason == .unusableTimestamp)
    #expect(result.evidence.latestActivity?.timestampOrigin == .missing)
    #expect(result.evidence.latestActivity?.ageMilliseconds == nil)
}

@Test("ADP-5: missing timestamps inherit previous file time with provenance")
func inheritedTimestamp() {
    let result = engine.infer([signal(3, age: nil, .turnEnded),
                               signal(1, age: 60_000, .activity),
                               signal(2, age: nil, .activity)], nowMilliseconds: now)
    #expect(result.status == .waiting)
    #expect(result.reason == .waitingForReply)
    #expect(result.evidence.latestActivity?.timestampMilliseconds == now - 60_000)
    #expect(result.evidence.latestActivity?.timestampOrigin == .inherited(fromSequence: 1))
}

@Test("ADP-5: last sequence controls both state and silence when record time regresses")
func nonmonotoneTime() {
    let result = engine.infer([signal(2, age: 100_000, .activity),
                               signal(1, age: 0, .sessionEnded)], nowMilliseconds: now)
    #expect(result.status == .unknown)
    #expect(result.reason == .inactive)
    #expect(result.evidence.latestActivity?.signal.sequence == 2)
    #expect(result.evidence.latestActivity?.ageMilliseconds == 100_000)
}

@Test("§10.4: future timestamps cannot establish recency, silence or pending lifetime",
      arguments: [StatusActivitySignal.Kind.activity, .toolCall(id: "a"), .turnEnded])
func futureTimestamp(kind: StatusActivitySignal.Kind) {
    let result = engine.infer([signal(1, age: -1, kind)], nowMilliseconds: now)
    #expect(result.status == .unknown)
    #expect(result.reason == .unusableTimestamp)
    #expect(result.evidence.latestActivity?.timestampMilliseconds == now + 1)
    #expect(result.evidence.latestActivity?.ageMilliseconds == nil)
}

@Test("§10.4: inherited future time remains unusable until a later valid timestamp")
func inheritedFutureTime() {
    let events = [signal(1, age: -1, .activity), signal(2, age: nil, .toolCall(id: "a"))]
    let result = engine.infer(events, nowMilliseconds: now)
    #expect(result.status == .unknown)
    #expect(result.evidence.latestActivity?.timestampOrigin == .inherited(fromSequence: 1))
    let recovered = engine.infer(events + [signal(3, age: 0, .activity)], nowMilliseconds: now)
    #expect(recovered.status == .running)
    #expect(recovered.evidence.latestActivity?.timestampOrigin == .recorded)
}

@Test("§10.4: a valid pending lifetime can establish tool-in-flight despite unknown latest silence")
func toolInFlightWithoutSilence() {
    let result = engine.infer([signal(1, age: 70_000, .toolCall(id: "a")),
                               signal(2, age: -1, .activity)], nowMilliseconds: now)
    #expect(result.status == .running)
    #expect(result.reason == .toolInFlight)
    #expect(result.evidence.decisiveSignal?.signal.sequence == 1)
    #expect(result.evidence.latestActivity?.ageMilliseconds == nil)
}

@Test("§10.4: semantic terminal signals work without usable timing",
      arguments: [Int64?.none, .some(-1)])
func untimedTerminals(age: Int64?) {
    let ended = engine.infer([signal(1, age: age, .sessionEnded)], nowMilliseconds: now)
    #expect(ended.status == .completed)
    #expect(ended.reason == .sessionEnded)
    let failed = engine.infer([signal(1, age: age, .failure(.apiError))], nowMilliseconds: now)
    #expect(failed.status == .failed)
    #expect(failed.reason == .apiError)
}

@Test("ADP-5: sequence ties retain input order rather than sorting by timestamp")
func equalSequences() {
    let failed = signal(1, age: 0, .failure(.turnError))
    let resumed = signal(1, age: 100_000, .activity)
    #expect(engine.infer([failed, resumed], nowMilliseconds: now).status == .unknown)
    #expect(engine.infer([resumed, failed], nowMilliseconds: now).status == .failed)
}

@Test("§10.4: injected now alone moves a pending call through boundary states")
func injectedClock() {
    let events = [signal(1, age: 0, .toolCall(id: "a"))]
    #expect(engine.infer(events, nowMilliseconds: now + 15_000).status == .running)
    #expect(engine.infer(events, nowMilliseconds: now + 15_001).reason == .possiblyNeedsApproval)
    #expect(engine.infer(events, nowMilliseconds: now + 600_001).reason == .pendingToolExpired)
    #expect(engine.infer(events, nowMilliseconds: now) == engine.infer(events, nowMilliseconds: now))
}

@Test("§10.4: elapsed milliseconds saturate safely across Int64 extremes")
func extremeTime() throws {
    let result = engine.infer([.init(sequence: .max, timestampMilliseconds: .min, kind: .turnEnded)],
                              nowMilliseconds: .max)
    #expect(result.status == .completed)
    #expect(result.evidence.latestActivity?.ageMilliseconds == .max)
    #expect(result.evidence.latestActivity?.ageOverflowed == true)
    let extreme = StatusInferenceEngine(thresholds: try .init(approvalSilenceMilliseconds: .max - 1,
        recentActivityMilliseconds: .max, pendingToolLifetimeMilliseconds: .max,
        turnCompletionSilenceMilliseconds: .max))
    #expect(extreme.infer([.init(sequence: 1, timestampMilliseconds: .min, kind: .turnEnded)],
                          nowMilliseconds: .max).status == .completed)
    #expect(extreme.infer([.init(sequence: 1, timestampMilliseconds: .min, kind: .toolCall(id: "a"))],
                          nowMilliseconds: .max).reason == .pendingToolExpired)
}

@Test("§10.4: configurable thresholds are validated and reported in evidence")
func customThresholds() throws {
    let thresholds = try StatusInferenceThresholds(approvalSilenceMilliseconds: 2,
        recentActivityMilliseconds: 4, pendingToolLifetimeMilliseconds: 8,
        turnCompletionSilenceMilliseconds: 10)
    let custom = StatusInferenceEngine(thresholds: thresholds)
    #expect(custom.infer([signal(1, age: 2, .toolCall(id: "a"))], nowMilliseconds: now).status == .running)
    #expect(custom.infer([signal(1, age: 3, .toolCall(id: "a"))], nowMilliseconds: now).status == .waiting)
    #expect(custom.infer([signal(1, age: 9, .toolCall(id: "a"))], nowMilliseconds: now).status == .unknown)
    #expect(custom.infer([signal(1, age: 4, .turnEnded)], nowMilliseconds: now).reason == .waitingForReply)
    #expect(custom.infer([signal(1, age: 10, .turnEnded)], nowMilliseconds: now).reason == .waitingForReply)
    let completed = custom.infer([signal(1, age: 11, .turnEnded)], nowMilliseconds: now)
    #expect(completed.reason == .turnIdleCompleted)
    #expect(completed.evidence.thresholds == thresholds)
    #expect(try StatusInferenceThresholds() == .default)
}

@Test("§10.4: nonpositive and inverted thresholds are rejected", arguments: [Int64.min, -1, 0])
func invalidThresholds(value: Int64) {
    #expect(throws: StatusInferenceThresholds.ValidationError.nonPositive) {
        try StatusInferenceThresholds(approvalSilenceMilliseconds: value)
    }
    #expect(throws: StatusInferenceThresholds.ValidationError.nonPositive) {
        try StatusInferenceThresholds(recentActivityMilliseconds: value)
    }
    #expect(throws: StatusInferenceThresholds.ValidationError.nonPositive) {
        try StatusInferenceThresholds(pendingToolLifetimeMilliseconds: value)
    }
    #expect(throws: StatusInferenceThresholds.ValidationError.nonPositive) {
        try StatusInferenceThresholds(turnCompletionSilenceMilliseconds: value)
    }
}

@Test("§10.4: inconsistent windows cannot create unreachable inference states")
func inconsistentThresholds() {
    #expect(throws: StatusInferenceThresholds.ValidationError.inconsistentWindows) {
        try StatusInferenceThresholds(approvalSilenceMilliseconds: 60_000)
    }
    #expect(throws: StatusInferenceThresholds.ValidationError.inconsistentWindows) {
        try StatusInferenceThresholds(pendingToolLifetimeMilliseconds: 15_000)
    }
    #expect(throws: StatusInferenceThresholds.ValidationError.inconsistentWindows) {
        try StatusInferenceThresholds(turnCompletionSilenceMilliseconds: 59_999)
    }
}
