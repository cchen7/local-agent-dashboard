import AppKit
import Foundation
import Observation
import ADCore
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
    private var loaded = false
    private var store: AgentStore?

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            let result = try await Task.detached {
                let directory: URL
                if CommandLine.arguments.contains("--synthetic") {
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
                let defaults = CommandLine.arguments.contains("--synthetic") ? [] : try SourceAccessProbe.defaultSources()
                for source in defaults where !existing.contains(where: {
                    $0.agent == source.agent && $0.rootURL.standardizedFileURL == source.rootURL.standardizedFileURL
                }) { try store.upsertSource(source) }
                return (store, try store.sources())
            }.value
            store = result.0
            sources = result.1
        } catch { storageFailed = true }
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
