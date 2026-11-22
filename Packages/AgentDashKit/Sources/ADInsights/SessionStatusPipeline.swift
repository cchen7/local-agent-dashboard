import ADCore
import ADStore
import CoreFoundation
import Foundation

/// Refreshes due sessions off the UI actor. The store rejects stale results if
/// a concurrent import changes the session during evaluation.
public actor SessionStatusPipeline {
    private let store: AgentStore
    private var engine: StatusInferenceEngine
    private var policy: String?

    public init(store: AgentStore, thresholds: StatusInferenceThresholds = .default) {
        self.store = store; self.engine = StatusInferenceEngine(thresholds: thresholds)
    }

    /// Reconfigure on the same actor that evaluates status. The writer checks
    /// the policy as well as the session revision before accepting a result.
    public func configure(_ thresholds: StatusInferenceThresholds) throws {
        let key = [thresholds.approvalSilenceMilliseconds, thresholds.recentActivityMilliseconds,
                   thresholds.pendingToolLifetimeMilliseconds, thresholds.turnCompletionSilenceMilliseconds]
            .map(String.init).joined(separator: ":")
        try store.activateStatusPolicy(key)
        engine = StatusInferenceEngine(thresholds: thresholds)
        policy = key
    }

    /// React to committed changes, with one timer for the next due reevaluation.
    /// No periodic reads are performed when nothing can change with time.
    public func run() async throws {
        var due: Task<Void, Never>?
        defer { due?.cancel() }
        for try await schedule in store.statusScheduleUpdates() {
            try Task.checkCancellation()
            due?.cancel()
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            guard let deadline = schedule.hasDirtySessions ? now + 2_000 : schedule.nextDeadline else {
                due = nil
                continue
            }
            let delta = deadline.subtractingReportingOverflow(now)
            let wait = delta.overflow ? Int64.max : max(0, delta.partialValue)
            due = Task {
                do {
                    try await Task.sleep(for: .milliseconds(wait))
                    try Task.checkCancellation()
                    repeat {
                        try refresh()
                        try Task.checkCancellation()
                        // Check again in case a commit invalidated a result
                        // while the dirty flag stayed true across snapshots.
                    } while try store.hasPendingStatusWork(at: Int64(Date().timeIntervalSince1970 * 1_000), policy: policy)
                } catch {
                    // Leave the persisted work pending; a later observation
                    // or explicit restart can retry after a store error.
                }
            }
        }
    }

    /// Returns only changes that can affect the visible status or a search filter.
    @discardableResult
    public func refresh(at now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) throws -> Int {
        var after: Int64 = 0
        var changed = 0
        guard try store.hasPendingStatusWork(at: now, policy: policy) else { return 0 }
        while true {
            try Task.checkCancellation()
            let batch = try store.statusWork(at: now, afterID: after)
            guard let last = batch.last else { return changed }
            var updates: [PersistedStatusUpdate] = []
            for item in batch {
                try Task.checkCancellation()
                if item.archived {
                    updates.append(.init(id: item.id, revision: item.revision, status: .unknown,
                                         reason: "archivedSession", nextAt: nil))
                    continue
                }
                let signals = ActivityProjection.signals(item)
                let result = engine.infer(signals, nowMilliseconds: now)
                let nextAt = nextDeadline(result, now: now)
                updates.append(.init(id: item.id, revision: item.revision, status: result.status,
                                     reason: result.reason.rawValue, nextAt: nextAt,
                                     activity: runningActivity(result)))
            }
            changed += try store.applyStatuses(updates, policy: policy)
            after = last.id
        }
    }

    private func runningActivity(_ result: StatusInferenceResult) -> PersistedRunningActivity? {
        guard result.status == .running else { return nil }
        let evidence = result.evidence
        let lastEventAt = evidence.latestActivity.flatMap {
            $0.ageMilliseconds == nil || $0.ageOverflowed ? nil : $0.timestampMilliseconds
        }
        if evidence.latestActivity?.signal.kind != .turnEnded,
           let call = evidence.pendingTools.last(where: {
               guard let age = $0.call.ageMilliseconds else { return false }
               return !$0.call.ageOverflowed && age <= engine.thresholds.pendingToolLifetimeMilliseconds
           })?.call, let callEventID = call.signal.eventID {
            return .init(action: .pendingTool, callEventID: callEventID, startedAt: call.timestampMilliseconds,
                         lastEventAt: lastEventAt)
        }
        let action: PersistedRunningActivity.Action = switch evidence.latestActivity?.signal.kind {
        case .turnEnded: .turnFinished
        case .toolResult: .toolFinished
        default: .recentActivity
        }
        return .init(action: action, lastEventAt: lastEventAt)
    }

    private func nextDeadline(_ result: StatusInferenceResult, now: Int64) -> Int64? {
        let evidence = result.evidence
        switch result.reason {
        case .apiError, .turnError, .toolResultError, .sessionEnded, .turnIdleCompleted, .needsApproval, .noActivity:
            return nil
        default: break
        }
        let windows = engine.thresholds
        var deadlines: [Int64] = []
        func add(_ timestamp: Int64?, delay: Int64, afterBoundary: Bool = false) {
            guard let timestamp else { return }
            let (boundary, overflow) = timestamp.addingReportingOverflow(delay)
            guard !overflow else { return }
            let (due, edgeOverflow) = boundary.addingReportingOverflow(afterBoundary ? 1 : 0)
            if !edgeOverflow && due > now { deadlines.append(due) }
        }
        let latest = evidence.latestActivity?.timestampMilliseconds
        add(latest, delay: 0) // A future timestamp can eventually become usable.
        add(latest, delay: windows.recentActivityMilliseconds)
        add(latest, delay: windows.recentActivityMilliseconds, afterBoundary: true)
        if signalsMayEndTurn(result) {
            add(latest, delay: windows.turnCompletionSilenceMilliseconds, afterBoundary: true)
        }
        if !evidence.pendingTools.isEmpty {
            add(latest, delay: windows.approvalSilenceMilliseconds, afterBoundary: true)
        }
        for tool in evidence.pendingTools {
            add(tool.call.timestampMilliseconds, delay: 0)
            add(tool.call.timestampMilliseconds, delay: windows.pendingToolLifetimeMilliseconds, afterBoundary: true)
        }
        return deadlines.min()
    }

    private func signalsMayEndTurn(_ result: StatusInferenceResult) -> Bool {
        result.reason == .waitingForReply || result.evidence.latestActivity?.signal.kind == .turnEnded
    }
}

private enum ActivityProjection {
    static func signals(_ item: StatusWorkItem) -> [StatusActivitySignal] {
        var knownCompletions: Set<String> = []
        var resolvedCalls: Set<String> = []
        var result: [StatusActivitySignal] = []
        for event in item.events {
            let metadata: [String: Any]
            if let json = event.metadataJSON, let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                metadata = decoded
            } else { metadata = [:] }
            if boolean(metadata["child_activity"]) == true { continue }
            let signal = metadata["signal"] as? String
            let callID = (metadata["call_id"] as? String) ?? (metadata["tool_use_id"] as? String)
            var kind: StatusActivitySignal.Kind?
            switch event.kind {
            case .user: kind = .activity
            case .assistant: kind = signal == "assistant.turn_end" ? .turnEnded : .activity
            case .toolCall:
                if let callID { knownCompletions.remove(callID); resolvedCalls.remove(callID); kind = .toolCall(id: callID) }
                else { kind = .activity }
            case .toolResult:
                let failed = boolean(metadata["is_error"]) ?? boolean(metadata["success"]).map { !$0 }
                kind = completion(callID, failed: failed, known: &knownCompletions, resolved: &resolvedCalls)
            case .error:
                kind = .failure(item.agent == .claudeCode ? .apiError : .turnError)
            case .system, .summary:
                switch signal {
                case "session.start", "session.resume", "assistant.turn_start", "task_started": kind = .activity
                case "assistant.turn_end", "task_complete": kind = .turnEnded
                case "session.task_complete": kind = boolean(metadata["success"]) == false ? .failure(.turnError) : .turnEnded
                case "session.shutdown": kind = .sessionEnded
                case "approval_requested": kind = .approvalRequested(toolCallID: callID)
                case "exec_command_end", "patch_apply_end", nil:
                    let code = (metadata["exit_code"] as? NSNumber).flatMap { Int64($0.stringValue) }
                    let failed = code.map { $0 != 0 } ?? boolean(metadata["success"]).map { !$0 }
                    if let callID, failed != nil {
                        kind = completion(callID, failed: failed, known: &knownCompletions, resolved: &resolvedCalls)
                    }
                default: break
                }
            case .promptHistory, .thinking, .unknown: break
            }
            if let kind {
                result.append(.init(sequence: event.sequence, timestampMilliseconds: event.timestamp,
                                    kind: kind, eventID: event.id))
            }
        }
        return result
    }

    private static func completion(_ id: String?, failed: Bool?, known: inout Set<String>, resolved: inout Set<String>)
        -> StatusActivitySignal.Kind?
    {
        guard let id else { return failed == true ? .failure(.turnError) : .activity }
        if known.contains(id) || (failed == nil && resolved.contains(id)) { return nil }
        if failed != nil { known.insert(id) }
        resolved.insert(id)
        return .toolResult(id: id, outcome: failed == true ? .failure : .success)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
