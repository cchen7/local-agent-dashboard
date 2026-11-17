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
            } else {
                NavigationSplitView {
                    sidebar
                } content: {
                    EmptyPanel(title: model.page == .projects ? "No projects yet" : "No sessions yet",
                               symbol: model.page == .projects ? "folder" : "bubble.left.and.text.bubble.right",
                               message: "Your local library is empty.")
                        .accessibilityIdentifier(model.page == .projects ? "empty.projects" : "empty.sessions")
                        .navigationSplitViewColumnWidth(min: 300, ideal: 356, max: 420)
                        .navigationTitle(Text((model.page ?? .sessions).title))
                } detail: {
                    EmptyPanel(title: "Your private, local dashboard", symbol: "lock.shield",
                               message: "Zero network. Read-only sources. Everything stays on this Mac.")
                        .accessibilityIdentifier("empty.detail")
                }
            }
        }
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
