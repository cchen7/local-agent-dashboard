import AppKit
import Foundation
import Observation
import ADCore
import ADPrivacy
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
                return (store, try store.sources())
            }.value
            store = result.0
            sources = result.1
        } catch { storageFailed = true }
    }

    func observeSessionIndex() async {
        guard let store else { return }
        do {
            for try await rows in store.indexedSessionUpdates() {
                let displayed = await Task.detached { rows.map(SessionListItem.init) }.value
                guard !Task.isCancelled else { return }
                sessions = displayed
                if !displayed.contains(where: { $0.id == selectedSessionID }) {
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
            let text = i == 0 ? "API_TOKEN=synthetic-preview-only" : "合成转录 · Synthetic message \(i)"
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

    func grantAccess(to source: Source) async {
        guard let store else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.resolvesAliases = false
        panel.directoryURL = source.rootURL
        panel.message = String(localized: "Choose this agent's source directory. Access is read-only.")
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
