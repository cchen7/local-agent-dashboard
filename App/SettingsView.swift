import SwiftUI
import ADCore
import ADPrivacy

struct SettingsView: View {
    @Bindable var model: DashboardModel
    @State private var showsAddSource = false

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
                            Text(verbatim: SecretMasker.mask(source.label)).font(.headline)
                            Text(verbatim: SecretMasker.mask(source.rootURL.path)).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: sourceAgentName(source.agent) + " · " + SecretMasker.mask(source.environment))
                                .font(.caption).foregroundStyle(.secondary)
                            status(model.access[source.id ?? -1] ?? .notChecked)
                        }
                        Spacer()
                        Button("Grant access again") { Task { await model.grantAccess(to: source) } }
                    }
                    .padding(.vertical, 4)
                }
                HStack {
                    Button("Verify Access") { Task { await model.verifyAccess() } }
                        .disabled(model.verifying || model.sources.isEmpty)
                    Spacer()
                    Button("Add Source") { showsAddSource = true }
                        .disabled(model.store == nil)
                        .accessibilityIdentifier("source.add")
                }
                if model.verifying { ProgressView() }
                if model.storageFailed { Text("Storage could not be opened. Quit and try again.").foregroundStyle(.red) }
            }
            .padding()
            .sheet(isPresented: $showsAddSource) { AddSourceSheet(model: model) }
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
        case .wrongDirectory: Text("Could not verify the original source folder. Access was left unchanged.").foregroundStyle(.red)
        case .pathConflict: Text("This path is registered to a different source.").foregroundStyle(.red)
        }
    }
}

private struct AddSourceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: DashboardModel
    @State private var agent = AgentKind.codex
    @State private var name = ""
    @State private var environment = "Local"
    @State private var choosing = false
    @State private var result: SourceAdditionResult = .cancelled

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Source").font(.title2)
            Text("Choose a local directory for this agent. Adding it does not start indexing.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Agent Type", selection: $agent) {
                    ForEach(AgentKind.allCases, id: \.self) { kind in
                        Text(verbatim: sourceAgentName(kind)).tag(kind)
                    }
                }
                TextField("Source Name", text: $name)
                    .accessibilityIdentifier("source.add.name")
                TextField("Environment Label", text: $environment)
                    .accessibilityIdentifier("source.add.environment")
            }
            .disabled(choosing)

            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(choosing)
                Button("Choose Folder…") { Task { await choose() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(choosing || !valid)
                    .accessibilityIdentifier("source.add.choose")
            }
        }
        .padding(22)
        .frame(width: 450)
    }

    private var error: LocalizedStringResource? {
        switch result {
        case .duplicate: "This folder is already registered for this agent. Use Grant access again to update its permission."
        case .pathConflict: "This path is saved for a different source. Choose another folder to keep both sources separate."
        case .inaccessible: "Could not grant read-only access to this folder."
        case .storageFailed: "Could not save the new source."
        case .added, .cancelled: nil
        }
    }

    private func choose() async {
        guard !choosing, valid else { return }
        choosing = true
        defer { choosing = false }
        result = .cancelled
        result = await model.chooseCustomSource(agent: agent, name: name, environment: environment)
        if result == .added { dismiss() }
    }
}

private func sourceAgentName(_ agent: AgentKind) -> String {
    switch agent {
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    case .copilot: "Copilot CLI"
    case .grokBuild: "Grok Build"
    }
}
