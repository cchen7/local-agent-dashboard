import ADCore
import ADStore
import SwiftUI

struct SourceSettingsEditor: View {
    private struct MappingRow: Identifiable {
        let id = UUID()
        var value: PathMapping
    }

    private struct RuleRow: Identifiable {
        let id = UUID()
        var value: EnvironmentRule
    }

    let source: Source
    let persist: @MainActor (SourceSettings) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var environment: String
    @State private var mappings: [MappingRow]
    @State private var rules: [RuleRow]
    @State private var saving = false
    @State private var validationMessage: LocalizedStringResource?

    init(source: Source, persist: @escaping @MainActor (SourceSettings) async throws -> Void) {
        self.source = source
        self.persist = persist
        _label = State(initialValue: source.label)
        _environment = State(initialValue: source.environment)
        _mappings = State(initialValue: source.pathMappings.map { .init(value: $0) })
        _rules = State(initialValue: source.environmentRules.map { .init(value: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Source Settings").font(.title2)
            Text("Changes do not replace folder access or rebuild existing sessions.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LabeledContent("Edit Name") {
                        TextField("Edit Name", text: $label).labelsHidden()
                            .accessibilityIdentifier("source.edit.name")
                    }
                    LabeledContent("Edit Environment") {
                        TextField("Edit Environment", text: $environment).labelsHidden()
                            .accessibilityIdentifier("source.edit.environment")
                    }
                    mappingFields
                    if source.agent == .codex { ruleFields }
                }
                .padding(.trailing, 4)
            }
            .disabled(saving)
            if let validationMessage {
                Text(validationMessage).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Discard Edits") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("Save Source Settings") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("source.edit.save")
            }
        }
        .padding(22)
        .frame(width: 560, height: 440)
    }

    private var mappingFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Path Mappings").font(.headline)
            Text("Use absolute recorded prefixes and absolute or ~/ local prefixes.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($mappings) { $row in
                HStack {
                    TextField("Recorded Prefix", text: $row.value.from)
                    TextField("Local Prefix", text: $row.value.to)
                    Button {
                        let id = row.id
                        mappings.removeAll { $0.id == id }
                    } label: { Label("Remove Mapping", systemImage: "minus.circle") }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(Text("Remove Mapping"))
                }
            }
            Button("Add Mapping") { mappings.append(.init(value: .init(from: "", to: ""))) }
                .accessibilityIdentifier("source.edit.addMapping")
        }
    }

    private var ruleFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex Environment Rules").font(.headline)
            Text("The first matching rule supplies the environment label.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach($rules) { $row in
                HStack {
                    Picker("Record Field", selection: $row.value.field) {
                        if !SourceSettings.codexEnvironmentFields.contains(row.value.field) {
                            Text("Stored Field").tag(row.value.field)
                        }
                        Text("Model Provider").tag("model_provider")
                        Text("Originator").tag("originator")
                    }
                    .labelsHidden()
                    TextField("Exact Value", text: $row.value.equals)
                    TextField("Rule Environment", text: $row.value.environment)
                    Button {
                        let id = row.id
                        rules.removeAll { $0.id == id }
                    } label: { Label("Remove Rule", systemImage: "minus.circle") }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(Text("Remove Rule"))
                }
            }
            Button("Add Environment Rule") {
                rules.append(.init(value: .init(field: "model_provider", equals: "", environment: "")))
            }
            .accessibilityIdentifier("source.edit.addRule")
        }
    }

    private func save() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        validationMessage = nil
        var draft = SourceSettings(source)
        draft.label = label
        draft.environment = environment
        draft.pathMappings = mappings.map(\.value)
        if source.agent == .codex { draft.environmentRules = rules.map(\.value) }
        do {
            try await persist(draft)
            dismiss()
        } catch SourceSettingsCommitFailure.indexing {
            validationMessage = "Stop indexing before editing this source."
        } catch SourceSettingsEditFailure.staleEditor {
            validationMessage = "Source settings changed. Close and reopen the editor."
        } catch SourceSettingsValidation.invalidMapping(.ambiguousRules(_, _)) {
            validationMessage = "Two mappings use the same recorded prefix with different destinations."
        } catch SourceSettingsValidation.invalidMapping {
            validationMessage = "Check that every mapping uses a valid recorded and local prefix."
        } catch SourceSettingsValidation.invalidRule {
            validationMessage = "Every rule needs a supported field, an exact value, and an environment."
        } catch SourceSettingsValidation.conflictingRule {
            validationMessage = "Two rules assign different environments to the same value."
        } catch {
            validationMessage = "Could not save source settings."
        }
    }
}
