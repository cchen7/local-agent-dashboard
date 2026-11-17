import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Agent Dashboard", systemImage: "gauge.with.needle").font(.headline)
            Text("No sessions yet").foregroundStyle(.secondary)
            Text("This foundation build does not index sessions yet.").font(.caption)
            Divider()
            Button("Open Dashboard") {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }.keyboardShortcut("d")
            SettingsLink { Text("Settings…") }.keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(20)
        .frame(width: 360)
    }
}
