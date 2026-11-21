import AppKit
import Foundation
import Observation
import ADCore
import ADPrivacy
import ADSearch
import ADStore

enum DashboardPage: String, CaseIterable, Identifiable {
    case sessions, projects, tokens
    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .sessions: "Sessions"
        case .projects: "Projects"
        case .tokens: "Token Usage"
        }
    }
    var symbol: String {
        switch self {
        case .sessions: "bubble.left.and.text.bubble.right"
        case .projects: "folder"
        case .tokens: "gauge.with.needle"
        }
    }
}

@MainActor @Observable
final class DashboardModel {
    var page: DashboardPage? = .sessions
    var sources: [Source] = []
    var access: [Int64: SourceAccessStatus] = [:]
    var storageFailed = false
    var verifying = false
    private(set) var sessions: [SessionListItem] = []
    var selectedSessionID: SessionKey?
    private(set) var sessionIndexLoaded = false
    private(set) var sessionIndexFailed = false
    private var loaded = false
    private(set) var store: AgentStore?
    var sessionSearchText = "" {
        didSet { if sessionSearchText != oldValue { sessionSearchOffset = 0 } }
    }
    static let sessionSearchPageSize = 50
    private(set) var sessionSearchOffset = 0
    private var searchForText: String?
    private var searchForOffset = 0
    private var lastSearchState: SessionSearchState = .waiting
    private var searchHome: String?

    var isSearchingSessions: Bool { !sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var sessionSearchState: SessionSearchState {
        searchForText == sessionSearchText && searchForOffset == sessionSearchOffset ? lastSearchState : .waiting
    }

    var selectedMatchKey: String? {
        guard isSearchingSessions, case .results(let results) = sessionSearchState else { return nil }
        return results.hits.first { $0.id == selectedSessionID }?.firstMatchKey
    }

    var selectedSession: SessionListItem? {
        sessions.first { $0.id == selectedSessionID }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            let result = try await Task.detached {
                let directory: URL
                let synthetic = CommandLine.arguments.contains("--synthetic")
                if synthetic {
                    directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDashboard-\(UUID().uuidString)")
                } else {
                    directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true)
                        .appendingPathComponent("AgentDashboard", isDirectory: true)
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
                // This writes only app-owned configuration. No source directory is read at launch.
                let existing = try store.sources()
                let defaults = synthetic ? [] : try SourceAccessProbe.defaultSources()
                for source in defaults where !existing.contains(where: {
                    $0.agent == source.agent && $0.rootURL.standardizedFileURL == source.rootURL.standardizedFileURL
                }) { try store.upsertSource(source) }
                if synthetic && CommandLine.arguments.contains("--synthetic-sessions") {
                    try Self.seedSessions(store, in: directory)
                }
                let home = synthetic ? "/synthetic" : defaults.first?.rootURL.deletingLastPathComponent().path
                return (store, try store.sources(), home)
            }.value
            store = result.0
            sources = result.1
            searchHome = result.2
        } catch { storageFailed = true }
    }

    func observeSessionIndex() async {
        guard let store else { return }
        do {
            for try await rows in store.indexedSessionUpdates() {
                let displayed = await Task.detached { rows.map(SessionListItem.init) }.value
                guard !Task.isCancelled else { return }
                sessions = displayed
                if isSearchingSessions, case .results(let results) = sessionSearchState {
                    selectSearchHit(results)
                } else if !isSearchingSessions && !displayed.contains(where: { $0.id == selectedSessionID }) {
                    selectedSessionID = displayed.first?.id
                }
                sessionIndexLoaded = true
                sessionIndexFailed = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            sessionIndexFailed = true
        }
    }

    func observeSessionSearch(_ text: String, offset: Int) async {
        guard let store, searchIsCurrent(text, offset: offset) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if !sessions.contains(where: { $0.id == selectedSessionID }) { selectedSessionID = sessions.first?.id }
            searchForText = nil
            lastSearchState = .waiting
            return
        }
        do {
            if text != searchForText { try await Task.sleep(for: .milliseconds(150)) }
            for try await _ in store.searchIndexChanges() {
                guard searchIsCurrent(text, offset: offset) else { return }
                let scope = IndexedSearchScope(now: Int64(Date().timeIntervalSince1970 * 1000),
                                               timeZone: .current, hostHome: searchHome)
                let limit = Self.sessionSearchPageSize
                let work = Task.detached(priority: .userInitiated) {
                    try SessionSearch.run(text, in: store, scope: scope, limit: limit, offset: offset)
                }
                let found = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard searchIsCurrent(text, offset: offset) else { return }
                if offset > 0 && found.hits.isEmpty {
                    sessionSearchOffset = 0
                    return
                }
                searchForText = text
                searchForOffset = offset
                lastSearchState = .results(found)
                selectSearchHit(found)
                // At most one query runs at a time. While it runs or cools
                // down, the stream retains one wakeup for all pending writes.
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            guard searchIsCurrent(text, offset: offset) else { return }
            searchForText = text
            searchForOffset = offset
            lastSearchState = error is SearchQuery.Failure || (error as? IndexedSearchFailure) == .invalidFilter
                ? .invalid : .failed
        }
    }

    private func searchIsCurrent(_ text: String, offset: Int) -> Bool {
        !Task.isCancelled && text == sessionSearchText && offset == sessionSearchOffset
    }

    func pageSessionSearch(forward: Bool) {
        guard case .results(let results) = sessionSearchState else { return }
        let size = Self.sessionSearchPageSize
        if forward {
            guard results.sessionCount - sessionSearchOffset > size else { return }
            sessionSearchOffset += size
        } else {
            sessionSearchOffset = max(0, sessionSearchOffset - size)
        }
    }

    private func selectSearchHit(_ results: SessionSearchResults) {
        if !results.hits.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = results.hits.first?.id
        }
    }

    nonisolated private static func seedSessions(_ store: AgentStore, in directory: URL) throws {
        let sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic",
            rootURL: directory.appendingPathComponent("unused-source"), environment: "Synthetic"))
        let primary = SessionKey(agent: .codex, nativeID: "preview-import")
        let other = SessionKey(agent: .codex, nativeID: "preview-docs")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var records: [NormalizedRecord] = [
            .session(.init(key: primary, sourceID: sourceID, environment: "Synthetic",
                           cwd: "/synthetic/projects/client", title: "Verify synthetic import",
                           startedAt: now - 900_000, lastEventAt: now, status: .completed)),
            .session(.init(key: other, sourceID: sourceID, environment: "Synthetic",
                           cwd: "/synthetic/projects/docs", title: "Review synthetic documentation",
                           startedAt: now - 3_600_000, status: .waiting)),
            .event(.init(session: other, sequence: 0, timestamp: now - 3_600_000, kind: .assistant,
                         text: "Documentation preview", dedupeKey: "preview:docs")),
        ]
        for i in 0..<133 {
            let text: String
            switch i {
            case 0: text = "API_TOKEN=synthetic-preview-only"
            case 130: text = "修复登录问题 · Synthetic search target"
            default: text = "合成转录 · Synthetic message \(i)"
            }
            records.append(.event(.init(session: primary, sequence: Int64(i), timestamp: now - 60_000 + Int64(i),
                                       kind: i.isMultiple(of: 2) ? .user : .assistant,
                                       text: text, dedupeKey: "preview:import:\(i)")))
        }
        try store.write(records)
    }

    func verifyAccess() async {
        guard !verifying else { return }
        verifying = true
        defer { verifying = false }
        for source in sources {
            guard let id = source.id else { continue }
            access[id] = await Task.detached { SourceAccessProbe.check(source) }.value
        }
    }

    func chooseCustomSource(agent: AgentKind, name: String, environment: String) async -> SourceAdditionResult {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !environment.isEmpty, store != nil else { return .storageFailed }
        let panel = Self.sourceFolderPanel()
        guard await panel.begin() == .OK, let url = panel.url else { return .cancelled }
        guard Source.isLocalRoot(url) else { return .inaccessible }
        let bytes: Data
        do {
            bytes = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch { return .inaccessible }
        return await registerCustomSource(.init(agent: agent, label: label, rootURL: url, environment: environment,
                                                 access: .bookmark(bytes)))
    }

    /// Save metadata to the app's index only. Do not start a scan or verify access here.
    func registerCustomSource(_ source: Source) async -> SourceAdditionResult {
        guard let store else { return .storageFailed }
        do {
            let (outcome, snapshot) = try await Task.detached {
                let result = try store.registerCustomSource(source)
                return (result, try store.sources())
            }.value
            sources = snapshot
            switch outcome {
            case .added: return .added
            case .alreadyRegistered: return .duplicate
            }
        } catch { return .storageFailed }
    }

    func grantAccess(to source: Source) async {
        guard let store else { return }
        let panel = Self.sourceFolderPanel()
        panel.directoryURL = source.rootURL
        guard await panel.begin() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL == source.rootURL.standardizedFileURL else {
            if let id = source.id { access[id] = .wrongDirectory }
            return
        }
        do {
            var updated = source
            updated.rootURL = url
            updated.access = .bookmark(try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                           includingResourceValuesForKeys: nil, relativeTo: nil))
            _ = try await Task.detached { [updated] in try store.upsertSource(updated) }.value
            sources = try await Task.detached { try store.sources() }.value
            await verifyAccess()
        } catch {
            if let id = source.id { access[id] = .denied }
        }
    }
    private static func sourceFolderPanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.resolvesAliases = false
        panel.message = String(localized: "Choose this agent's source directory. Access is read-only.")
        return panel
    }
}

enum SourceAdditionResult: Equatable {
    case added, duplicate, cancelled, inaccessible, storageFailed
}

enum SessionSearchState: Equatable {
    case waiting
    case results(SessionSearchResults)
    case invalid
    case failed
}

/// Only display-projected metadata reaches the list or its accessibility labels.
struct SessionListItem: Identifiable, Sendable {
    let id: SessionKey
    let title: String?
    let path: String?
    let branch: String?
    let environment: String
    let status: SessionStatus
    let startedAt: Int64?
    let lastActivity: Int64?
    let archived: Bool

    nonisolated init(_ row: IndexedSession) {
        id = row.id
        title = row.title.flatMap { $0.isEmpty ? nil : SecretMasker.mask($0) }
        path = row.workspace.map(SecretMasker.mask)
        branch = row.branch.map(SecretMasker.mask)
        environment = SecretMasker.mask(row.environment)
        status = row.status
        startedAt = row.startedAt
        lastActivity = row.lastActivity
        archived = row.archived
    }
}
