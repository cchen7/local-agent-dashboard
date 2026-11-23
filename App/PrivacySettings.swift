import ADPrivacy
import ADStore
import SwiftUI

private struct SecretMaskingSetting: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var secretMaskingEnabled: Bool {
        get { self[SecretMaskingSetting.self] }
        set { self[SecretMaskingSetting.self] = newValue }
    }
}

struct PrivacySettingsPane: View {
    let model: DashboardModel
    @State private var confirmation = false
    @State private var failed = false

    var body: some View {
        Form {
            Section("Displayed session text") {
                Toggle("Mask displayed credentials", isOn: Binding(get: { model.maskSecrets }, set: { enabled in
                    Task { failed = !(await model.setDisplayMasking(enabled)) }
                }))
                .accessibilityIdentifier("privacy.maskDisplay")
                .disabled(model.store == nil || model.changingPrivacy)
                Text("Display masking does not change the local index.").foregroundStyle(.secondary)
            }
            Section("Stored session text") {
                Toggle("Remove credentials from the index", isOn: Binding(get: { model.redactIndexSecrets }, set: { enabled in
                    if enabled { confirmation = true }
                    else { applyRedaction(false) }
                }))
                .accessibilityIdentifier("privacy.redactIndex")
                .disabled(!model.canSetIndexRedaction)
                Text("Recognized credentials are masked in stored text and new imports. Original files stay unchanged.")
                    .foregroundStyle(.secondary)
                if model.sourceIndexing.progress.values.contains(where: \.active) {
                    Text("Stop active indexing before changing stored-text redaction.").foregroundStyle(.secondary)
                }
            }
            ThinkingIndexSection(model: model)
            ExclusionRulesSection(model: model)
            if model.changingPrivacy { ProgressView("Updating privacy settings…").controlSize(.small) }
            if failed { Text("Privacy settings could not be saved.").foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.privacy")
        .alert("Remove recognized credentials from the index?", isPresented: $confirmation) {
            Button("Remove Indexed Credentials", role: .destructive) { applyRedaction(true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces recognized credentials in the live local index. Turning it off does not restore removed values.")
        }
    }

    private func applyRedaction(_ enabled: Bool) {
        Task { failed = !(await model.setIndexRedaction(enabled)) }
    }
}

private struct ExclusionRulesSection: View {
    let model: DashboardModel
    @State private var draft = ""
    @State private var pending: [String]?
    @State private var problem: LocalizedStringResource?
    @State private var update: SessionExclusionUpdate?

    private var rules: [String] { draft.split(whereSeparator: \.isNewline).map(String.init) }
    private var changed: Bool {
        !rules.elementsEqual(model.sessionExclusions) { $0.utf8.elementsEqual($1.utf8) }
    }

    var body: some View {
        Section("Excluded paths") {
            Text("Enter one absolute path or ~/ rule per line. Use /** to include subfolders.")
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body.monospaced())
                .frame(minHeight: 88)
                .accessibilityLabel("Excluded paths")
                .accessibilityIdentifier("privacy.exclusions.editor")
                .disabled(model.changingPrivacy)
            Text("Affected files are reconsidered on their next scan. Removed sessions can return only while their original files are available.")
                .foregroundStyle(.secondary)
            Button("Apply Exclusions", action: confirm).disabled(!changed || !model.canSetIndexRedaction)
                .accessibilityIdentifier("privacy.exclusions.apply")
            if let problem { Text(problem).foregroundStyle(.red) }
            if let update {
                Text("Removed sessions from the local index: \(update.removedSessions)")
                    .accessibilityIdentifier("privacy.exclusions.removed")
                if update.invalidatedFiles > 0 {
                    Text("Files to recheck on the next scan: \(update.invalidatedFiles)").foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { draft = model.sessionExclusions.joined(separator: "\n") }
        .onChange(of: model.sessionExclusions, initial: true) { _, saved in
            if !model.changingPrivacy { draft = saved.joined(separator: "\n") }
        }
        .onChange(of: draft) { _, _ in
            problem = nil
            if changed { update = nil }
        }
        .alert("Apply exclusion rules?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { selected in
            Button("Apply Rules", role: .destructive) { apply(selected) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Matching sessions and their usage will be removed from the local index, including archived sessions. Original files stay unchanged.")
        }
    }

    private func confirm() {
        let proposed = rules
        problem = nil
        do {
            try model.validateSessionExclusions(proposed)
            pending = proposed
        } catch PathExclusions.Failure.invalidRule(let index) {
            problem = "Check path exclusion rule \(index + 1)."
        } catch PathExclusions.Failure.tooManyRules {
            problem = "Enter no more than 64 exclusion rules."
        } catch {
            problem = "Use absolute paths when the home folder is unavailable."
        }
    }

    private func apply(_ selected: [String]) {
        Task {
            do { update = try await model.setSessionExclusions(selected) }
            catch { problem = "Exclusion rules could not be saved." }
        }
    }
}

private struct ThinkingIndexSection: View {
    let model: DashboardModel
    @State private var pending: Bool?
    @State private var failed = false

    var body: some View {
        Section("Thinking blocks") {
            Toggle("Index plaintext thinking", isOn: Binding(get: { model.indexThinkingBlocks }, set: { pending = $0 }))
                .disabled(!model.canSetIndexRedaction)
                .accessibilityIdentifier("privacy.indexThinking")
            Text("This option adds readable Claude Code blocks on the next scan. Original files and token totals stay unchanged.")
                .foregroundStyle(.secondary)
            if failed { Text("Thinking index preference could not be saved.").foregroundStyle(.red) }
        }
        .alert("Change thinking indexing?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { enabled in
            if enabled {
                Button("Enable Thinking Indexing") { apply(true) }
            } else {
                Button("Remove Indexed Thinking", role: .destructive) { apply(false) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { enabled in
            if enabled {
                Text("Readable thinking can contain private text. It will become searchable in the local index after the next scan.")
            } else {
                Text("This removes all previously indexed thinking blocks, including archived copies. Replies and source files remain unchanged.")
            }
        }
    }

    private func apply(_ enabled: Bool) {
        Task { failed = !(await model.setIndexThinking(enabled)) }
    }
}
