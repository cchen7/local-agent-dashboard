import ADCore
import ADSearch
import SwiftUI

struct MainWindow: View {
    @Bindable var model: DashboardModel

    var body: some View {
        Group {
            if model.page == .tokens {
                NavigationSplitView {
                    sidebar
                } detail: {
                    EmptyPanel(title: "No token usage yet", symbol: "gauge.with.needle",
                               message: "Usage and list-price estimates will appear after indexing.")
                        .accessibilityIdentifier("empty.tokens")
                        .navigationTitle("Token Usage")
                }
            } else if model.page == .projects {
                NavigationSplitView {
                    sidebar
                } content: {
                    EmptyPanel(title: "No projects yet", symbol: "folder",
                               message: "Your local library is empty.")
                        .accessibilityIdentifier("empty.projects")
                        .navigationSplitViewColumnWidth(min: 300, ideal: 356, max: 420)
                        .navigationTitle("Projects")
                } detail: {
                    emptyDetail
                }
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
                            SessionTranscript(session: session, store: store, search: search)
                                .id(TranscriptSelection(session: session.id, query: search?.query))
                        } else {
                            emptyDetail
                        }
                    }
                }
                .searchable(text: $model.sessionSearchText, prompt: Text("Search Sessions"))
                .task(id: SearchInput(text: model.sessionSearchText, offset: model.sessionSearchOffset,
                                       ready: model.store != nil)) { [text = model.sessionSearchText,
                                                                    offset = model.sessionSearchOffset] in
                    await model.observeSessionSearch(text, offset: offset)
                }
            }
        }
        .task(id: model.store != nil) { await model.observeSessionIndex() }
        .overlay(alignment: .bottom) {
            if model.storageFailed {
                Label("Storage could not be opened. Quit and try again.", systemImage: "exclamationmark.triangle")
                    .padding().background(.regularMaterial)
            }
        }
        .toolbar {
            ToolbarItem {
                SettingsLink { Label("Source Access", systemImage: "folder.badge.gearshape") }
                    .accessibilityIdentifier("openSettings")
            }
        }
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
        } else {
            List(selection: $model.selectedSessionID) {
                ForEach(model.sessions) { session in
                    SessionListCell(session: session).tag(session.id)
                }
            }
            .accessibilityIdentifier("sessions.list")
        }
    }

    @ViewBuilder private var emptyDetail: some View {
        if model.sessions.isEmpty || model.page == .projects {
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
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 300)
    }
}

private struct SearchInput: Equatable {
    let text: String
    let offset: Int
    let ready: Bool
}

private struct TranscriptSelection: Hashable {
    let session: SessionKey
    let query: String?
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
