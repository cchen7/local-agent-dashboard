import ADAdapters
import ADCore
import ADStore
import Foundation
import Synchronization

/// One full or incremental source pass. Counts contain no paths or log content.
public struct SourceIndexScan: Equatable, Sendable {
    public let totalFiles: Int
    public let checkedFiles: Int
    public let failedFiles: Int
    public let bytesRead: Int64
    public let elapsed: Duration
}

public enum SourceIndexUpdate: Equatable, Sendable {
    case discovering
    case scanning(SourceIndexScan)
    case watching(SourceIndexScan)
    case rescanned(SourceIndexScan)
}

public enum SourceIndexFailure: Error, Equatable, Sendable {
    case invalidSource, rootChanged
}

/// FR-SRC-2 / SPEC §7: own one scan/watch loop for an explicitly selected source.
/// The caller holds read access for the entire call and cancels to stop.
public enum JSONLSourceIndexing {
    public enum Mode: Sendable {
        case follow
        case fullRescan
    }

    public static func run<A: AgentAdapter>(source: Source, authorizedRoot: URL,
                                             adapter: A, store: AgentStore,
                                             mode: Mode = .follow, rescans: AsyncStream<Void>? = nil,
                                             onUpdate: @escaping @Sendable (SourceIndexUpdate) -> Void) async throws {
        guard source.enabled, let sourceID = source.id, source.agent == A.kind else {
            throw SourceIndexFailure.invalidSource
        }
        try Task.checkCancellation()
        let expected = try SourceFileReader.directoryIdentity(root: authorizedRoot)
        let pending = Mutex(PendingSourceChanges())
        let wake = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        // Subscribe first so changes during discovery or the first scan are retained.
        let watcher: FSEventsWatcher?
        let requests: Task<Void, Never>?
        switch mode {
        case .follow:
            watcher = try FSEventsWatcher(authorizedRoot: authorizedRoot) { signal in
                let enqueued = pending.withLock { $0.record(signal, copilotWorkspaces: A.kind == .copilot) }
                if enqueued { wake.continuation.yield(()) }
            }
            requests = rescans.map { requests in
                Task {
                    for await _ in requests {
                        guard !Task.isCancelled else { break }
                        pending.withLock { $0.requestReplay() }
                        wake.continuation.yield(())
                    }
                }
            }
        case .fullRescan:
            watcher = nil
            requests = nil
        }
        defer {
            watcher?.cancel()
            requests?.cancel()
            wake.continuation.finish()
        }

        func checkRoot() throws {
            guard (try? SourceFileReader.directoryIdentity(root: authorizedRoot)) == expected else {
                throw SourceIndexFailure.rootChanged
            }
        }

        func discover() throws -> [FSEventsWatcher.FileID: SourceFile] {
            try checkRoot()
            onUpdate(.discovering)
            let files = try adapter.discover(in: source, authorizedRoot: authorizedRoot)
            try checkRoot()
            return Dictionary(files.map { (FSEventsWatcher.FileID(relativePath: $0.relativePath), $0) },
                              uniquingKeysWith: { first, _ in first })
        }

        func confirmedMissing(_ path: String) throws -> SourceArchiveCandidate? {
            try Task.checkCancellation()
            guard let file = try store.sourceArchiveCandidate(sourceID: sourceID, relativePath: path),
                  (try? SourceFileReader.isMissing(root: authorizedRoot, relativePath: path, expectedRoot: expected)) == true
            else { return nil }
            return file
        }

        func archive(_ files: [SourceArchiveCandidate]) throws {
            guard !files.isEmpty else { return }
            try Task.checkCancellation()
            try checkRoot()
            let now = Int64(Date().timeIntervalSince1970 * 1_000)
            try store.archiveMissingSourceFiles(files, sourceID: sourceID, at: now)
        }

        var known = try discover()
        func scan(_ files: [SourceFile], fullDiscovery: Bool = false, replay: Bool = false) throws -> SourceIndexScan {
            let started = ContinuousClock.now
            func report(checked: Int, failed: Int, bytes: Int64) -> SourceIndexScan {
                .init(totalFiles: files.count, checkedFiles: checked, failedFiles: failed,
                      bytesRead: bytes, elapsed: started.duration(to: .now))
            }
            onUpdate(.scanning(report(checked: 0, failed: 0, bytes: 0)))

            var candidates: [(file: SourceFile, modified: Int64)] = []
            candidates.reserveCapacity(files.count)
            for file in files {
                try Task.checkCancellation()
                let reader = try? SourceFileReader(root: authorizedRoot, relativePath: file.relativePath,
                                                  expectedRoot: expected)
                let modified = (try? reader?.snapshot().modificationTimeNS) ?? Int64.min
                candidates.append((file, modified))
            }
            candidates.sort {
                if $0.modified != $1.modified { return $0.modified > $1.modified }
                return $0.file.relativePath.utf8.lexicographicallyPrecedes($1.file.relativePath.utf8)
            }

            var checked = 0
            var failed = 0
            var bytes: Int64 = 0
            var missing: [SourceArchiveCandidate] = []
            for item in candidates {
                try Task.checkCancellation()
                do {
                    let result = try JSONLFileImporter.importFile(item.file, from: source, authorizedRoot: authorizedRoot,
                                                                 expectedRoot: expected, replay: replay, store: store, adapter: adapter)
                    let (sum, overflow) = bytes.addingReportingOverflow(result.bytesRead)
                    bytes = overflow ? Int64.max : sum
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try checkRoot()
                    if let absent = try confirmedMissing(item.file.relativePath) {
                        missing.append(absent)
                    } else {
                        failed += 1
                    }
                }
                checked += 1
                onUpdate(.scanning(report(checked: checked, failed: failed, bytes: bytes)))
            }
            if fullDiscovery {
                for path in try store.unarchivedTranscriptPaths(sourceID: sourceID)
                where known[.init(relativePath: path)] == nil {
                    if let absent = try confirmedMissing(path) { missing.append(absent) }
                }
            }
            try checkRoot()
            try archive(missing)
            if fullDiscovery {
                try Task.checkCancellation()
                try store.recordSourceScan(sourceID: sourceID, at: Int64(Date().timeIntervalSince1970 * 1000))
            }
            return report(checked: checked, failed: failed, bytes: bytes)
        }

        if case .fullRescan = mode {
            onUpdate(.rescanned(try scan(Array(known.values), fullDiscovery: true, replay: true)))
            return
        }
        onUpdate(.watching(try scan(Array(known.values), fullDiscovery: true)))
        for await _ in wake.stream {
            try Task.checkCancellation()
            guard pending.withLock({ !$0.isEmpty }) else { continue }
            // Coalesce bursts while retaining distinct byte-exact file keys.
            try await Task.sleep(for: .milliseconds(300))
            let request = pending.withLock { $0.take() }
            guard !request.isEmpty else { continue }
            try checkRoot()
            if request.rescan || request.files.contains(where: { known[$0] == nil }) {
                known = try discover()
                onUpdate(.watching(try scan(Array(known.values), fullDiscovery: true, replay: request.replay)))
            } else {
                // A notification alone never authorizes a new file.
                let relevant = request.files.union(request.workspaceFiles.filter { known[$0] != nil })
                if !relevant.isEmpty {
                    onUpdate(.watching(try scan(relevant.compactMap { known[$0] })))
                }
            }
        }
        try Task.checkCancellation()
    }
}

private struct PendingSourceChanges: Sendable {
    private(set) var rescan = false
    private(set) var replay = false
    private(set) var files: Set<FSEventsWatcher.FileID> = []
    private(set) var workspaceFiles: Set<FSEventsWatcher.FileID> = []
    var isEmpty: Bool { !rescan && files.isEmpty && workspaceFiles.isEmpty }

    mutating func requestReplay() {
        replay = true
        rescan = true
        files.removeAll(keepingCapacity: true)
        workspaceFiles.removeAll(keepingCapacity: true)
    }

    mutating func record(_ signal: FSEventsWatcher.Signal, copilotWorkspaces: Bool) -> Bool {
        switch signal {
        case .rescanRequired:
            rescan = true
            files.removeAll(keepingCapacity: true)
            workspaceFiles.removeAll(keepingCapacity: true)
        case .fileChanged(let key):
            let workspaceEvent = copilotWorkspaces ? CopilotWorkspaceTitle.eventPath(forWorkspacePath: key.relativePath) : nil
            guard workspaceEvent != nil || key.relativePath.hasSuffix(".jsonl") || key.relativePath.hasSuffix(".jsonl.zst")
            else { return false }
            if !rescan {
                if let workspaceEvent { workspaceFiles.insert(.init(relativePath: workspaceEvent)) }
                else { files.insert(key) }
                if files.count + workspaceFiles.count > 256 {
                    rescan = true
                    files.removeAll(keepingCapacity: true)
                    workspaceFiles.removeAll(keepingCapacity: true)
                }
            }
        }
        return true
    }

    mutating func take() -> Self {
        let copy = self
        self = .init()
        return copy
    }
}
