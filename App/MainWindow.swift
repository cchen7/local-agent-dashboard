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
                        sessionList
                            .navigationSplitViewColumnWidth(min: 300, ideal: preferredListWidth(geometry.size.width), max: 420)
                            .navigationTitle("Sessions")
                    } detail: {
                        if let session = model.selectedSession, let store = model.store {
                            SessionTranscript(session: session, store: store)
                                .id(session.id)
                        } else {
                            emptyDetail
                        }
                    }
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
