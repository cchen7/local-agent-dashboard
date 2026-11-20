import SwiftUI
import ADCore

struct SettingsView: View {
    @Bindable var model: DashboardModel

    var body: some View {
        TabView {
            Form {
                Text("Zero network. Read-only sources. Everything stays on this Mac.")
                    .accessibilityIdentifier("settingsPrivacyPromise")
                Text("This foundation build does not index sessions yet.").foregroundStyle(.secondary)
                LaunchAtLoginControls()
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }

            VStack(alignment: .leading, spacing: 16) {
                Text("Verify Source Access").font(.title2)
                Text("Checks directory entry counts only. No session content is opened.")
                    .foregroundStyle(.secondary)
                List(model.sources) { source in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: source.label).font(.headline)
                            Text(verbatim: source.rootURL.path).font(.caption).foregroundStyle(.secondary)
                            status(model.access[source.id ?? -1] ?? .notChecked)
                        }
                        Spacer()
                        Button("Grant access again") { Task { await model.grantAccess(to: source) } }
                    }
                    .padding(.vertical, 4)
                }
                Button("Verify Access") { Task { await model.verifyAccess() } }
                    .disabled(model.verifying || model.sources.isEmpty)
                if model.verifying { ProgressView() }
                if model.storageFailed { Text("Storage could not be opened. Quit and try again.").foregroundStyle(.red) }
            }
            .padding()
            .tabItem { Label("Sources", systemImage: "folder") }

            VStack(spacing: 12) {
                Text("Agent Dashboard").font(.title)
                Text("Fully local. No network permission.")
                Text("This foundation build does not index sessions yet.").foregroundStyle(.secondary)
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 680, height: 480)
    }

    @ViewBuilder private func status(_ value: SourceAccessStatus) -> some View {
        switch value {
        case .notChecked: Text("Not checked").foregroundStyle(.secondary)
        case .readable(let count): Text("Readable · top-level entries: \(count)").foregroundStyle(.green)
        case .missing: Text("Directory not found").foregroundStyle(.secondary)
        case .denied: Text("Access denied. Grant access again.").foregroundStyle(.red)
        case .staleBookmark: Text("Bookmark is stale. Grant access again.").foregroundStyle(.red)
        case .wrongDirectory: Text("Choose the directory shown above.").foregroundStyle(.red)
        }
    }
}
