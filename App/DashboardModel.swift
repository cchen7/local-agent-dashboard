import AppKit
import Foundation
import Observation
import ADCore
import ADInsights
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
    let sourceIndexing = SourceIndexingController()
    let pricing = PricingModel()
    private(set) var editingSourceIDs: Set<Int64> = []
    var page: DashboardPage? = .sessions
    var sources: [Source] = []
    var access: [Int64: SourceAccessStatus] = [:]
    var settingsPage: SettingsPage = .general
    private(set) var contextWindowRules: [ModelContextWindow] = []
    private static let contextWindowPreferenceKey = "modelContextWindowRules"
    var selectedProjectID: IndexedProject.ID?
    var storageFailed = false
    var verifying = false
    private(set) var onboardingRequired = false
    private(set) var onboardingSaving = false
    private(set) var onboardingChoice: Set<Int64> = []
    private(set) var sourcePreviews: [Int64: SourceFilePreview] = [:]
    private(set) var sessions: [SessionListItem] = []
    var selectedSessionID: SessionKey?
    private(set) var sessionIndexLoaded = false
    private(set) var sessionIndexFailed = false
    private var loaded = false
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    private var statusPipeline: SessionStatusPipeline?
    private(set) var statusThresholds = StatusInferenceThresholds.default
    private(set) var savingStatusThresholds = false
    private static let statusPreferenceKey = "statusInferenceThresholdsSeconds"
    private var synthetic: Bool { CommandLine.arguments.contains("--synthetic") }
    private(set) var store: AgentStore?
    var usageStore: AgentStore? { store }
    var sessionSearchText = "" {
        didSet { if sessionSearchText != oldValue { sessionSearchOffset = 0 } }
    }
    var sessionSearchOrder: SessionSearchOrder = .relevance {
        didSet { if sessionSearchOrder != oldValue { sessionSearchOffset = 0 } }
    }
    static let sessionSearchPageSize = 50
    private(set) var sessionSearchOffset = 0
    private var searchForText: String?
    private var searchForOffset = 0
    private var searchForOrder: SessionSearchOrder = .relevance
    private var searchForFilter: SessionLibraryFilter?
    private var lastSearchState: SessionSearchState = .waiting
    private var lastSearchScope: IndexedSearchScope?
    private var searchHome: String?
    private(set) var smartGroups: [SavedSessionSearch] = []
    private(set) var libraryFilter: SessionLibraryFilter?
    private(set) var visibleSessions: [SessionListItem] = []
    private(set) var sidebarAgents: [SidebarAgent] = []
    private(set) var sidebarEnvironments: [SidebarEnvironment] = []

    var projectPathHome: String? { searchHome }

    var isSearchingSessions: Bool { !sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var sessionSearchState: SessionSearchState {
        searchForText == sessionSearchText && searchForOffset == sessionSearchOffset &&
            searchForOrder == sessionSearchOrder && searchForFilter == libraryFilter ? lastSearchState : .waiting
    }

    var selectedTranscriptSearch: SessionTranscriptSearch? {
        guard isSearchingSessions, case .results(let results) = sessionSearchState, let scope = lastSearchScope,
              let hit = results.hits.first(where: { $0.id == selectedSessionID }) else { return nil }
        return .init(query: sessionSearchText, scope: scope, firstMatchKey: hit.firstMatchKey, count: hit.matchCount)
    }

    var selectedSession: SessionListItem? {
        visibleSessions.first { $0.id == selectedSessionID }
    }

    func load(syntheticPricingDirectory: URL? = nil) async {
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
                let previewUsage = CommandLine.arguments.contains("--synthetic") &&
                    (CommandLine.arguments.contains("--synthetic-usage") ||
                     ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_USAGE"] == "1")
                let defaults = synthetic ? [] : try SourceAccessProbe.defaultSources()
                let home = synthetic ? "/synthetic" : defaults.first?.rootURL.deletingLastPathComponent().path
                let externalDirectory = synthetic ? syntheticPricingDirectory : home.map {
                    URL(fileURLWithPath: $0).appendingPathComponent(".config/agent-dashboard", isDirectory: true)
                }
                let bundled = !synthetic || previewUsage || syntheticPricingDirectory != nil
                    ? Bundle.main.url(forResource: "pricing", withExtension: "json") : nil
                let runtime = LocalPricingRuntime(external: externalDirectory?.appendingPathComponent("pricing.json"),
                                                  bundled: bundled, store: store)
                let initialPricing = await runtime.refresh()
                if previewUsage { try Self.prepareUsageFixture(in: directory, store: store) }
                if CommandLine.arguments.contains("--synthetic"),
                   CommandLine.arguments.contains("--synthetic-indexing-source") ||
                   ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] == "1" {
                    try Self.prepareIndexingFixture(in: directory, store: store)
                }
                if CommandLine.arguments.contains("--synthetic"),
                   CommandLine.arguments.contains("--synthetic-indexing-codex") ||
                   ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_CODEX_SOURCE"] == "1" {
                    try Self.prepareCodexIndexingFixture(in: directory, store: store)
                }
                if synthetic && CommandLine.arguments.contains("--synthetic-indexing-copilot") {
                    try Self.prepareCopilotIndexingFixture(in: directory, store: store)
                }
                // This writes only app-owned configuration. No source directory is read at launch.
                if !defaults.isEmpty { try store.installDefaultSources(defaults) }
                if synthetic && CommandLine.arguments.contains("--synthetic-projects") {
                    try Self.seedProjects(store)
                } else if synthetic && CommandLine.arguments.contains("--synthetic-sessions") {
                    try Self.seedSessions(store, in: directory)
                }
                if synthetic && (CommandLine.arguments.contains("--synthetic-index-status") ||
                    ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_INDEX_STATUS"] == "1") {
                    try Self.seedIndexStatus(store, in: directory)
                }
                let needsOnboarding = try store.needsSourceOnboarding()
                let onboarding = synthetic ? CommandLine.arguments.contains("--synthetic-onboarding") && needsOnboarding
                                           : needsOnboarding
                return (store, try store.sources(), home, onboarding, runtime, initialPricing)
            }.value
            store = result.0
            sources = result.1
            searchHome = result.2
            onboardingRequired = result.3
            pricing.attach(store: result.0, runtime: result.4, initial: result.5)
            if !synthetic, let data = UserDefaults.standard.data(forKey: Self.contextWindowPreferenceKey),
               data.count <= 131_072, let rules = try? JSONDecoder().decode([ModelContextWindow].self, from: data),
               ModelContextWindow.areValid(rules) {
                contextWindowRules = rules
            }
            if !synthetic || CommandLine.arguments.contains("--synthetic-status") {
                statusThresholds = loadStatusThresholds()
                let initial = statusThresholds
                let pipeline = SessionStatusPipeline(store: result.0)
                statusTask = Task { [weak self] in
                    do {
                        try await pipeline.configure(initial)
                        try Task.checkCancellation()
                        self?.statusPipeline = pipeline
                        try await pipeline.run()
                    } catch { self?.statusPipeline = nil }
                }
            }
        } catch { storageFailed = true }
    }

    deinit { statusTask?.cancel() }

    func saveContextWindowRules(_ rules: [ModelContextWindow]) throws {
        guard ModelContextWindow.areValid(rules) else { throw ContextWindowSettingsFailure.invalidRules }
        let data = try JSONEncoder().encode(rules)
        if !synthetic { UserDefaults.standard.set(data, forKey: Self.contextWindowPreferenceKey) }
        contextWindowRules = rules
    }

    private func loadStatusThresholds() -> StatusInferenceThresholds {
        guard !synthetic,
              let values = UserDefaults.standard.array(forKey: Self.statusPreferenceKey) as? [Int],
              values.count == 4 else { return .default }
        return (try? Self.statusThresholds(seconds: values)) ?? .default
    }

    static func statusThresholds(seconds: [Int]) throws -> StatusInferenceThresholds {
        guard seconds.count == 4, seconds.allSatisfy({ (1...604_800).contains($0) }) else {
            throw StatusSettingsFailure.outOfRange
        }
        return try .init(approvalSilenceMilliseconds: Int64(seconds[0]) * 1000,
                         recentActivityMilliseconds: Int64(seconds[1]) * 1000,
                         pendingToolLifetimeMilliseconds: Int64(seconds[2]) * 1000,
                         turnCompletionSilenceMilliseconds: Int64(seconds[3]) * 1000)
    }

    func saveStatusThresholds(_ seconds: [Int]) async throws {
        guard !savingStatusThresholds, let pipeline = statusPipeline else { throw StatusSettingsFailure.unavailable }
        let value = try Self.statusThresholds(seconds: seconds)
        savingStatusThresholds = true
        defer { savingStatusThresholds = false }
        try await pipeline.configure(value)
        if !synthetic { UserDefaults.standard.set(seconds, forKey: Self.statusPreferenceKey) }
        statusThresholds = value
    }

    var canEditStatusThresholds: Bool { statusPipeline != nil }

    nonisolated private static func seedIndexStatus(_ store: AgentStore, in directory: URL) throws {
        let sourceID = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic indexed source",
            rootURL: directory.appendingPathComponent("unused-status-root"), environment: "Synthetic"))
        let fileID = try store.upsertFile(.init(sourceID: sourceID, relativePath: "projects/synthetic.jsonl", role: .session),
                                         checkpoint: nil)
        _ = try store.upsertFile(.init(sourceID: sourceID, relativePath: "projects/pending.jsonl", role: .session),
                                 checkpoint: nil)
        let session = SessionKey(agent: .claudeCode, nativeID: "preview-source-status")
        try store.commitFileBatch([
            .session(.init(key: session, sourceID: sourceID, fileID: fileID, environment: "Synthetic")),
        ], for: fileID, from: nil, to: .init(inode: 11, size: 20, offset: 15, parserVersion: 1,
                                             sequence: 3, previousTimestamp: nil, unknownRecords: 3))
    }

    func observeSessionIndex() async {
        guard let store else { return }
        do {
            for try await rows in store.indexedSessionUpdates() {
                let snapshot = await Task.detached { SidebarLibrarySnapshot(rows) }.value
                guard !Task.isCancelled else { return }
                sessions = snapshot.sessions
                sidebarAgents = snapshot.agents
                sidebarEnvironments = snapshot.environments
                refreshVisibleSessions()
                if isSearchingSessions, case .results(let results) = sessionSearchState {
                    selectSearchHit(results)
                } else if !isSearchingSessions {
                    selectVisibleSession()
                }
                sessionIndexLoaded = true
                sessionIndexFailed = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            sessionIndexFailed = true
        }
    }

    func observeSessionSearch(_ text: String, offset: Int, order: SessionSearchOrder = .relevance,
                              filter: SessionLibraryFilter? = nil) async {
        guard let store, searchIsCurrent(text, offset: offset, order: order, filter: filter) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selectVisibleSession()
            searchForText = nil
            lastSearchState = .waiting
            return
        }
        do {
            if text != searchForText { try await Task.sleep(for: .milliseconds(150)) }
            for try await _ in store.searchIndexChanges(order: order) {
                guard searchIsCurrent(text, offset: offset, order: order, filter: filter) else { return }
                let scope = IndexedSearchScope(now: Int64(Date().timeIntervalSince1970 * 1000),
                                               timeZone: .current, hostHome: searchHome, libraryFilter: filter)
                let limit = Self.sessionSearchPageSize
                let work = Task.detached(priority: .userInitiated) {
                    try SessionSearch.run(text, in: store, scope: scope, order: order, limit: limit, offset: offset)
                }
                let found = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                guard searchIsCurrent(text, offset: offset, order: order, filter: filter) else { return }
                if offset > 0 && found.hits.isEmpty {
                    sessionSearchOffset = 0
                    return
                }
                searchForText = text
                searchForOffset = offset
                searchForOrder = order
                searchForFilter = filter
                lastSearchScope = scope
                lastSearchState = .results(found)
                selectSearchHit(found)
                // At most one query runs at a time. While it runs or cools
                // down, the stream retains one wakeup for all pending writes.
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            guard searchIsCurrent(text, offset: offset, order: order, filter: filter) else { return }
            searchForText = text
            searchForOffset = offset
            searchForOrder = order
            searchForFilter = filter
            lastSearchState = error is SearchQuery.Failure || (error as? IndexedSearchFailure) == .invalidFilter
                ? .invalid : .failed
        }
    }

    private func searchIsCurrent(_ text: String, offset: Int, order: SessionSearchOrder, filter: SessionLibraryFilter?) -> Bool {
        !Task.isCancelled && text == sessionSearchText && offset == sessionSearchOffset && order == sessionSearchOrder
            && filter == libraryFilter
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

    func searchFromTopic(_ term: String) {
        sessionSearchText = SearchQuery.quotedLiteral(term)
    }

    func observeSmartGroups() async {
        guard let store else { return }
        do {
            for try await groups in store.savedSessionSearches() {
                guard !Task.isCancelled else { return }
                smartGroups = groups
            }
        } catch {
            if !Task.isCancelled { smartGroups = [] }
        }
    }

    func saveSmartGroup(name: String, query: String, order: SessionSearchOrder = .relevance,
                        filter: SessionLibraryFilter? = nil) async throws {
        guard let store else { throw SavedSessionSearchFailure.invalidQuery }
        try await Task.detached {
            try store.saveSessionSearch(name: name, query: query, order: order, libraryFilter: filter)
        }.value
    }

    func removeSmartGroup(_ group: SavedSessionSearch) async throws {
        guard let store else { throw SavedSessionSearchFailure.invalidQuery }
        try await Task.detached { try store.removeSessionSearch(group) }.value
    }

    func openSmartGroup(_ group: SavedSessionSearch) {
        openMenuSearch(group.query)
        sessionSearchOrder = group.order
        setLibraryFilter(group.libraryFilter)
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
        for i in 0..<400 {
            let text: String
            switch i {
            case 0: text = "API_TOKEN=synthetic-preview-only"
            case 130: text = "修复登录问题 · Synthetic search target"
            case 260: text = "验证登录配置 · Second synthetic search target"
            case 395: text = "完成登录修复 · Final synthetic search target"
            default: text = "合成转录 · Synthetic message \(i)"
            }
            records.append(.event(.init(session: primary, sequence: Int64(i), timestamp: now - 60_000 + Int64(i),
                                       kind: i.isMultiple(of: 2) ? .user : .assistant,
                                       text: text, dedupeKey: "preview:import:\(i)")))
        }
        if CommandLine.arguments.contains("--synthetic-overview") ||
            ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_OVERVIEW"] == "1" {
            records.append(contentsOf: [
                .event(.init(session: primary, sequence: 1000, timestamp: now - 60_000, kind: .summary,
                             text: "Synthetic checkpoint verified", dedupeKey: "preview:overview:summary")),
                .event(.init(session: primary, sequence: 1001, timestamp: now - 4_000, kind: .toolResult,
                             toolName: "Synthetic check", text: "OVERVIEW_TOKEN=synthetic-overview-only",
                             dedupeKey: "preview:overview:tool")),
            ])
        }
        try store.write(records)
    }

    nonisolated private static func prepareUsageFixture(in directory: URL, store: AgentStore) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var records: [NormalizedRecord] = []
        for (index, agent, model) in [(0, AgentKind.claudeCode, "claude-haiku-5-5"), (1, .codex, "gpt-6.2-sol")] {
            let sourceID = try store.upsertSource(.init(agent: agent, label: "Synthetic usage",
                rootURL: directory.appendingPathComponent("synthetic-usage-\(index)"), environment: "Synthetic"))
            let key = SessionKey(agent: agent, nativeID: "preview-usage-\(index)")
            records.append(.session(.init(key: key, sourceID: sourceID, environment: "Synthetic")))
            for sample in 0..<90 {
                let timestamp = now - Int64(90 - sample) * 300_000 + Int64(index) * 10_000
                let spike = (sample % 18) * (index + 2)
                let fresh = 100 + spike * 40
                let counts = TokenCounts(inputFresh: Int64(fresh), cacheRead: Int64(fresh * 2),
                                         cacheWrite: Int64(25 + spike), output: Int64(50 + spike * 12))
                records.append(.tokens(.init(session: key, timestamp: timestamp,
                    model: sample == 0 ? "synthetic-unpriced" : model, counts: counts,
                    dedupeKey: "preview-usage:\(index):\(sample)")))
            }
        }
        records.append(.rateLimit(.init(agent: .codex, limitID: "synthetic-preview", window: .primary,
                                        timestamp: now - 60_000, windowMinutes: 300, usedPercent: 42,
                                        resetsAt: now + 3_600_000, planType: "Synthetic")))
        try store.write(records)
    }

    nonisolated private static func seedProjects(_ store: AgentStore) throws {
        let home = URL(fileURLWithPath: "/synthetic")
        let codex = try store.upsertSource(.init(agent: .codex, label: "Synthetic Codex",
            rootURL: home.appendingPathComponent(AgentKind.codex.defaultSourceDirectoryName)))
        let claude = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic Claude",
            rootURL: home.appendingPathComponent(AgentKind.claudeCode.defaultSourceDirectoryName)))
        let client = "/synthetic/work/client"
        let primary = SessionKey(agent: .codex, nativeID: "preview-project-client")
        let peer = SessionKey(agent: .claudeCode, nativeID: "preview-project-worktree")
        let docs = SessionKey(agent: .codex, nativeID: "preview-project-docs")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try store.write([
            .session(.init(key: primary, sourceID: codex, environment: "Local",
                           cwd: client, title: "Verify synthetic checkout",
                           startedAt: now - 900_000, lastEventAt: now, status: .completed, gitBranch: "main")),
            .session(.init(key: peer, sourceID: claude, environment: "Local",
                           cwd: client + "/.claude/worktrees/demo", title: "Validate synthetic integration",
                           startedAt: now - 800_000, lastEventAt: now - 30_000, status: .running, gitBranch: "demo")),
            .session(.init(key: docs, sourceID: codex, environment: "Local",
                           cwd: "/synthetic/work/docs", title: "Review synthetic documentation",
                           startedAt: now - 2_000_000, lastEventAt: now - 120_000, status: .waiting)),
            .event(.init(session: primary, sequence: 0, timestamp: now, kind: .assistant,
                         text: "Synthetic checkout verified", dedupeKey: "preview:project:checkout")),
            .event(.init(session: peer, sequence: 0, timestamp: now - 30_000, kind: .toolResult,
                         toolName: "Synthetic check", text: "PROJECT_TOKEN=synthetic-project-secret",
                         dedupeKey: "preview:project:worktree")),
            .event(.init(session: docs, sequence: 0, timestamp: now - 120_000, kind: .assistant,
                         text: "Synthetic documentation reviewed", dedupeKey: "preview:project:docs")),
        ])
    }

    func openProjectSession(_ id: SessionKey) {
        setLibraryFilter(nil)
        sessionSearchText = ""
        selectedSessionID = id
        page = .sessions
    }

    func openMenuSearch(_ query: String) {
        setLibraryFilter(nil)
        page = .sessions
        sessionSearchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionSearchOffset = 0
    }

    func openLibraryFilter(_ filter: SessionLibraryFilter?) {
        page = .sessions
        setLibraryFilter(filter)
    }

    func setLibraryFilter(_ filter: SessionLibraryFilter?) {
        guard filter != libraryFilter else { return }
        libraryFilter = filter
        sessionSearchOffset = 0
        refreshVisibleSessions()
        selectVisibleSession()
    }

    private func refreshVisibleSessions() {
        guard let libraryFilter else { visibleSessions = sessions; return }
        visibleSessions = sessions.filter { session in
            libraryFilter.includes(agent: session.id.agent, environment: session.indexedEnvironment, status: session.status)
        }
    }

    private func selectVisibleSession() {
        if !visibleSessions.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = visibleSessions.first?.id
        }
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

    func previewOnboardingSources() async {
        guard onboardingRequired else { return }
        let pending = sources.filter { source in
            guard let id = source.id else { return false }
            return sourcePreviews[id] == nil
        }
        for source in pending {
            guard !Task.isCancelled, let id = source.id else { return }
            guard sourcePreviews[id] == nil else { continue }
            let task = Task.detached(priority: .utility) { await SourceAccessProbe.preview(source) }
            let reading = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled, onboardingRequired else { return }
            guard sources.contains(where: { $0.id == id && $0.access == source.access }) else { continue }
            sourcePreviews[id] = reading
            if case .available(let count) = reading, count > 0, source.enabled {
                onboardingChoice.insert(id)
            }
        }
    }

    func setOnboardingSource(_ id: Int64, selected: Bool) {
        guard !onboardingSaving, sources.contains(where: { $0.id == id && $0.enabled }),
              case .available(let count) = sourcePreviews[id], count > 0 else { return }
        if selected { onboardingChoice.insert(id) }
        else { onboardingChoice.remove(id) }
    }

    func completeOnboarding(startSelected: Bool) async -> Bool {
        guard onboardingRequired, !onboardingSaving, let store else { return false }
        let targets = startSelected ? sources.filter { source in
            guard source.enabled, let id = source.id, !editingSourceIDs.contains(id),
                  case .available(let count) = sourcePreviews[id], count > 0 else { return false }
            return onboardingChoice.contains(id)
        } : []
        guard !startSelected || !targets.isEmpty else { return false }
        onboardingSaving = true
        defer { onboardingSaving = false }
        do {
            try await Task.detached { try store.completeSourceOnboarding() }.value
            onboardingRequired = false
            targets.forEach(startIndexing)
            return true
        } catch { return false }
    }

    func startIndexing(_ selection: Source) {
        guard !onboardingRequired, let store, let id = selection.id, !editingSourceIDs.contains(id),
              let source = sources.first(where: { $0.id == id }) else { return }
        sourceIndexing.start(source: source, store: store)
    }

    func canRescan(_ source: Source) -> Bool {
        guard !onboardingRequired, let id = source.id, store != nil, !editingSourceIDs.contains(id) else { return false }
        return sourceIndexing.canRescan(source)
    }

    var canRescanSources: Bool { sources.contains(where: canRescan) }

    func rescanSource(_ selection: Source) {
        guard let store, let source = sources.first(where: { $0.id == selection.id }), canRescan(source) else { return }
        sourceIndexing.rescan(source: source, store: store)
    }

    func rescanSources() { for source in sources { rescanSource(source) } }

    nonisolated private static func prepareIndexingFixture(in directory: URL, store: AgentStore) throws {
        let root = directory.appendingPathComponent("synthetic-claude-source")
        let project = root.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("00000000-0000-0000-0000-000000000033.jsonl")
        let text = #"{"type":"user","uuid":"synthetic-index-selection","cwd":"/synthetic/test","message":{"content":"Selected source 索引验证"}}"#
        try Data((text + "\n").utf8).write(to: file)
        try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic Claude source", rootURL: root,
                                     environment: "Synthetic"))
    }

    nonisolated private static func prepareCodexIndexingFixture(in directory: URL, store: AgentStore) throws {
        let root = directory.appendingPathComponent("synthetic-codex-source")
        let day = root.appendingPathComponent("sessions/2026/01/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"00000000-0000-0000-0000-000000000034","cwd":"/synthetic/test"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Selected Codex source 索引验证"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: day.appendingPathComponent("rollout-synthetic.jsonl"))
        try store.upsertSource(.init(agent: .codex, label: "Synthetic Codex source", rootURL: root, environment: "Synthetic"))
    }

    nonisolated private static func prepareCopilotIndexingFixture(in directory: URL, store: AgentStore) throws {
        let root = directory.appendingPathComponent("synthetic-copilot-source")
        let session = root.appendingPathComponent("session-state/synthetic-copilot")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session.start","id":"start","data":{"sessionId":"synthetic-copilot","producer":"synthetic-cli","context":{"cwd":"/synthetic/test"}}}"#,
            #"{"type":"user.message","id":"prompt","data":{"content":"Copilot 合成索引验证","transformedContent":"Synthetic injected text"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: session.appendingPathComponent("events.jsonl"))
        try store.upsertSource(.init(agent: .copilot, label: "Synthetic Copilot source", rootURL: root,
                                     environment: "Synthetic"))
    }

    func chooseCustomSource(agent: AgentKind, name: String, environment: String) async -> SourceAdditionResult {
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !environment.isEmpty, store != nil else { return .storageFailed }
        let panel = Self.sourceFolderPanel()
        guard await panel.begin() == .OK, let url = panel.url else { return .cancelled }
        guard Source.isLocalRoot(url) else { return .inaccessible }
        let identity = await Task.detached { try? SourceFileReader.registrationIdentity(root: url) }.value
        guard let identity else { return .inaccessible }
        let bytes: Data
        do {
            bytes = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                         includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch { return .inaccessible }
        return await registerCustomSource(.init(agent: agent, label: label, rootURL: url, environment: environment,
                                                 access: .bookmark(bytes)), identity: identity)
    }

    /// Save metadata to the app's index only. Do not start a scan or verify access here.
    func registerCustomSource(_ source: Source, identity: SourceRootIdentity) async -> SourceAdditionResult {
        guard let store else { return .storageFailed }
        do {
            let (outcome, snapshot) = try await Task.detached {
                let registered = try store.sources().filter { $0.agent == source.agent }
                let existing = registered.first { SourceAccessProbe.directoryIdentity($0) == identity }
                // Check the saved pathname independently of its bookmark. The
                // newly selected folder can now occupy that pathname under a
                // different spelling, while the bookmark follows the old one.
                let occupiedPath = registered.first {
                    (try? SourceFileReader.registrationIdentity(root: $0.rootURL)) == identity
                }
                let result = try store.registerCustomSource(source, identity: identity,
                                                            existing: existing, occupiedPath: occupiedPath)
                return (result, try store.sources())
            }.value
            sources = snapshot
            switch outcome {
            case .added: return .added
            case .alreadyRegistered: return .duplicate
            case .pathConflict: return .pathConflict
            }
        } catch { return .storageFailed }
    }

    func saveSourceSettings(_ source: Source, replacement: SourceSettings) async throws {
        guard let store, let id = source.id else { throw SourceSettingsEditFailure.missingSource }
        guard sourceIndexing.progress[id]?.active != true, editingSourceIDs.insert(id).inserted else {
            throw SourceSettingsCommitFailure.indexing
        }
        defer { editingSourceIDs.remove(id) }
        let expected = SourceSettings(source)
        let home = searchHome
        do {
            sources = try await Task.detached {
                try store.updateSourceSettings(for: id, from: expected, to: replacement, hostHome: home)
                return try store.sources()
            }.value
        } catch let failure as SourceSettingsEditFailure {
            if let current = try? await Task.detached(operation: { try store.sources() }).value { sources = current }
            throw failure
        }
    }

    func removeSource(_ source: Source) async throws {
        guard let store, let id = source.id, !verifying, !onboardingRequired,
              sources.contains(where: { $0.id == id }), editingSourceIDs.insert(id).inserted
        else { throw SourceSettingsEditFailure.missingSource }
        defer { editingSourceIDs.remove(id) }
        await sourceIndexing.stopAndWait(id: id)
        sources = try await Task.detached {
            try store.removeRegisteredSource(id)
            return try store.sources()
        }.value
        access[id] = nil
        sourcePreviews[id] = nil
        onboardingChoice.remove(id)
    }

    func grantAccess(to source: Source) async {
        guard store != nil, let id = source.id, sourceIndexing.progress[id]?.active != true,
              editingSourceIDs.insert(id).inserted else { return }
        let panel = Self.sourceFolderPanel()
        panel.directoryURL = source.rootURL
        let response = await panel.begin()
        editingSourceIDs.remove(id)
        guard response == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                includingResourceValuesForKeys: nil, relativeTo: nil)
            await applySourceGrant(to: source, selectedRoot: url, bookmark: bookmark)
        } catch { access[id] = .denied }
    }

    func applySourceGrant(to source: Source, selectedRoot: URL, bookmark: Data) async {
        guard let store, let id = source.id, sourceIndexing.progress[id]?.active != true,
              editingSourceIDs.insert(id).inserted else { return }
        defer { editingSourceIDs.remove(id) }
        do {
            let (result, snapshot) = try await Task.detached {
                let identity = try SourceFileReader.registrationIdentity(root: selectedRoot)
                let legacyIdentity: SourceRootIdentity?
                if case .bookmark = source.access { legacyIdentity = SourceAccessProbe.directoryIdentity(source) }
                else { legacyIdentity = nil }
                let savedPathIdentity = try? SourceFileReader.registrationIdentity(root: source.rootURL)
                let result = try store.renewSourceAccess(source, selectedRoot: selectedRoot, identity: identity,
                                                         bookmark: bookmark, legacyBookmarkIdentity: legacyIdentity,
                                                         savedPathIdentity: savedPathIdentity)
                return (result, result == .renewed ? try store.sources() : [])
            }.value
            switch result {
            case .renewed:
                sources = snapshot
                if onboardingRequired {
                    sourcePreviews[id] = nil
                    onboardingChoice.remove(id)
                } else {
                    await verifyAccess()
                }
            case .wrongDirectory: access[id] = .wrongDirectory
            case .pathConflict: access[id] = .pathConflict
            }
        } catch { access[id] = .denied }
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

enum SourceSettingsCommitFailure: Error { case indexing }
enum StatusSettingsFailure: Error { case unavailable, outOfRange }
enum ContextWindowSettingsFailure: Error { case invalidRules }

struct SessionTranscriptSearch: Equatable, Sendable {
    let query: String
    let scope: IndexedSearchScope
    let firstMatchKey: String
    let count: Int
}

enum SourceAdditionResult: Equatable {
    case added, duplicate, pathConflict, cancelled, inaccessible, storageFailed
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
    fileprivate let indexedEnvironment: String
    let status: SessionStatus
    let statusReason: String?
    let startedAt: Int64?
    let lastActivity: Int64?
    let archived: Bool

    nonisolated init(_ row: IndexedSession) {
        id = row.id
        title = row.title.flatMap { $0.isEmpty ? nil : SecretMasker.mask($0) }
        path = row.workspace.map(SecretMasker.mask)
        branch = row.branch.map(SecretMasker.mask)
        environment = SecretMasker.mask(row.environment)
        indexedEnvironment = row.environment
        status = row.status
        statusReason = row.statusReason
        startedAt = row.startedAt
        lastActivity = row.lastActivity
        archived = row.archived
    }
}

struct SidebarAgent: Identifiable, Sendable {
    let id: AgentKind
    let count: Int
}

struct SidebarEnvironment: Identifiable, Sendable {
    let id: [UInt8]
    let label: String
    var filter: SessionLibraryFilter { .environment(String(decoding: id, as: UTF8.self)) }
}

private struct SidebarLibrarySnapshot: Sendable {
    let sessions: [SessionListItem]
    let agents: [SidebarAgent]
    let environments: [SidebarEnvironment]

    init(_ rows: [IndexedSession]) {
        var counts: [AgentKind: Int] = [:]
        var names: Set<[UInt8]> = []
        sessions = rows.map { row in
            counts[row.id.agent, default: 0] += 1
            names.insert(Array(row.environment.utf8))
            return SessionListItem(row)
        }
        agents = AgentKind.allCases.compactMap { agent in counts[agent].map { .init(id: agent, count: $0) } }
        environments = names.map { .init(id: $0, label: SecretMasker.mask(String(decoding: $0, as: UTF8.self))) }
            .sorted { $0.label == $1.label ? $0.id.lexicographicallyPrecedes($1.id) : $0.label < $1.label }
    }
}
