import ADCore

/// Explicit semantic inputs for one session, supplied by a caller without parsing text here.
/// Sequence is file order, not time order. Equal sequences retain input order.
public struct StatusActivitySignal: Equatable, Sendable {
    /// Only actual activity should use `activity`; passive metadata is not a resume signal.
    /// Normal turn ends and session ends are deliberately distinct.
    public enum Kind: Equatable, Sendable {
        case activity
        case toolCall(id: String)
        case toolResult(id: String, outcome: StatusToolOutcome)
        case turnEnded
        case sessionEnded
        case failure(StatusFailure)
        case approvalRequested(toolCallID: String?)
    }

    public let sequence: Int64
    public let timestampMilliseconds: Int64?
    public let kind: Kind

    /// Times are UTC epoch milliseconds; missing times inherit the previous file record (ADP-5).
    public init(sequence: Int64, timestampMilliseconds: Int64?, kind: Kind) {
        self.sequence = sequence
        self.timestampMilliseconds = timestampMilliseconds
        self.kind = kind
    }
}

/// Source-reported failures; no error detection from message wording is performed.
public enum StatusFailure: Equatable, Sendable { case apiError, turnError }

/// A tool result resolves only an earlier call with the same ID.
public enum StatusToolOutcome: Equatable, Sendable { case success, failure }

/// Immutable, validated millisecond windows for SPEC §10.4.
public struct StatusInferenceThresholds: Equatable, Sendable {
    /// Invalid settings are rejected instead of clamped or allowed to trap during inference.
    public enum ValidationError: Error, Equatable, Sendable { case nonPositive, inconsistentWindows }

    public let approvalSilenceMilliseconds: Int64
    public let recentActivityMilliseconds: Int64
    public let pendingToolLifetimeMilliseconds: Int64
    public let turnCompletionSilenceMilliseconds: Int64

    public static let `default` = StatusInferenceThresholds(defaults: ())

    private init(defaults: Void) {
        approvalSilenceMilliseconds = 15_000
        recentActivityMilliseconds = 60_000
        pendingToolLifetimeMilliseconds = 600_000
        turnCompletionSilenceMilliseconds = 1_800_000
    }

    /// Approval silence must precede both recency and tool expiry; the turn-idle window
    /// must end at or after recency. Tool lifetime is otherwise independently configurable.
    public init(approvalSilenceMilliseconds: Int64 = 15_000,
                recentActivityMilliseconds: Int64 = 60_000,
                pendingToolLifetimeMilliseconds: Int64 = 600_000,
                turnCompletionSilenceMilliseconds: Int64 = 1_800_000) throws {
        guard [approvalSilenceMilliseconds, recentActivityMilliseconds,
               pendingToolLifetimeMilliseconds, turnCompletionSilenceMilliseconds].allSatisfy({ $0 > 0 }) else {
            throw ValidationError.nonPositive
        }
        guard approvalSilenceMilliseconds < recentActivityMilliseconds,
              approvalSilenceMilliseconds < pendingToolLifetimeMilliseconds,
              recentActivityMilliseconds <= turnCompletionSilenceMilliseconds else {
            throw ValidationError.inconsistentWindows
        }
        self.approvalSilenceMilliseconds = approvalSilenceMilliseconds
        self.recentActivityMilliseconds = recentActivityMilliseconds
        self.pendingToolLifetimeMilliseconds = pendingToolLifetimeMilliseconds
        self.turnCompletionSilenceMilliseconds = turnCompletionSilenceMilliseconds
    }
}

/// Machine-readable reasons, not display strings. UI localization must preserve the
/// distinction between inferred `possiblyNeedsApproval` and explicit `needsApproval`.
public enum StatusInferenceReason: String, Equatable, Sendable {
    case apiError, turnError, toolResultError
    case sessionEnded, turnIdleCompleted
    case possiblyNeedsApproval, needsApproval, waitingForReply
    case recentActivity, toolInFlight
    case noActivity, unusableTimestamp, pendingToolExpired, inactive
}

/// Provenance of the time used for inference, including ADP-5 inheritance.
public enum StatusTimestampOrigin: Equatable, Sendable {
    case recorded, inherited(fromSequence: Int64), missing
}

/// A semantic signal and the exact timing used to evaluate it. A future or missing
/// timestamp has no age: neither establishes recency, silence, or tool lifetime.
public struct StatusSignalEvidence: Equatable, Sendable {
    public let signal: StatusActivitySignal
    public let timestampMilliseconds: Int64?
    public let timestampOrigin: StatusTimestampOrigin
    public let ageMilliseconds: Int64?
    /// True when elapsed time exceeds Int64.max; age saturates, comparisons still treat it as greater.
    public let ageOverflowed: Bool

    fileprivate init(signal: StatusActivitySignal, previousTime: (value: Int64, sequence: Int64)?, now: Int64) {
        self.signal = signal
        if let timestamp = signal.timestampMilliseconds {
            timestampMilliseconds = timestamp
            timestampOrigin = .recorded
        } else if let previousTime {
            timestampMilliseconds = previousTime.value
            timestampOrigin = .inherited(fromSequence: previousTime.sequence)
        } else {
            timestampMilliseconds = nil
            timestampOrigin = .missing
        }
        if let timestampMilliseconds, timestampMilliseconds <= now {
            let elapsed = now.subtractingReportingOverflow(timestampMilliseconds)
            ageMilliseconds = elapsed.overflow ? .max : elapsed.partialValue
            ageOverflowed = elapsed.overflow
        } else {
            ageMilliseconds = nil
            ageOverflowed = false
        }
    }
}

/// An unmatched call; expired and untimed calls remain visible as evidence.
public struct StatusPendingToolEvidence: Equatable, Sendable {
    public let id: String
    public let call: StatusSignalEvidence
}

/// Inputs supporting the decision; contains only typed signals, IDs and times, never text.
public struct StatusInferenceEvidence: Equatable, Sendable {
    public let nowMilliseconds: Int64
    public let thresholds: StatusInferenceThresholds
    public let latestActivity: StatusSignalEvidence?
    public let decisiveSignal: StatusSignalEvidence?
    public let pendingTools: [StatusPendingToolEvidence]
}

/// Status and typed reason suitable for persistence or localized hover evidence.
public struct StatusInferenceResult: Equatable, Sendable {
    public let status: SessionStatus
    public let reason: StatusInferenceReason
    public let evidence: StatusInferenceEvidence
}

/// Pure SPEC §10.4 / DEV-002 inference: failed → completed → waiting → running.
/// No file access, wall clock, process inspection, timers, store queries or text heuristics.
public struct StatusInferenceEngine: Sendable {
    public let thresholds: StatusInferenceThresholds

    /// Use validated custom thresholds or the specification defaults.
    public init(thresholds: StatusInferenceThresholds = .default) {
        self.thresholds = thresholds
    }

    /// Evaluate a complete activity history for one session. Input may be unsorted.
    /// Later actions resume a session and invalidate prior terminal markers. A normal
    /// turn/session end alone does not erase a preceding failure with no later action.
    /// Scoped explicit approval persists until its result, replacement call, or generic
    /// resumed activity; unscoped approval is superseded by any later tool action.
    /// Explicit approval does not expire by silence; only inferred approval uses tool TTL.
    /// Unmatched tools remain correlated by ID across other actions, until result or expiry.
    /// Regressing times are retained in sequence order; future times are never clamped to now.
    public func infer(_ signals: [StatusActivitySignal], nowMilliseconds: Int64) -> StatusInferenceResult {
        let ordered = signals.enumerated().sorted {
            if $0.element.sequence == $1.element.sequence { return $0.offset < $1.offset }
            return $0.element.sequence < $1.element.sequence
        }
        var previousTime: (value: Int64, sequence: Int64)?
        var latest: StatusSignalEvidence?
        var failure: (reason: StatusInferenceReason, signal: StatusSignalEvidence)?
        var sessionEnd: StatusSignalEvidence?
        var turnEnd: StatusSignalEvidence?
        var approval: (toolID: String?, signal: StatusSignalEvidence)?
        var pending: [StatusPendingToolEvidence] = []

        func resume() {
            failure = nil; sessionEnd = nil; turnEnd = nil
        }

        for (_, signal) in ordered {
            let item = StatusSignalEvidence(signal: signal, previousTime: previousTime, now: nowMilliseconds)
            if let timestamp = signal.timestampMilliseconds {
                previousTime = (timestamp, signal.sequence)
            }
            latest = item
            switch signal.kind {
            case .activity:
                resume()
                approval = nil
            case .toolCall(let id):
                resume()
                if approval?.toolID == nil || approval?.toolID == id { approval = nil }
                pending.removeAll { $0.id == id }
                pending.append(.init(id: id, call: item))
            case .toolResult(let id, let outcome):
                resume()
                if approval?.toolID == nil || approval?.toolID == id { approval = nil }
                pending.removeAll { $0.id == id }
                if outcome == .failure { failure = (.toolResultError, item) }
            case .failure(let error):
                failure = (error == .apiError ? .apiError : .turnError, item)
            case .sessionEnded:
                sessionEnd = item
            case .turnEnded:
                turnEnd = item
            case .approvalRequested(let toolID):
                resume()
                approval = (toolID, item)
            }
        }

        func result(_ status: SessionStatus, _ reason: StatusInferenceReason,
                    _ decisive: StatusSignalEvidence?) -> StatusInferenceResult {
            .init(status: status, reason: reason,
                  evidence: .init(nowMilliseconds: nowMilliseconds, thresholds: thresholds,
                                  latestActivity: latest, decisiveSignal: decisive, pendingTools: pending))
        }

        if let failure { return result(.failed, failure.reason, failure.signal) }
        if let sessionEnd { return result(.completed, .sessionEnded, sessionEnd) }
        let silence = latest?.ageMilliseconds
        let silenceOverflowed = latest?.ageOverflowed == true
        if let turnEnd, let silence, silenceOverflowed || silence > thresholds.turnCompletionSilenceMilliseconds {
            return result(.completed, .turnIdleCompleted, turnEnd)
        }
        if let approval { return result(.waiting, .needsApproval, approval.signal) }
        let eligibleTool = pending.last {
            guard let age = $0.call.ageMilliseconds else { return false }
            return !$0.call.ageOverflowed && age <= thresholds.pendingToolLifetimeMilliseconds
        }
        if let eligibleTool, let silence, silenceOverflowed || silence > thresholds.approvalSilenceMilliseconds {
            return result(.waiting, .possiblyNeedsApproval, eligibleTool.call)
        }
        if let turnEnd, let silence, !silenceOverflowed,
           silence >= thresholds.recentActivityMilliseconds,
           silence <= thresholds.turnCompletionSilenceMilliseconds {
            return result(.waiting, .waitingForReply, turnEnd)
        }
        if let silence, !silenceOverflowed, silence <= thresholds.recentActivityMilliseconds {
            return result(.running, .recentActivity, latest)
        }
        if let eligibleTool { return result(.running, .toolInFlight, eligibleTool.call) }
        guard let latest else { return result(.unknown, .noActivity, nil) }
        if silence == nil { return result(.unknown, .unusableTimestamp, latest) }
        if let expired = pending.last(where: {
            guard let age = $0.call.ageMilliseconds else { return false }
            return $0.call.ageOverflowed || age > thresholds.pendingToolLifetimeMilliseconds
        }) {
            return result(.unknown, .pendingToolExpired, expired.call)
        }
        return result(.unknown, .inactive, latest)
    }
}
