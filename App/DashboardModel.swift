import AppKit
import Foundation
import Observation
import ADCore
import ADInsights
import ADPricing
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
    #if AGENTDASH_SYNTHETIC_ONLY
    var syntheticQALaunchReady = false
    #endif
    private(set) var maskSecrets = true
    private(set) var redactIndexSecrets = false
    private(set) var sessionExclusions: [String] = []
    private(set) var indexThinkingBlocks = false
    private(set) var privacyRevision: UInt64 = 0
    private(set) var changingPrivacy = false
    private(set) var clearingIndex = false
    private(set) var archiveRetention: ArchiveRetention = .forever
    private(set) var toolOutputLimit: ToolOutputArchiveLimit = .standard
    private(set) var archiveMaintenanceFailed = false
    @ObservationIgnored private var archiveTask: Task<Void, Never>?
    @ObservationIgnored private var resumeWrites: Task<Void, Never>?
    private(set) var editingSourceIDs: Set<Int64> = []
    var page: DashboardPage? = .sessions
    var sources: [Source] = []
    var access: [Int64: SourceAccessStatus] = [:]
    var settingsPage: SettingsPage = .general
    private(set) var clockFormat: DashboardClockFormat
    private(set) var showsMenuBarThroughput: Bool
    private(set) var preferredSessionListWidth: CGFloat?
    private(set) var menuBarTokensPerMinute: Int64?
    @ObservationIgnored private var menuBarThroughputTask: Task<Void, Never>?
    private let presentationPrefix: String?

    init() {
        let prefix: String?
        if CommandLine.arguments.contains("--synthetic") {
            // Opt-in relaunch tests own only their exact UUID namespace.
            prefix = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_PRESENTATION_ID"]
                .flatMap(UUID.init(uuidString:)).map { "syntheticPresentation.\($0.uuidString)." }
        } else {
            prefix = ""
        }
        presentationPrefix = prefix
        clockFormat = prefix.flatMap { UserDefaults.standard.string(forKey: $0 + "clockFormat") }
            .flatMap(DashboardClockFormat.init(rawValue:)) ?? .system
        showsMenuBarThroughput = prefix.map { UserDefaults.standard.bool(forKey: $0 + "showsMenuBarThroughput") } ?? false
        preferredSessionListWidth = prefix.flatMap {
            (UserDefaults.standard.object(forKey: $0 + "sessionListWidth") as? NSNumber)?.doubleValue
        }.flatMap { $0.isFinite && (300...420).contains($0) ? CGFloat($0) : nil }
        sourceIndexing.onFollowFailure = { [weak self] id in self?.recordResumesIndexing(false, sourceID: id) }
    }

    func rememberSessionListWidth(_ width: CGFloat) {
        guard width.isFinite else { return }
        let width = min(420, max(300, width))
        guard preferredSessionListWidth != width else { return }
        preferredSessionListWidth = width
        if let prefix = presentationPrefix {
            UserDefaults.standard.set(Double(width), forKey: prefix + "sessionListWidth")
        }
    }

    func setClockFormat(_ format: DashboardClockFormat) {
        guard clockFormat != format else { return }
        clockFormat = format
        if let prefix = presentationPrefix {
            let key = prefix + "clockFormat"
            if format == .system { UserDefaults.standard.removeObject(forKey: key) }
            else { UserDefaults.standard.set(format.rawValue, forKey: key) }
        }
    }

    func setShowsMenuBarThroughput(_ enabled: Bool) {
        guard showsMenuBarThroughput != enabled else { return }
        showsMenuBarThroughput = enabled
        if let prefix = presentationPrefix {
            let key = prefix + "showsMenuBarThroughput"
            if enabled { UserDefaults.standard.set(true, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        restartMenuBarThroughput()
        if enabled, store == nil { Task { await load() } }
    }

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
    @ObservationIgnored private var topicsTask: Task<Void, Never>?
    private var statusPipeline: SessionStatusPipeline?
    private(set) var statusThresholds = StatusInferenceThresholds.default
    private(set) var savingStatusThresholds = false
    private static let statusPreferenceKey = "statusInferenceThresholdsSeconds"
    private var synthetic: Bool { CommandLine.arguments.contains("--synthetic") }
    nonisolated static var syntheticActivity: Bool {
        CommandLine.arguments.contains("--synthetic") &&
            ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_ACTIVITY"] == "1"
    }
    private(set) var store: AgentStore?
    var usageStore: AgentStore? { store }
    private(set) var searchField = SearchFieldQuery()
    @ObservationIgnored private var lastQueryEdit: ContinuousClock.Instant?
    @ObservationIgnored private var pairedSearchPage: SearchPagePair?
    var sessionSearchText: String { searchField.query }

    func editSearchText(_ text: String) { installSearchField(searchField.editingText(text)) }
    func editSearchTokens(_ tokens: [SearchFieldQuery.Token]) { installSearchField(searchField.editingTokens(tokens)) }
    func commitSearchFilters() { installSearchField(searchField.committingFilters()) }

    func removeSearchFilter(_ token: SearchFieldQuery.Token) {
        editSearchTokens(searchField.tokens.filter { $0 != token })
    }

    private func replaceSearchQuery(_ query: String) {
        installSearchField(SearchFieldQuery(query: query))
    }

    private func installSearchField(_ replacement: SearchFieldQuery) {
        guard searchField != replacement else { return }
        if !sessionSearchText.utf8.elementsEqual(replacement.query.utf8) {
            sessionSearchOffset = 0
            lastQueryEdit = .now
            pairedSearchPage = nil
        }
        searchField = replacement
    }
    var groupSessionsByProject = false {
        didSet {
            if !synthetic && groupSessionsByProject != oldValue {
                UserDefaults.standard.set(groupSessionsByProject, forKey: Self.groupSessionsPreference)
            }
        }
    }
    private static let groupSessionsPreference = "groupSessionsByProject"
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
        searchForText?.utf8.elementsEqual(sessionSearchText.utf8) == true && searchForOffset == sessionSearchOffset &&
            searchForOrder == sessionSearchOrder && searchForFilter == libraryFilter ? lastSearchState : .waiting
    }

    var lastNonemptySearchPage: SessionSearchResults? {
        guard case .results(let results) = lastSearchState, !results.hits.isEmpty else { return nil }
        return results
    }

    var selectedTranscriptSearch: SessionTranscriptSearch? {
        guard isSearchingSessions, case .results(let results) = sessionSearchState, let scope = lastSearchScope,
              let hit = results.hits.first(where: { $0.id == selectedSessionID }) else { return nil }
        return .init(query: sessionSearchText, scope: scope, firstMatchKey: hit.firstMatchKey, count: hit.matchCount)
    }

    var selectedSession: SessionListItem? {
        visibleSessions.first { $0.id == selectedSessionID }
    }

    func load() async {
        guard !loaded else { return }
        loaded = true
        do {
            let result = try await Task.detached {
                let directory: URL
                let synthetic = CommandLine.arguments.contains("--synthetic")
                #if AGENTDASH_SYNTHETIC_ONLY
                let startup = try SyntheticStartupFixture.request()
                let live = try SyntheticLiveUpdateFixture.request()
                let resources = try SyntheticResourceFixture.request()
                let transcript = try SyntheticLongTranscript.request()
                let periods = try SyntheticUsagePeriod.request()
                let repricing = try SyntheticRepricing.request()
                let nativeSearch = try SyntheticNativeSearch.request()
                let standardFixtures = startup == nil && live == nil && resources == nil && transcript == nil && periods == nil && repricing == nil && nativeSearch == nil
                if let nativeSearch {
                    guard startup == nil && live == nil && resources == nil && transcript == nil && periods == nil && repricing == nil
                    else { throw StoreError.invalidLocation }
                    directory = try nativeSearch.openMeasurementDirectory()
                } else if let repricing {
                    guard startup == nil && live == nil && resources == nil && transcript == nil && periods == nil else {
                        throw StoreError.invalidLocation
                    }
                    directory = try repricing.openMeasurementDirectory()
                } else if let periods {
                    guard startup == nil && live == nil && resources == nil && transcript == nil else {
                        throw StoreError.invalidLocation
                    }
                    directory = try periods.openMeasurementDirectory()
                } else if let transcript {
                    guard startup == nil && live == nil && resources == nil else { throw StoreError.invalidLocation }
                    directory = try transcript.openMeasurementDirectory()
                } else if let startup {
                    guard live == nil && resources == nil else { throw StoreError.invalidLocation }
                    directory = try startup.openDirectory()
                } else if let resources {
                    guard live == nil else { throw StoreError.invalidLocation }
                    directory = try resources.openDirectory()
                } else if synthetic {
                    directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDashboard-\(UUID().uuidString)")
                } else {
                    throw StoreError.invalidLocation
                }
                #else
                if synthetic {
                    directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDashboard-\(UUID().uuidString)")
                } else {
                    directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                            appropriateFor: nil, create: true)
                        .appendingPathComponent("AgentDashboard", isDirectory: true)
                }
                #endif
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
                let defaults = synthetic ? [] : try SourceAccessProbe.defaultSources()
                let home = synthetic ? "/synthetic" : defaults.first?.rootURL.deletingLastPathComponent().path
                let externalOverride: URL?
                #if AGENTDASH_SYNTHETIC_ONLY
                externalOverride = repricing?.priceDirectory
                #else
                externalOverride = nil
                #endif
                let externalDirectory = synthetic ? externalOverride : home.map {
                    URL(fileURLWithPath: $0).appendingPathComponent(".config/agent-dashboard", isDirectory: true)
                }
                #if AGENTDASH_SYNTHETIC_ONLY
                let previewUsage = standardFixtures && synthetic &&
                    (CommandLine.arguments.contains("--synthetic-usage") ||
                     ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_USAGE"] == "1")
                let startupPricing = startup != nil || resources != nil
                #else
                let previewUsage = false
                let startupPricing = false
                #endif
                let bundled = !synthetic || startupPricing || previewUsage
                    ? Bundle.main.url(forResource: "pricing", withExtension: "json") : nil
                let runtime = LocalPricingRuntime(external: externalDirectory?.appendingPathComponent("pricing.json"),
                                                  bundled: bundled, store: store)
                let initialPricing = await runtime.refresh()
                // This writes only app-owned configuration. No source directory is read at launch.
                if !defaults.isEmpty { try store.installDefaultSources(defaults) }
                #if AGENTDASH_SYNTHETIC_ONLY
                if synthetic && standardFixtures {
                    try Self.installSyntheticFixtures(in: directory, store: store, previewUsage: previewUsage)
                }
                if startup?.preparesIndex == true { try SyntheticStartupFixture.seed(in: directory, store: store) }
                if let live { try live.register(in: store) }
                if let resources, resources.mode == .prepare { try await resources.seed(store) }
                #endif
                let needsOnboarding = try store.needsSourceOnboarding()
                let onboarding = synthetic ? CommandLine.arguments.contains("--synthetic-onboarding") && needsOnboarding
                                           : needsOnboarding
                let retention = try store.archiveRetention()
                if retention != .forever {
                    _ = try store.expireArchivedSessions(now: Self.archiveNow(), hostHome: home)
                }
                return (store, try store.sources(), home, onboarding, runtime, initialPricing,
                        try store.displaySecretMaskingEnabled(), try store.indexSecretRedactionEnabled(),
                        try store.sessionExclusionPatterns(), try store.indexThinkingBlocksEnabled(), retention,
                        try store.toolOutputArchiveLimit(), try store.sourceIDsResumingIndexing())
            }.value
            if CommandLine.arguments.contains("--synthetic"),
               let query = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_SEARCH_QUERY"],
               query.utf8.count <= 512 {
                replaceSearchQuery(query)
            }
            #if AGENTDASH_SYNTHETIC_ONLY
            if SyntheticResourceFixture.current?.mode == .usage || SyntheticUsagePeriod.measuring || SyntheticRepricing.measuring { page = .tokens }
            #endif
            store = result.0
            restartMenuBarThroughput()
            sources = result.1
            searchHome = result.2
            onboardingRequired = result.3
            maskSecrets = result.6
            redactIndexSecrets = result.7
            sessionExclusions = result.8
            indexThinkingBlocks = result.9
            archiveRetention = result.10
            toolOutputLimit = result.11
            scheduleArchiveMaintenance()
            pricing.attach(store: result.0, runtime: result.4, initial: result.5)
            if !synthetic { Task { await verifyAccess(bookmarksOnly: true) } }
            if !synthetic { groupSessionsByProject = UserDefaults.standard.bool(forKey: Self.groupSessionsPreference) }
            if !synthetic, let data = UserDefaults.standard.data(forKey: Self.contextWindowPreferenceKey),
               data.count <= 131_072, let rules = try? JSONDecoder().decode([ModelContextWindow].self, from: data),
               ModelContextWindow.areValid(rules) {
                contextWindowRules = rules
            }
            if !synthetic || ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_TOPICS"] == "1" {
                let store = result.0
                topicsTask = Task(priority: .utility) {
                    if let pipeline = try? TopicIndexPipeline(store: store) { try? await pipeline.run() }
                }
            }
            if !synthetic || Self.syntheticActivity || CommandLine.arguments.contains("--synthetic-status") {
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
            #if AGENTDASH_SYNTHETIC_ONLY
            if let live = SyntheticLiveUpdateFixture.current {
                guard let source = sources.first(where: live.matches) else { throw StoreError.invalidLocation }
                startIndexing(source)
            }
            #endif
            // DEV-109: continue the sources the user left indexing, from their checkpoints.
            let resuming = Set(result.12)
            for source in sources where source.id.map(resuming.contains) == true { startIndexing(source) }
        } catch {
            storageFailed = true
            #if AGENTDASH_SYNTHETIC_ONLY
            if ProcessInfo.processInfo.environment[SyntheticStartupFixture.environmentKey] != nil {
                FileHandle.standardOutput.write(Data("synthetic-startup: fixture unavailable\n".utf8))
            }
            if ProcessInfo.processInfo.environment[SyntheticLiveUpdateFixture.environmentKey] != nil {
                FileHandle.standardOutput.write(Data("synthetic-live-update: fixture unavailable\n".utf8))
            }
            if SyntheticResourceFixture.current != nil {
                SyntheticResourceFixture.report("fixture unavailable")
            }
            if ProcessInfo.processInfo.environment[SyntheticLongTranscript.environmentKey] != nil {
                SyntheticLongTranscript.report("fixture unavailable")
            }
            if ProcessInfo.processInfo.environment[SyntheticUsagePeriod.environmentKey] != nil {
                SyntheticUsagePeriod.report("fixture unavailable")
            }
            if ProcessInfo.processInfo.environment[SyntheticRepricing.environmentKey] != nil {
                SyntheticRepricing.report("fixture unavailable")
            }
            if ProcessInfo.processInfo.environment[SyntheticNativeSearch.environmentKey] != nil {
                SyntheticNativeSearch.report("fixture unavailable")
            }
            #endif
        }
    }

    deinit {
        statusTask?.cancel()
        topicsTask?.cancel()
        menuBarThroughputTask?.cancel()
    }

    private func restartMenuBarThroughput() {
        menuBarThroughputTask?.cancel()
        menuBarTokensPerMinute = nil
        guard showsMenuBarThroughput, let store else { return }
        menuBarThroughputTask = Task(priority: .utility) { [weak self] in
            var lastRead: ContinuousClock.Instant?
            await UsageRefresh.follow(store.menuBarThroughputChanges(), refresh: {
                if let lastRead, lastRead.duration(to: .now) < .seconds(1) {
                    try? await Task.sleep(until: lastRead.advanced(by: .seconds(1)), clock: .continuous)
                }
                guard !Task.isCancelled, self != nil else { return nil }
                lastRead = .now
                let reading = try? await store.menuBarThroughputReading(now: UsageRefresh.now)
                guard !Task.isCancelled else { return nil }
                self?.menuBarTokensPerMinute = reading?.tokens
                return reading?.nextChangeAt
            }, unavailable: { self?.menuBarTokensPerMinute = nil })
        }
    }

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

    func observeSessionIndex() async {
        guard let store else { return }
        let revision = privacyRevision
        let masking = maskSecrets
        do {
            for try await rows in store.indexedSessionUpdates() {
                let snapshot = await Task.detached { SidebarLibrarySnapshot(rows, maskSecrets: masking) }.value
                guard !Task.isCancelled, privacyRevision == revision else { return }
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
            guard !Task.isCancelled, privacyRevision == revision else { return }
            sessionIndexFailed = true
        }
    }

    func observeSessionSearch(_ text: String, offset: Int, order: SessionSearchOrder = .relevance,
                              filter: SessionLibraryFilter? = nil) async {
        let revision = privacyRevision
        let masking = maskSecrets
        guard let store, searchIsCurrent(text, offset: offset, order: order, filter: filter) else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            selectVisibleSession()
            searchForText = nil
            lastSearchState = .waiting
            pairedSearchPage = nil
            return
        }
        do {
            let debouncing = searchForText?.utf8.elementsEqual(text.utf8) != true
            let debounceStart = lastQueryEdit ?? .now
            if debouncing {
                // Measure the pause from the actual edit, not from the
                // later render pass that started this observation.
                let deadline = debounceStart.advanced(by: .milliseconds(150))
                if deadline > .now { try await Task.sleep(until: deadline, clock: .continuous) }
            }
            #if AGENTDASH_SYNTHETIC_ONLY
            let measuredSearch = SyntheticNativeSearch.measuring
            let waiting = debounceStart.duration(to: .now).components
            let debounceMS = measuredSearch && debouncing
                ? Double(waiting.seconds) * 1_000 + Double(waiting.attoseconds) / 1e15 : 0
            #endif
            for try await _ in store.searchIndexChanges(order: order) {
                guard privacyRevision == revision, searchIsCurrent(text, offset: offset, order: order, filter: filter) else { return }
                pairedSearchPage = nil
                let scope = IndexedSearchScope(now: Int64(Date().timeIntervalSince1970 * 1000),
                                               timeZone: .current, hostHome: searchHome, libraryFilter: filter)
                let size = Self.sessionSearchPageSize
                let windowStart = offset - offset % (2 * size)
                let work = Task.detached(priority: .userInitiated) {
                    #if AGENTDASH_SYNTHETIC_ONLY
                    let queryStart = measuredSearch ? DispatchTime.now().uptimeNanoseconds : 0
                    #endif
                    let result = try SessionSearch.run(text, in: store, scope: scope, order: order,
                                                       limit: 2 * size, offset: windowStart, maskSecrets: masking)
                    #if AGENTDASH_SYNTHETIC_ONLY
                    return (result, measuredSearch
                            ? Double(DispatchTime.now().uptimeNanoseconds - queryStart) / 1_000_000 : 0)
                    #else
                    return result
                    #endif
                }
                let response = try await withTaskCancellationHandler {
                    try await work.value
                } onCancel: {
                    work.cancel()
                }
                #if AGENTDASH_SYNTHETIC_ONLY
                let (window, queryMS) = response
                #else
                let window = response
                #endif
                guard privacyRevision == revision, searchIsCurrent(text, offset: offset, order: order, filter: filter) else { return }
                let found = window.page(offset: offset - windowStart, limit: size)
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
                pairedSearchPage = .init(text: text, order: order, filter: filter, revision: revision,
                                         start: windowStart, results: window)
                selectSearchHit(found)
                #if AGENTDASH_SYNTHETIC_ONLY
                if measuredSearch {
                    SyntheticNativeSearchRun.shared.didPublish(text: text, offset: offset,
                                                               matches: found.matchCount, debounce: debounceMS, query: queryMS)
                }
                #endif
                // At most one query runs at a time. While it runs or cools
                // down, the stream retains one wakeup for all pending writes.
                try await Task.sleep(for: .milliseconds(150))
            }
        } catch {
            guard privacyRevision == revision, searchIsCurrent(text, offset: offset, order: order, filter: filter) else { return }
            searchForText = text
            searchForOffset = offset
            searchForOrder = order
            searchForFilter = filter
            pairedSearchPage = nil
            lastSearchState = error is SearchQuery.Failure || (error as? IndexedSearchFailure) == .invalidFilter
                ? .invalid : .failed
        }
    }

    private func searchIsCurrent(_ text: String, offset: Int, order: SessionSearchOrder, filter: SessionLibraryFilter?) -> Bool {
        !Task.isCancelled && text.utf8.elementsEqual(sessionSearchText.utf8) &&
            offset == sessionSearchOffset && order == sessionSearchOrder
            && filter == libraryFilter
    }

    func displayText(_ text: String) -> String { maskSecrets ? SecretMasker.mask(text) : text }

    var canSetIndexRedaction: Bool {
        store != nil && !changingPrivacy && !clearingIndex && !sourceIndexing.progress.values.contains { $0.active }
    }

    func setDisplayMasking(_ enabled: Bool) async -> Bool {
        guard let store, !changingPrivacy, !clearingIndex else { return false }
        changingPrivacy = true
        defer { changingPrivacy = false }
        do {
            try await Task.detached { try store.setDisplaySecretMaskingEnabled(enabled) }.value
            if maskSecrets != enabled {
                maskSecrets = enabled
                invalidateTextPresentation()
            }
            return true
        } catch { return false }
    }

    func setIndexRedaction(_ enabled: Bool) async -> Bool {
        guard let store, canSetIndexRedaction else { return false }
        changingPrivacy = true
        defer { changingPrivacy = false }
        do {
            let changed = try await Task.detached(priority: .utility) { try store.setIndexSecretRedactionEnabled(enabled) }.value
            redactIndexSecrets = enabled
            if enabled && changed { invalidateTextPresentation() }
            return true
        } catch { return false }
    }

    func setIndexThinking(_ enabled: Bool) async -> Bool {
        guard let store, canSetIndexRedaction else { return false }
        changingPrivacy = true
        defer { changingPrivacy = false }
        do {
            let changed = try await Task.detached(priority: .utility) {
                try store.setIndexThinkingBlocksEnabled(enabled)
            }.value
            indexThinkingBlocks = enabled
            if changed && !enabled { invalidateTextPresentation() }
            return true
        } catch { return false }
    }

    func validateSessionExclusions(_ patterns: [String]) throws {
        _ = try PathExclusions(patterns, hostHome: searchHome)
    }

    func setSessionExclusions(_ patterns: [String]) async throws -> SessionExclusionUpdate {
        guard let store, canSetIndexRedaction else { throw PrivacyPolicyChangeFailure.busy }
        changingPrivacy = true
        defer { changingPrivacy = false }
        let home = searchHome
        let update = try await Task.detached(priority: .utility) {
            try store.replaceSessionExclusions(patterns, hostHome: home)
        }.value
        sessionExclusions = patterns
        if update.removedSessions > 0 { invalidateTextPresentation() }
        return update
    }

    var canClearIndex: Bool { canSetIndexRedaction && editingSourceIDs.isEmpty }

    func planIndexClear(_ scope: IndexClearScope) async throws -> IndexClearPlan {
        guard canClearIndex, let store else { throw IndexClearError.indexingActive }
        let home = searchHome
        return try await Task.detached { try store.prepareIndexClear(scope, hostHome: home) }.value
    }

    func applyIndexClear(_ plan: IndexClearPlan) async throws -> IndexClearResult {
        guard canClearIndex, let store else { throw IndexClearError.indexingActive }
        clearingIndex = true
        defer { clearingIndex = false }
        let home = searchHome
        let result = try await Task.detached(priority: .utility) { try store.clearIndex(plan, hostHome: home) }.value
        invalidateTextPresentation()
        return result
    }

    nonisolated static func archiveNow() -> Int64 { Int64(Date().timeIntervalSince1970 * 1_000) }

    func setArchiveRetention(_ policy: ArchiveRetention, now: Int64 = DashboardModel.archiveNow()) async throws -> Int {
        guard canClearIndex, let store else { throw IndexClearError.indexingActive }
        clearingIndex = true
        defer { clearingIndex = false }
        let home = searchHome
        let removed = try await Task.detached(priority: .utility) {
            try store.setArchiveRetention(policy, now: now, hostHome: home)
        }.value
        archiveRetention = policy
        archiveMaintenanceFailed = false
        scheduleArchiveMaintenance()
        if removed > 0 { invalidateTextPresentation() }
        return removed
    }

    func setToolOutputLimit(_ limit: ToolOutputArchiveLimit) async -> Bool {
        guard canClearIndex, let store else { return false }
        clearingIndex = true
        defer { clearingIndex = false }
        do {
            let changed = try await Task.detached(priority: .utility) {
                try store.setToolOutputArchiveLimit(limit)
            }.value
            toolOutputLimit = limit
            if changed { invalidateTextPresentation() }
            return true
        } catch { return false }
    }

    private func scheduleArchiveMaintenance() {
        archiveTask?.cancel()
        guard archiveRetention != .forever else { archiveTask = nil; return }
        archiveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
                await self?.runArchiveMaintenance()
            }
        }
    }

    private func runArchiveMaintenance() async {
        guard let store, archiveRetention != .forever else { return }
        let now = Self.archiveNow()
        let home = searchHome
        do {
            let removed = try await Task.detached(priority: .utility) {
                try store.expireArchivedSessions(now: now, hostHome: home)
            }.value
            archiveMaintenanceFailed = false
            if removed > 0 { invalidateTextPresentation() }
        } catch { archiveMaintenanceFailed = true }
    }

    private func invalidateTextPresentation() {
        sessions = []
        visibleSessions = []
        sidebarEnvironments = []
        sessionIndexLoaded = false
        searchForText = nil
        lastSearchScope = nil
        lastSearchState = .waiting
        pairedSearchPage = nil
        privacyRevision &+= 1
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
        // Keep the adjacent page on the same committed ordering. The normal
        // new page observation independently checks for newer commits.
        if let pair = pairedSearchPage, pair.text.utf8.elementsEqual(sessionSearchText.utf8),
           pair.order == sessionSearchOrder, pair.filter == libraryFilter, pair.revision == privacyRevision,
           sessionSearchOffset >= pair.start, sessionSearchOffset - pair.start < pair.results.hits.count {
            let page = pair.results.page(offset: sessionSearchOffset - pair.start, limit: size)
            searchForOffset = sessionSearchOffset
            lastSearchState = .results(page)
            selectSearchHit(page)
            #if AGENTDASH_SYNTHETIC_ONLY
            if SyntheticNativeSearch.measuring {
                SyntheticNativeSearchRun.shared.didPublish(text: sessionSearchText, offset: sessionSearchOffset,
                                                           matches: page.matchCount, debounce: 0, query: 0)
            }
            #endif
        }
    }

    private struct SearchPagePair {
        let text: String
        let order: SessionSearchOrder
        let filter: SessionLibraryFilter?
        let revision: UInt64
        let start: Int
        let results: SessionSearchResults
    }

    private func selectSearchHit(_ results: SessionSearchResults) {
        if !results.hits.contains(where: { $0.id == selectedSessionID }) {
            selectedSessionID = results.hits.first?.id
        }
    }

    func searchFromTopic(_ term: String) {
        replaceSearchQuery(SearchQuery.quotedLiteral(term))
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

    func openProjectSession(_ id: SessionKey) {
        setLibraryFilter(nil)
        replaceSearchQuery("")
        selectedSessionID = id
        page = .sessions
    }

    func openMenuSearch(_ query: String) {
        setLibraryFilter(nil)
        page = .sessions
        replaceSearchQuery(query)
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

    func verifyAccess(bookmarksOnly: Bool = false) async {
        guard !verifying, let store else { return }
        verifying = true
        defer { verifying = false }
        for source in sources {
            if bookmarksOnly, case .defaultLocation = source.access { continue }
            guard let id = source.id else { continue }
            let result = await Task.detached(priority: .utility) {
                do {
                    let identity = try store.registeredRootIdentity(for: source)
                    return SourceAccessProbe.check(source, expectedIdentity: identity, bookmarkOnly: bookmarksOnly)
                } catch { return SourceAccessStatus.notChecked }
            }.value
            guard sources.contains(where: {
                $0.id == id && $0.access == source.access &&
                    $0.rootURL.path.utf8.elementsEqual(source.rootURL.path.utf8)
            }) else { continue }
            access[id] = result
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
        guard !onboardingRequired, !changingPrivacy, !clearingIndex, let store, let id = selection.id, !editingSourceIDs.contains(id),
              let source = sources.first(where: { $0.id == id }) else { return }
        if sourceIndexing.start(source: source, store: store) { recordResumesIndexing(true, sourceID: id) }
    }

    /// An explicit stop is the only way a running source stops resuming at launch.
    func stopIndexing(_ id: Int64) {
        sourceIndexing.stop(id: id)
        recordResumesIndexing(false, sourceID: id)
    }

    /// DEV-109: keep these small writes in call order without blocking the
    /// main actor while an import batch holds the writer.
    private func recordResumesIndexing(_ resumes: Bool, sourceID: Int64) {
        guard let store else { return }
        let previous = resumeWrites
        resumeWrites = Task {
            await previous?.value
            await Task.detached(priority: .utility) { try? store.setResumesIndexing(resumes, sourceID: sourceID) }.value
        }
    }

    func canRescan(_ source: Source) -> Bool {
        guard !onboardingRequired, !changingPrivacy, !clearingIndex, let id = source.id, store != nil, !editingSourceIDs.contains(id) else { return false }
        return sourceIndexing.canRescan(source)
    }

    var canRescanSources: Bool { sources.contains(where: canRescan) }

    func rescanSource(_ selection: Source) {
        guard let store, let source = sources.first(where: { $0.id == selection.id }), canRescan(source) else { return }
        sourceIndexing.rescan(source: source, store: store)
    }

    func rescanSources() { for source in sources { rescanSource(source) } }

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
        guard !clearingIndex, sourceIndexing.progress[id]?.active != true, editingSourceIDs.insert(id).inserted else {
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
            if !sessionExclusions.isEmpty && !SourceSettings.sameMappings(expected.pathMappings, replacement.pathMappings) {
                invalidateTextPresentation()
            }
        } catch let failure as SourceSettingsEditFailure {
            if let current = try? await Task.detached(operation: { try store.sources() }).value { sources = current }
            throw failure
        }
    }

    func removeSource(_ source: Source) async throws {
        guard let store, let id = source.id, !verifying, !onboardingRequired, !clearingIndex,
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
        guard store != nil, let id = source.id, !clearingIndex, sourceIndexing.progress[id]?.active != true,
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
        guard let store, let id = source.id, !clearingIndex, sourceIndexing.progress[id]?.active != true,
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

#if AGENTDASH_SYNTHETIC_ONLY
struct SyntheticStartupFixture: Sendable {
    static let environmentKey = "AGENTDASH_SYNTHETIC_STARTUP"
    static let firstSession = SessionKey(agent: .codex, nativeID: "startup-preview-0")
    static let firstTitle = "Prepared synthetic session"
    private static let current = try? request()

    let preparesIndex: Bool
    let id: UUID

    static func marker(for session: SessionListItem) -> String? {
        guard session.id == firstSession, session.title == firstTitle, let current else { return nil }
        return "synthetic-startup: \(current.preparesIndex ? "prepared" : "reopened") row drawn"
    }

    static func request() throws -> Self? {
        guard let value = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard CommandLine.arguments.contains("--synthetic"), parts.count == 2,
              parts[0] == "prepare" || parts[0] == "reopen", let id = UUID(uuidString: String(parts[1]))
        else { throw StoreError.invalidLocation }
        return .init(preparesIndex: parts[0] == "prepare", id: id)
    }

    func openDirectory() throws -> URL {
        let files = FileManager.default
        let directory = files.temporaryDirectory.appendingPathComponent("AgentDashboard-startup-\(id.uuidString)", isDirectory: true)
        if preparesIndex {
            // A prepare request must own a freshly created directory.
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
        } else {
            guard try directory.resourceValues(forKeys: [.fileResourceTypeKey]).fileResourceType == .directory,
                  try directory.appendingPathComponent("index.sqlite")
                    .resourceValues(forKeys: [.fileResourceTypeKey]).fileResourceType == .regular
            else { throw StoreError.invalidLocation }
        }
        return directory
    }

    static func seed(in directory: URL, store: AgentStore) throws {
        let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic startup",
            rootURL: directory.appendingPathComponent("unused-source"), environment: "Synthetic"))
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var records: [NormalizedRecord] = []
        for row in 0..<1_000 {
            let key = row == 0 ? firstSession : SessionKey(agent: .codex, nativeID: "startup-preview-\(row)")
            let timestamp = now - Int64(row) * 10_000
            records.append(.session(.init(key: key, sourceID: source, environment: "Synthetic",
                cwd: "/synthetic/startup", title: row == 0 ? firstTitle : "Synthetic session \(row)",
                startedAt: timestamp, lastEventAt: timestamp)))
            for event in 0..<10 {
                records.append(.event(.init(session: key, sequence: Int64(event), timestamp: timestamp,
                    kind: event.isMultiple(of: 2) ? .user : .assistant,
                    text: "合成启动样例 · Synthetic startup fixture \(row):\(event)",
                    dedupeKey: "startup-preview:\(row):\(event)")))
            }
        }
        try store.write(records)
    }
}
#endif

enum PrivacyPolicyChangeFailure: Error { case busy }
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
    let titleSource: SessionTitleSource?
    let path: String?
    let branch: String?
    let environment: String
    fileprivate let indexedEnvironment: String
    let status: SessionStatus
    let statusReason: String?
    let startedAt: Int64?
    let lastActivity: Int64?
    let archived: Bool
    let usage: IndexedSessionUsageSummary?

    nonisolated init(_ row: IndexedSession, maskSecrets: Bool = true) {
        func visible(_ text: String) -> String { maskSecrets ? SecretMasker.mask(text) : text }
        id = row.id
        title = displayedSessionTitle(row.title, maskSecrets: maskSecrets)
        titleSource = title == nil ? nil : row.titleSource
        path = row.workspace.map(visible)
        branch = row.branch.map(visible)
        environment = visible(row.environment)
        indexedEnvironment = row.environment
        status = row.status
        statusReason = row.statusReason
        startedAt = row.startedAt
        lastActivity = row.lastActivity
        archived = row.archived
        usage = row.usage
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

    init(_ rows: [IndexedSession], maskSecrets: Bool) {
        var counts: [AgentKind: Int] = [:]
        var names: Set<[UInt8]> = []
        sessions = rows.map { row in
            counts[row.id.agent, default: 0] += 1
            names.insert(Array(row.environment.utf8))
            return SessionListItem(row, maskSecrets: maskSecrets)
        }
        agents = AgentKind.allCases.compactMap { agent in counts[agent].map { .init(id: agent, count: $0) } }
        environments = names.map {
            let text = String(decoding: $0, as: UTF8.self)
            return .init(id: $0, label: maskSecrets ? SecretMasker.mask(text) : text)
        }
            .sorted { $0.label == $1.label ? $0.id.lexicographicallyPrecedes($1.id) : $0.label < $1.label }
    }
}
