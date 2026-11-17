import AppKit
import SwiftUI

@main
struct AgentDashboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = DashboardModel()

    var body: some Scene {
        Window("Agent Dashboard", id: "dashboard") {
            MainWindow(model: model)
                .frame(minWidth: 960, minHeight: 600)
                .task { await model.load() }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Sessions") { model.page = .sessions }.keyboardShortcut("1")
                Button("Projects") { model.page = .projects }.keyboardShortcut("2")
                Button("Token Usage") { model.page = .tokens }.keyboardShortcut("3")
            }
        }

        MenuBarExtra("Agent Dashboard", systemImage: "gauge.with.needle") {
            MenuBarPanel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
                .task { await model.load() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
