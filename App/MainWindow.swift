import ADCore
import ADPrivacy
import ADSearch
import ADStore
import SwiftUI

struct MainWindow: View {
    @Bindable var model: DashboardModel
    @Environment(\.openSettings) private var openSettings
    @State private var searchToSave: SearchToSave?
    @State private var removalFailed = false

    private struct SearchToSave: Identifiable {
        let id = UUID()
        let query: String
        let order: SessionSearchOrder
        let filter: SessionLibraryFilter?
    }

    var body: some View {
        Group {
            if model.page == .tokens {
                NavigationSplitView {
                    sidebar
                } detail: {
                    Group {
                        if let store = model.usageStore {
                            TokenUsageEntry(store: store, pricing: model.pricing, editRedlines: {
                                model.settingsPage = .thresholds
                                openSettings()
                            }, openPricing: {
                                model.settingsPage = .pricing
                                openSettings()
                            })
                        } else {
                            EmptyPanel(title: "No token usage yet", symbol: "gauge.with.needle",
                                       message: "Usage and list-price estimates will appear after indexing.")
                                .accessibilityIdentifier("empty.tokens")
                        }
                    }
                    .navigationTitle("Token Usage")
                }
            } else if model.page == .projects {
                ProjectsBrowser(store: model.store, hostHome: model.projectPathHome,
                                selection: $model.selectedProjectID, openSession: model.openProjectSession) {
                    sidebar
                }
                .id(model.privacyRevision)
            } else {
                GeometryReader { geometry in
                    NavigationSplitView {
                        sidebar
                    } content: {
                        sessionColumn
                            .navigationSplitViewColumnWidth(min: 300, ideal: preferredListWidth(geometry.size.width), max: 420)
                            .navigationTitle("Sessions")
                    } detail: {
                        let search = model.selectedTranscriptSearch
                        if let session = model.selectedSession, let store = model.store,
                           !model.isSearchingSessions || search != nil {
                            SessionTranscript(session: session, store: store, search: search,
                                              contextWindowRules: model.contextWindowRules,
                                              displayCurrency: model.pricing.currency)
                                .id(TranscriptSelection(session: session.id, query: search?.query,
                                                         privacyRevision: model.privacyRevision))
                        } else {
                            emptyDetail
                        }
                    }
                }
                .searchable(text: $model.sessionSearchText, prompt: Text("Search Sessions"))
                .task(id: SearchInput(text: model.sessionSearchText, offset: model.sessionSearchOffset,
                                       order: model.sessionSearchOrder,
                                       filter: model.libraryFilter,
                                       ready: model.store != nil, privacyRevision: model.privacyRevision)) { [text = model.sessionSearchText,
                                                                    offset = model.sessionSearchOffset,
                                                                    order = model.sessionSearchOrder,
                                                                    filter = model.libraryFilter] in
                    await model.observeSessionSearch(text, offset: offset, order: order, filter: filter)
                }
            }
        }
        .task(id: LibraryInput(ready: model.store != nil, privacyRevision: model.privacyRevision)) {
            await model.observeSessionIndex()
        }
        .environment(\.secretMaskingEnabled, model.maskSecrets)
        .task(id: model.store != nil) { await model.observeSmartGroups() }
        .environment(\.sessionOverviewOptions,
                     .init(enabled: !model.isSearchingSessions, searchTopic: { term in
                        model.searchFromTopic(term)
                     }))
        .overlay(alignment: .bottom) {
            if model.storageFailed {
                Label("Storage could not be opened. Quit and try again.", systemImage: "exclamationmark.triangle")
                    .padding().background(.regularMaterial)
            }
        }
        .toolbar {
            if model.page == .sessions, model.isSearchingSessions {
                ToolbarItem {
                    Picker("Search Sort", selection: $model.sessionSearchOrder) {
                        Text("Relevance").tag(SessionSearchOrder.relevance)
                        Text("Most Recent").tag(SessionSearchOrder.recent)
                        Text("Token Volume").tag(SessionSearchOrder.tokens)
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("search.sort")
                }
                ToolbarItem {
                    Button("Save Search…", systemImage: "bookmark") {
                        searchToSave = .init(query: model.sessionSearchText, order: model.sessionSearchOrder, filter: model.libraryFilter)
                    }
                    .accessibilityIdentifier("search.saveSmartGroup")
                    .disabled(!canSaveSearch)
                }
            }
            ToolbarItem {
                SettingsLink { Label("Source Access", systemImage: "folder.badge.gearshape") }
                    .accessibilityIdentifier("openSettings")
            }
        }
        .sheet(item: $searchToSave) { search in
            SmartGroupSaveSheet(query: search.query) { name, query in
                try await model.saveSmartGroup(name: name, query: query, order: search.order, filter: search.filter)
            }
        }
        .alert("Could not remove the smart group.", isPresented: $removalFailed) {}
    }

    private var canSaveSearch: Bool {
        if case .results = model.sessionSearchState { return model.store != nil }
        return false
    }

    @ViewBuilder private var sessionColumn: some View {
        if model.isSearchingSessions {
            switch model.sessionSearchState {
            case .waiting:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .invalid:
                EmptyPanel(title: "Check the search query", symbol: "magnifyingglass",
                           message: "Check quoted phrases and filter values.")
            case .failed:
                EmptyPanel(title: "Could not search sessions", symbol: "exclamationmark.triangle",
                           message: "Edit the query to try again.")
            case .results(let results):
                searchResults(results)
            }
        } else {
            sessionList
        }
    }

    @ViewBuilder private func searchResults(_ results: SessionSearchResults) -> some View {
        if results.hits.isEmpty {
            EmptyPanel(title: "No search matches", symbol: "magnifyingglass",
                       message: "Try a different word or filter.")
        } else {
            let sessions = Dictionary(uniqueKeysWithValues: model.sessions.map { ($0.id, $0) })
            VStack(alignment: .leading, spacing: 0) {
                Text("Matches: \(results.matchCount) · Sessions: \(results.sessionCount)")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                if results.sessionCount > DashboardModel.sessionSearchPageSize {
                    HStack(spacing: 8) {
                        Text("Sessions \(model.sessionSearchOffset + 1)–\(model.sessionSearchOffset + results.hits.count)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.pageSessionSearch(forward: false) } label: {
                            Label("Earlier Results", systemImage: "chevron.left").labelStyle(.iconOnly)
                        }
                        .disabled(model.sessionSearchOffset == 0)
                        Button { model.pageSessionSearch(forward: true) } label: {
                            Label("Later Results", systemImage: "chevron.right").labelStyle(.iconOnly)
                        }
                        .disabled(model.sessionSearchOffset + results.hits.count >= results.sessionCount)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 8)
                }
                List(selection: $model.selectedSessionID) {
                    ForEach(results.hits) { hit in
                        if let session = sessions[hit.id] {
                            SessionListCell(session: session, snippet: hit.snippet).tag(hit.id)
                        }
                    }
                }
            }
            .accessibilityIdentifier("sessions.searchResults")
        }
    }

    @ViewBuilder private var sessionList: some View {
        if model.sessionIndexFailed {
            EmptyPanel(title: "Could not read the session list", symbol: "exclamationmark.triangle",
                       message: "Open the window again to retry.")
        } else if !model.sessionIndexLoaded && !model.storageFailed {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sessions.isEmpty {
            EmptyPanel(title: "No sessions yet", symbol: "bubble.left.and.text.bubble.right",
                       message: "Your local library is empty.")
                .accessibilityIdentifier("empty.sessions")
        } else if model.visibleSessions.isEmpty {
            EmptyPanel(title: "No sessions in this filter", symbol: "line.3.horizontal.decrease.circle",
                       message: "Choose another filter or show all sessions.")
                .accessibilityIdentifier("empty.sessionFilter")
        } else {
            List(selection: $model.selectedSessionID) {
                ForEach(model.visibleSessions) { session in
                    SessionListCell(session: session).tag(session.id)
                }
            }
            .accessibilityIdentifier("sessions.list")
        }
    }

    @ViewBuilder private var emptyDetail: some View {
        if model.sessions.isEmpty {
            EmptyPanel(title: "Your private, local dashboard", symbol: "lock.shield",
                       message: "Zero network. Read-only sources. Everything stays on this Mac.")
                .accessibilityIdentifier("empty.detail")
        } else {
            EmptyPanel(title: "Select a session", symbol: "bubble.left.and.text.bubble.right",
                       message: "Choose an indexed session to read its transcript.")
        }
    }

    private func preferredListWidth(_ windowWidth: CGFloat) -> CGFloat {
        if windowWidth <= 1120 { return 300 + 56 * min(1, max(0, (windowWidth - 960) / 160)) }
        return 356 + 64 * min(1, max(0, (windowWidth - 1120) / 320))
    }

    private var sidebar: some View {
        List(selection: $model.page) {
            Section("Library") {
                ForEach(DashboardPage.allCases) { page in
                    Label { Text(page.title) } icon: { Image(systemName: page.symbol) }.tag(page)
                }
            }
            if model.libraryFilter != nil {
                Button { model.openLibraryFilter(nil) } label: {
                    Label("Clear Sidebar Filter", systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.filter.clear")
            }
            if !model.sidebarAgents.isEmpty {
                Section("Agents") {
                    ForEach(model.sidebarAgents) { row in
                        sidebarFilter(.agent(row.id), icon: "smallcircle.filled.circle",
                                      identifier: "sidebar.agent.\(row.id.rawValue)") {
                            Text(verbatim: row.id.sessionName)
                            Spacer()
                            Text(row.count.formatted()).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            if model.sidebarEnvironments.count > 1 {
                Section("Environments") {
                    ForEach(model.sidebarEnvironments) { row in
                        sidebarFilter(row.filter, icon: "shippingbox", identifier: "sidebar.environment") {
                            Text(verbatim: row.label)
                        }
                    }
                }
            }
            Section("Status") {
                ForEach([SessionStatus.running, .waiting, .completed, .failed], id: \.self) { status in
                    sidebarFilter(.status(status), icon: status.sidebarSymbol,
                                  identifier: "sidebar.status.\(status.rawValue)") {
                        Text(status.label)
                    }
                }
            }
            if !model.smartGroups.isEmpty {
                Section("Smart Groups") {
                    ForEach(model.smartGroups) { group in
                        Button { model.openSmartGroup(group) } label: {
                            Label { Text(verbatim: model.displayText(group.name)) } icon: {
                                Image(systemName: "bookmark")
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Remove Smart Group", role: .destructive) {
                                Task {
                                    do { try await model.removeSmartGroup(group) }
                                    catch { removalFailed = true }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
    }

    private func sidebarFilter<Title: View>(_ filter: SessionLibraryFilter, icon: String, identifier: String,
                                            @ViewBuilder title: () -> Title) -> some View {
        Button {
            model.openLibraryFilter(filter)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                title()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.page == .sessions && model.libraryFilter == filter ? Color.accentColor.opacity(0.15) : .clear)
        .accessibilityAddTraits(model.page == .sessions && model.libraryFilter == filter ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }
}

private extension SessionStatus {
    var sidebarSymbol: String {
        switch self {
        case .running: "play.circle"
        case .waiting: "clock"
        case .completed: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        }
    }
}

private struct SmartGroupSaveSheet: View {
    let query: String
    let save: (String, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var saving = false
    @State private var failure: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Smart Group").font(.title2)
            TextField("Smart Group Name", text: $name)
                .accessibilityIdentifier("smartGroup.name")
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { Task { await saveGroup() } }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("smartGroup.save")
                    .disabled(SavedSessionSearch.validName(name) == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
    }

    private func saveGroup() async {
        guard !saving, let label = SavedSessionSearch.validName(name) else { return }
        saving = true
        defer { saving = false }
        do {
            try await save(label, query)
            dismiss()
        } catch SavedSessionSearchFailure.duplicate {
            failure = "This smart group is already saved."
        } catch SavedSessionSearchFailure.limitReached {
            failure = "Remove a smart group before saving another."
        } catch {
            failure = "Could not save the smart group."
        }
    }
}

private struct SearchInput: Equatable {
    let text: String
    let offset: Int
    let order: SessionSearchOrder
    let filter: SessionLibraryFilter?
    let ready: Bool
    let privacyRevision: UInt64
}

private struct LibraryInput: Equatable {
    let ready: Bool
    let privacyRevision: UInt64
}

private struct TranscriptSelection: Hashable {
    let session: SessionKey
    let query: String?
    let privacyRevision: UInt64
}

struct EmptyPanel: View {
    let title: LocalizedStringResource
    let symbol: String
    let message: LocalizedStringResource

    var body: some View {
        ContentUnavailableView {
            Label { Text(title) } icon: { Image(systemName: symbol) }
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
