import SwiftUI
import ADStore
import ADCore

struct SettingsView: View {
    @State private var indexStatus: [Int64: IndexedSourceStatus] = [:]
    @State private var indexStatusUnavailable = false
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
                            if let health = source.id.flatMap({ indexStatus[$0] }) {
                                SourceIndexStatusRows(status: health)
                            }
                        }
                        Spacer()
                        Button("Grant access again") { Task { await model.grantAccess(to: source) } }
                    }
                    .padding(.vertical, 4)
                }
                Button("Verify Access") { Task { await model.verifyAccess() } }
                    .disabled(model.verifying || model.sources.isEmpty)
                if model.verifying { ProgressView() }
                if indexStatusUnavailable { Text("Could not read index status.").foregroundStyle(.red) }
                if model.storageFailed { Text("Storage could not be opened. Quit and try again.").foregroundStyle(.red) }
            }
            .task(id: model.store != nil) { await observeIndexStatus() }
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

    private func observeIndexStatus() async {
        guard let store = model.store else { return }
        do {
            for try await rows in store.indexedSourceStatusUpdates() {
                guard !Task.isCancelled else { return }
                indexStatus = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
                indexStatusUnavailable = false
            }
        } catch {
            if !Task.isCancelled {
                indexStatus = [:]
                indexStatusUnavailable = true
            }
        }
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

private struct SourceIndexStatusRows: View {
    let status: IndexedSourceStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Indexed files: \(status.indexedFiles) of \(status.trackedFiles)")
                .accessibilityIdentifier("source.index.files.\(status.id)")
            HStack(spacing: 8) {
                Text("Indexed sessions: \(status.sessions)")
                    .accessibilityIdentifier("source.index.sessions.\(status.id)")
                Text("Unknown records: \(status.unknownRecords)")
                    .accessibilityIdentifier("source.index.unknown.\(status.id)")
            }
            if status.partialFiles > 0 { Text("Partial files: \(status.partialFiles)") }
            if status.goneFiles > 0 { Text("Missing tracked files: \(status.goneFiles)") }
            if status.archivedSessions > 0 { Text("Archived sessions: \(status.archivedSessions)") }
            if let scan = status.lastScanAt, scan > 0 {
                Text("Last recorded scan: \(Date(timeIntervalSince1970: Double(scan) / 1000), style: .relative)")
            }
            if status.failedFiles > 0 {
                Text("Recorded file errors: \(status.failedFiles)").foregroundStyle(.red)
            }
            if status.hasRecordedSourceError {
                Text("An index error was recorded for this source.").foregroundStyle(.red)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
