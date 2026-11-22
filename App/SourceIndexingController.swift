import ADAdapters
import ADCore
import ADIngest
import ADStore
import Foundation
import Observation

enum SourceIndexPresentation: Equatable {
    case starting
    case scanning(SourceIndexScan)
    case watching(SourceIndexScan)
    case rescanned(SourceIndexScan)
    case stopping
    case stopped
    case failed(IndexAccessFailure)

    var active: Bool {
        switch self {
        case .starting, .scanning, .watching, .stopping: true
        case .rescanned, .stopped, .failed: false
        }
    }
}

enum IndexAccessFailure: Error, Equatable, Sendable {
    case denied, staleBookmark, rootChanged, unavailable
}

/// One explicit in-process indexing session per registered source.
@MainActor @Observable
final class SourceIndexingController {
    private(set) var progress: [Int64: SourceIndexPresentation] = [:]
    @ObservationIgnored private var jobs: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var rescanRequests: [Int64: AsyncStream<Void>.Continuation] = [:]

    static func supports(_ agent: AgentKind) -> Bool { agent == .claudeCode || agent == .codex || agent == .copilot }

    func start(source: Source, store: AgentStore, mode: JSONLSourceIndexing.Mode = .follow) {
        guard source.enabled, Self.supports(source.agent), let id = source.id, jobs[id] == nil else { return }
        progress[id] = .starting
        let updates = AsyncStream<SourceIndexUpdate>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let requests = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if case .follow = mode { rescanRequests[id] = requests.continuation }
        let worker = Task.detached(priority: .utility) {
            defer { updates.continuation.finish() }
            try await SourceAccessProbe.withIndexingAccess(to: source) { root in
                let report: @Sendable (SourceIndexUpdate) -> Void = { updates.continuation.yield($0) }
                switch source.agent {
                case .claudeCode:
                    let adapter = ClaudeCodeAdapter(includeThinking: try store.indexThinkingBlocksEnabled())
                    try await JSONLSourceIndexing.run(source: source, authorizedRoot: root, adapter: adapter,
                                                     store: store, mode: mode, rescans: requests.stream, onUpdate: report)
                case .codex:
                    try await JSONLSourceIndexing.run(source: source, authorizedRoot: root, adapter: CodexAdapter(),
                                                     store: store, mode: mode, rescans: requests.stream, onUpdate: report)
                case .copilot:
                    try await JSONLSourceIndexing.run(source: source, authorizedRoot: root, adapter: CopilotAdapter(),
                                                     store: store, mode: mode, rescans: requests.stream, onUpdate: report)
                default:
                    throw SourceIndexFailure.invalidSource
                }
            }
        }
        jobs[id] = Task { [weak self] in
            var completed: SourceIndexScan?
            let failure: IndexAccessFailure? = await withTaskCancellationHandler {
                for await update in updates.stream {
                    if Task.isCancelled { break }
                    switch update {
                    case .discovering: self?.progress[id] = .starting
                    case .scanning(let scan): self?.progress[id] = .scanning(scan)
                    case .watching(let scan): self?.progress[id] = .watching(scan)
                    case .rescanned(let scan): completed = scan
                    }
                }
                do {
                    try await worker.value
                    return nil
                } catch is CancellationError {
                    return nil
                } catch let failure as IndexAccessFailure {
                    return failure
                } catch SourceIndexFailure.rootChanged {
                    return .rootChanged
                } catch {
                    return .unavailable
                }
            } onCancel: {
                worker.cancel()
            }
            self?.rescanRequests.removeValue(forKey: id)?.finish()
            self?.jobs[id] = nil
            self?.progress[id] = Task.isCancelled ? .stopped :
                failure.map(SourceIndexPresentation.failed) ?? completed.map(SourceIndexPresentation.rescanned) ?? .stopped
        }
    }

    func canRescan(_ source: Source) -> Bool {
        guard source.enabled, Self.supports(source.agent), let id = source.id,
              progress[id] != .stopping else { return false }
        return jobs[id] == nil || rescanRequests[id] != nil
    }

    func rescan(source: Source, store: AgentStore) {
        guard canRescan(source), let id = source.id else { return }
        if let request = rescanRequests[id] {
            request.yield(())
        } else {
            start(source: source, store: store, mode: .fullRescan)
        }
    }

    func stop(id: Int64) {
        guard let job = jobs[id] else { return }
        progress[id] = .stopping
        job.cancel()
    }

    /// Wait until the worker has stopped and released any scoped bookmark.
    func stopAndWait(id: Int64) async {
        let job = jobs[id]
        stop(id: id)
        await job?.value
        progress[id] = nil
    }
}
