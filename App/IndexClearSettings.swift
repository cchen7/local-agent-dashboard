import ADStore
import SwiftUI

struct IndexClearSettingsSection: View {
    let model: DashboardModel
    @State private var mode = Mode.project
    @State private var selection: IndexClearScope?
    @State private var choices: [IndexClearChoice] = []
    @State private var preview: IndexClearPlan?
    @State private var planning = false
    @State private var message: LocalizedStringResource?
    @State private var succeeded = false

    private enum Mode: Hashable, CaseIterable {
        case project, source, everything
        var label: LocalizedStringResource {
            switch self {
            case .project: "Project"
            case .source: "Source"
            case .everything: "Everything"
            }
        }

        func includes(_ scope: IndexClearScope) -> Bool {
            switch (self, scope) {
            case (.project, .project), (.source, .source), (.everything, .everything): true
            default: false
            }
        }
    }

    var body: some View {
        Section("Clear local index") {
            Picker("Scope", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { value in Text(value.label).tag(value) }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) { selection = nil; message = nil }
            .accessibilityIdentifier("storage.clear.scope")
            if mode != .everything {
                Picker(mode.label, selection: $selection) {
                    Text("Choose an item").tag(nil as IndexClearScope?)
                    ForEach(choices.filter { mode.includes($0.id) }) { choice in
                        Text(verbatim: display(choice)).tag(Optional(choice.id))
                    }
                }
                .accessibilityIdentifier("storage.clear.selection")
            }
            Button("Review Clear…") { Task { await prepare() } }
                .accessibilityIdentifier("storage.clear.review")
                .disabled((mode != .everything && selection == nil) || !model.canClearIndex || planning)
            if model.sourceIndexing.progress.values.contains(where: \.active) {
                Text("Stop indexing before clearing data.").foregroundStyle(.secondary)
            }
            if planning || model.clearingIndex { ProgressView().controlSize(.small) }
            if let message {
                Text(message).foregroundStyle(succeeded ? Color.secondary : Color.red)
                    .accessibilityIdentifier("storage.clear.result")
            }
        }
        .task(id: model.store != nil) { await observeChoices() }
        .alert("Clear Local Index?", isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } }),
               presenting: preview) { confirmed in
            Button("Clear Indexed Data", role: .destructive) { Task { await apply(confirmed) } }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            let scope = plan.label.map(model.displayText) ?? String(localized: "Everything")
            let counts = String(localized: "Sessions to clear: \(plan.sessionCount). Files to recheck on the next scan: \(plan.fileCount).")
            let detail = String(localized: "Clears local transcripts and attributed usage. Original files, source access and settings are kept. Archived sessions may not be recoverable.")
            let retained = plan.retainedRecordCount > 0
                ? String(localized: "Retained usage entries to clear: \(plan.retainedRecordCount).") : nil
            Text(verbatim: [scope, counts, retained, detail].compactMap { $0 }.joined(separator: "\n\n"))
        }
    }

    private func display(_ choice: IndexClearChoice) -> String {
        let pieces = [choice.label, choice.location, choice.removedSource ? String(localized: "Removed source") : nil]
        return pieces.compactMap { $0 }.filter { !$0.isEmpty }.map(model.displayText).joined(separator: " · ")
    }

    private func observeChoices() async {
        guard let store = model.store else { return }
        do {
            for try await values in store.indexClearChoices(hostHome: model.projectPathHome) {
                guard !Task.isCancelled else { return }
                choices = values
                if let selection, !values.contains(where: { $0.id == selection }) { self.selection = nil }
            }
        } catch {
            if !Task.isCancelled { succeeded = false; message = "Could not read index scopes." }
        }
    }

    private func prepare() async {
        let scope = mode == .everything ? IndexClearScope.everything : selection
        guard let scope, !planning else { return }
        planning = true
        defer { planning = false }
        message = nil
        do { preview = try await model.planIndexClear(scope) }
        catch { report(error) }
    }

    private func apply(_ plan: IndexClearPlan) async {
        message = nil
        do {
            let result = try await model.applyIndexClear(plan)
            succeeded = true
            message = "Cleared \(result.removedSessions) sessions from the local index."
        } catch { report(error) }
    }

    private func report(_ error: any Error) {
        succeeded = false
        switch error as? IndexClearError {
        case .selectionChanged, .selectionMissing: message = "The selection changed. Review it again before clearing."
        case .indexingActive: message = "Stop indexing before clearing data."
        case nil: message = "Could not clear the local index."
        }
    }
}

struct ArchiveRetentionSettingsSection: View {
    let model: DashboardModel
    @State private var pending: ArchiveRetention?
    @State private var expired: Int?
    @State private var failed = false

    var body: some View {
        Section("Archive retention") {
            Picker("Keep archived sessions", selection: Binding(get: { model.archiveRetention }, set: { value in
                if value == .forever { apply(value) }
                else { pending = value }
            })) {
                ForEach(ArchiveRetention.allCases, id: \.self) { policy in Text(label(policy)).tag(policy) }
            }
            .accessibilityIdentifier("storage.archiveRetention")
            .disabled(!model.canClearIndex)
            Text("Age is measured from confirmed archival. Expiry removes transcripts from the index and keeps historical token and cost totals.")
                .foregroundStyle(.secondary)
            if let expired, expired > 0 { Text("Expired archived sessions: \(expired)").foregroundStyle(.secondary) }
            if failed || model.archiveMaintenanceFailed {
                Text("Archive retention could not be applied.").foregroundStyle(.red)
            }
        }
        .alert("Apply Archive Retention?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { policy in
            Button("Apply Archive Retention", role: .destructive) { apply(policy) }
            Button("Cancel", role: .cancel) {}
        } message: { policy in
            Text("Archived transcripts at least \(policy.rawValue) days old may be removed from this local index. Usage totals and original files are kept.")
        }
    }

    private func label(_ policy: ArchiveRetention) -> LocalizedStringResource {
        switch policy {
        case .forever: "Forever"
        case .oneYear, .halfYear, .quarterYear: "\(policy.rawValue) days"
        }
    }

    private func apply(_ policy: ArchiveRetention) {
        failed = false
        Task {
            do { expired = try await model.setArchiveRetention(policy) }
            catch { failed = true }
        }
    }
}

struct ToolOutputSettingsSection: View {
    let model: DashboardModel
    @State private var pending: ToolOutputArchiveLimit?
    @State private var failed = false

    var body: some View {
        Section("Tool output archive") {
            Picker("Compressed limit per output", selection: Binding(get: { model.toolOutputLimit }, set: { limit in
                if limit.rawValue < model.toolOutputLimit.rawValue { pending = limit }
                else { apply(limit) }
            })) {
                ForEach(ToolOutputArchiveLimit.allCases, id: \.self) { limit in Text(label(limit)).tag(limit) }
            }
            .accessibilityIdentifier("storage.toolOutputLimit")
            .disabled(!model.canClearIndex)
            Text("Search uses a short preview. Larger output can be read from the original when available.")
                .foregroundStyle(.secondary)
            if failed { Text("Could not save the tool output limit.").foregroundStyle(.red) }
        }
        .alert("Reduce Tool Output Archive?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
               presenting: pending) { limit in
            Button("Apply Tool Output Limit", role: .destructive) { apply(limit) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Local archives larger than the new limit will be removed. Search previews and original files stay unchanged.")
        }
    }

    private func label(_ limit: ToolOutputArchiveLimit) -> LocalizedStringResource {
        if limit == .previewOnly { return "Searchable preview only" }
        return "\(limit.rawValue / 1024) KiB"
    }

    private func apply(_ limit: ToolOutputArchiveLimit) {
        Task { failed = !(await model.setToolOutputLimit(limit)) }
    }
}
