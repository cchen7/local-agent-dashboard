import SwiftUI
import ADStore
import ADCore
import ADIngest
import ADInsights
import ADPrivacy

enum SettingsPage: Hashable { case general, sources, thresholds, storage, pricing, about }

struct SettingsView: View {
    @State private var indexStatus: [Int64: IndexedSourceStatus] = [:]
    @State private var indexStatusUnavailable = false
    @State private var editingSource: Source?
    @State private var removingSource: Source?
    @State private var removalFailed = false
    @Bindable var model: DashboardModel
    @State private var showsAddSource = false

    var body: some View {
        TabView(selection: $model.settingsPage) {
            Form {
                Text("Zero network. Read-only sources. Everything stays on this Mac.")
                    .accessibilityIdentifier("settingsPrivacyPromise")
                Text("Start indexing in Settings → Sources.").foregroundStyle(.secondary)
                LaunchAtLoginControls()
            }
            .padding()
            .tabItem { Label("General", systemImage: "gearshape") }
            .tag(SettingsPage.general)

            VStack(alignment: .leading, spacing: 16) {
                Text("Sources").font(.title2)
                Text("Choose a source to index. Its files stay read-only and the index stays on this Mac.")
                    .foregroundStyle(.secondary)
                List(model.sources) { source in
                    let indexing = source.id.flatMap { model.sourceIndexing.progress[$0] }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: SecretMasker.mask(source.label)).font(.headline)
                            Text(verbatim: SecretMasker.mask(source.rootURL.path)).font(.caption)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Text(verbatim: sourceAgentName(source.agent) + " · " + SecretMasker.mask(source.environment))
                                .font(.caption).foregroundStyle(.secondary)
                            status(model.access[source.id ?? -1] ?? .notChecked)
                            if let indexing { indexingStatus(indexing) }
                            if let health = source.id.flatMap({ indexStatus[$0] }) {
                                SourceIndexStatusRows(status: health)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            if SourceIndexingController.supports(source.agent), let id = source.id {
                                if indexing?.active == true {
                                    Button("Stop Indexing") { model.sourceIndexing.stop(id: id) }
                                        .disabled(indexing == .stopping)
                                        .accessibilityIdentifier("source.stopIndexing")
                                } else {
                                    Button("Start Indexing") { model.startIndexing(source) }
                                        .disabled(model.onboardingRequired || !source.enabled || model.editingSourceIDs.contains(id))
                                        .accessibilityIdentifier("source.startIndexing")
                                }
                            }
                            if SourceIndexingController.supports(source.agent) {
                                Button("Rescan Source") { model.rescanSource(source) }
                                    .disabled(!model.canRescan(source))
                                    .accessibilityIdentifier("source.rescan")
                            }
                            Button("Edit Source Settings") { editingSource = source }
                                .accessibilityIdentifier("source.edit")
                                .disabled(source.id == nil || indexing?.active == true ||
                                          source.id.map(model.editingSourceIDs.contains) == true)
                            Button("Grant access again") { Task { await model.grantAccess(to: source) } }
                                .disabled(indexing?.active == true || source.id.map(model.editingSourceIDs.contains) == true)
                            Button("Remove Source") { removingSource = source }
                                .accessibilityIdentifier("source.remove")
                                .disabled(model.verifying || model.onboardingRequired ||
                                          source.id.map(model.editingSourceIDs.contains) != false)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .sheet(item: $editingSource) { source in
                    SourceSettingsEditor(source: source) { replacement in
                        try await model.saveSourceSettings(source, replacement: replacement)
                    }
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
                if removalFailed { Text("Could not remove the source.").foregroundStyle(.red) }
                if indexStatusUnavailable { Text("Could not read index status.").foregroundStyle(.red) }
                if model.storageFailed { Text("Storage could not be opened. Quit and try again.").foregroundStyle(.red) }
            }
            .task(id: model.store != nil) { await observeIndexStatus() }
            .padding()
            .sheet(isPresented: $showsAddSource) { AddSourceSheet(model: model) }
            .confirmationDialog("Remove this source?", isPresented: Binding(get: { removingSource != nil },
                                                                               set: { if !$0 { removingSource = nil } }),
                                titleVisibility: .visible, presenting: removingSource) { source in
                Button("Remove Source", role: .destructive) {
                    removalFailed = false
                    Task {
                        do { try await model.removeSource(source) }
                        catch { removalFailed = true }
                    }
                }
            } message: { _ in
                Text("Indexing stops and saved folder access is forgotten. Previously indexed sessions and the original files are kept.")
            }
            .tabItem { Label("Sources", systemImage: "folder") }
            .tag(SettingsPage.sources)

            StatusThresholdSettingsPane(model: model)
                .tabItem { Label("Thresholds", systemImage: "slider.horizontal.3") }
                .tag(SettingsPage.thresholds)

            StorageSettingsPane(model: model)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
                .tag(SettingsPage.storage)

            PricingSettingsPane(model: model.pricing, store: model.store)
                .tabItem { Label("Pricing", systemImage: "tag") }
                .tag(SettingsPage.pricing)

            VStack(spacing: 12) {
                Text("Agent Dashboard").font(.title)
                Text("Fully local. No network permission.")
            }
            .tabItem { Label("About", systemImage: "info.circle") }
            .tag(SettingsPage.about)
        }
        .frame(width: 680, height: 480)
    }

    @ViewBuilder private func indexingStatus(_ value: SourceIndexPresentation) -> some View {
        switch value {
        case .starting:
            Text("Finding session files…").foregroundStyle(.secondary)
        case .scanning(let scan):
            ProgressView(value: Double(scan.checkedFiles), total: Double(max(1, scan.totalFiles)))
            scanSummary(scan)
        case .watching(let scan):
            Label("Watching for changes", systemImage: "checkmark.circle")
                .foregroundStyle(.green).accessibilityIdentifier("source.watching")
            scanSummary(scan)
        case .rescanned(let scan):
            Text("Source scan finished").foregroundStyle(.secondary)
                .accessibilityIdentifier("source.rescanned")
            scanSummary(scan)
        case .stopping:
            Text("Stopping indexing…").foregroundStyle(.secondary)
        case .stopped:
            Text("Indexing stopped").foregroundStyle(.secondary).accessibilityIdentifier("source.stopped")
        case .failed(let failure):
            Text(indexingError(failure)).foregroundStyle(.red)
        }
    }

    private func scanSummary(_ scan: SourceIndexScan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Files checked: \(scan.checkedFiles) of \(scan.totalFiles)")
            if scan.failedFiles != 0 { Text("Files not read: \(scan.failedFiles)").foregroundStyle(.orange) }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func indexingError(_ failure: IndexAccessFailure) -> LocalizedStringResource {
        switch failure {
        case .denied: "Access denied. Grant access again."
        case .staleBookmark: "Bookmark is stale. Grant access again."
        case .rootChanged: "The source directory changed. Check its location before restarting."
        case .unavailable: "Could not index this source. Verify access and try again."
        }
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
        case .wrongDirectory: Text("Could not verify the original source folder. Access was left unchanged.").foregroundStyle(.red)
        case .pathConflict: Text("This path is registered to a different source.").foregroundStyle(.red)
        }
    }
}

private struct StatusThresholdSettingsPane: View {
    let model: DashboardModel
    @State private var approval = ""
    @State private var activity = ""
    @State private var tool = ""
    @State private var completion = ""
    @State private var feedback: Feedback?

    private enum Feedback { case saved, failed }

    private var values: [Int]? {
        let fields = [approval, activity, tool, completion].compactMap {
            Int($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (try? DashboardModel.statusThresholds(seconds: fields)) != nil ? fields : nil
    }

    var body: some View {
        Form {
            UsageRedlineSettingsSection(store: model.store)
            ContextWindowSettingsSection(model: model)
            Section("Session Status") {
                Text("Enter whole seconds. Changes also apply to sessions already in the index.")
                    .font(.callout).foregroundStyle(.secondary)
                field("Silence before possible approval", value: $approval, id: "approval")
                field("Recent activity", value: $activity, id: "activity")
                field("Unanswered tool lifetime", value: $tool, id: "tool")
                field("Idle time before marking a finished turn completed", value: $completion, id: "completion")
                if values == nil {
                    Text("Use 1 to 604,800 seconds. Approval silence must be shorter than recent activity and tool lifetime. Completion must be at least as long as recent activity.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Use Default Thresholds") {
                        populate(.default)
                        feedback = nil
                    }
                    Spacer()
                    Button("Save Thresholds") { save() }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("status.thresholds.save")
                        .disabled(values == nil || !model.canEditStatusThresholds || model.savingStatusThresholds)
                }
                .disabled(model.savingStatusThresholds)
                if model.savingStatusThresholds { ProgressView() }
                if feedback == .saved {
                    Text("Thresholds saved.").accessibilityIdentifier("status.thresholds.saved")
                } else if feedback == .failed {
                    Text("Could not save thresholds.").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { populate(model.statusThresholds) }
        .onChange(of: model.statusThresholds) { _, value in populate(value) }
    }

    private func field(_ label: LocalizedStringResource, value: Binding<String>, id: String) -> some View {
        LabeledContent {
            TextField("", text: value)
                .labelsHidden().monospacedDigit().multilineTextAlignment(.trailing)
                .frame(width: 84)
                .accessibilityLabel(Text(label))
                .accessibilityIdentifier("status.thresholds.\(id)")
                .disabled(model.savingStatusThresholds)
        } label: { Text(label) }
    }

    private func populate(_ value: StatusInferenceThresholds) {
        approval = String(value.approvalSilenceMilliseconds / 1_000)
        activity = String(value.recentActivityMilliseconds / 1_000)
        tool = String(value.pendingToolLifetimeMilliseconds / 1_000)
        completion = String(value.turnCompletionSilenceMilliseconds / 1_000)
    }

    private func save() {
        guard let values else { return }
        feedback = nil
        Task {
            do {
                try await model.saveStatusThresholds(values)
                feedback = .saved
            } catch { feedback = .failed }
        }
    }
}

private struct ContextWindowSettingsSection: View {
    struct DraftRule: Identifiable, Equatable {
        let id = UUID()
        var prefix = ""
        var tokens = ""
    }

    let model: DashboardModel
    @State private var draft: [DraftRule] = []
    @State private var saveFailed = false
    @State private var saved = false

    private var rules: [ModelContextWindow]? {
        let values = draft.compactMap { row -> ModelContextWindow? in
            guard let tokens = Int64(row.tokens.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
            return .init(prefix: row.prefix.trimmingCharacters(in: .whitespacesAndNewlines), tokens: tokens)
        }
        return values.count == draft.count && ModelContextWindow.areValid(values) ? values : nil
    }

    var body: some View {
        Section("Model Context Windows") {
            Text("Capacity is used only when the session log does not provide it. The longest matching model prefix wins.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach($draft) { $row in
                HStack(spacing: 10) {
                    TextField("Model prefix", text: $row.prefix)
                        .accessibilityIdentifier("context.rule.prefix")
                    TextField("Capacity in tokens", text: $row.tokens)
                        .frame(width: 148)
                        .accessibilityIdentifier("context.rule.capacity")
                    Button {
                        let id = row.id
                        draft.removeAll { $0.id == id }
                    } label: { Label("Remove Model Rule", systemImage: "minus.circle").labelStyle(.iconOnly) }
                    .help("Remove Model Rule")
                }
            }
            if rules == nil {
                Text("Use unique model prefixes and positive whole token counts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Add Model Rule") { draft.append(.init()) }
                    .disabled(draft.count >= ModelContextWindow.maximumRules)
                    .accessibilityIdentifier("context.rule.add")
                Spacer()
                Button("Save Model Context Windows") { save() }
                    .disabled(rules == nil || model.store == nil)
                    .accessibilityIdentifier("context.rule.save")
            }
            if saved { Text("Model context windows saved.").accessibilityIdentifier("context.rule.saved") }
            if saveFailed { Text("Could not save model context windows.").foregroundStyle(.red) }
        }
        .task(id: model.store != nil) {
            if model.store != nil {
                draft = model.contextWindowRules.map { .init(prefix: $0.prefix, tokens: String($0.tokens)) }
            }
        }
        .onChange(of: draft) { _, _ in
            saveFailed = false
            saved = false
        }
    }

    private func save() {
        guard let rules else { return }
        do {
            try model.saveContextWindowRules(rules)
            saved = true
            saveFailed = false
        } catch {
            saved = false
            saveFailed = true
        }
    }
}

private struct UsageRedlineSettingsSection: View {
    let store: AgentStore?
    @State private var draft: [AgentKind: String] = [:]
    @State private var loaded = false
    @State private var saving = false
    @State private var feedback: Feedback?

    private enum Feedback { case saved, loadFailed, saveFailed }

    static func parse(_ draft: [AgentKind: String]) -> [AgentKind: Int64]? {
        var limits: [AgentKind: Int64] = [:]
        for (agent, field) in draft {
            let text = field.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let value = Int64(text), value > 0 else { return nil }
            limits[agent] = value
        }
        return limits
    }

    var body: some View {
        Section("Throughput redlines") {
            Text("Enter tokens per minute for each agent. Leave a field blank to remove its redline.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(AgentKind.allCases, id: \.self) { agent in
                LabeledContent {
                    TextField("", text: Binding(get: { draft[agent] ?? "" }, set: {
                        draft[agent] = $0
                        feedback = nil
                    }))
                    .labelsHidden()
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 146)
                    .accessibilityLabel(Text(verbatim: agent.sessionName))
                    .accessibilityIdentifier("usage.redline.\(agent.rawValue)")
                    .disabled(!loaded || saving)
                } label: {
                    Text(verbatim: agent.sessionName)
                }
            }
            if Self.parse(draft) == nil {
                Text("Enter positive whole numbers for redlines.").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                if !loaded && feedback == .loadFailed {
                    Button("Try Again") { Task { await load() } }
                }
                Spacer()
                Button("Save Redlines") { Task { await save() } }
                    .disabled(!loaded || saving || Self.parse(draft) == nil)
                    .accessibilityIdentifier("usage.redline.save")
            }
            switch feedback {
            case .saved: Text("Redlines saved.").accessibilityIdentifier("usage.redline.saved")
            case .loadFailed: Text("Could not read redlines.").foregroundStyle(.red)
            case .saveFailed: Text("Could not save redlines.").foregroundStyle(.red)
            case nil: EmptyView()
            }
        }
        .task(id: store != nil) { await load() }
    }

    private func load() async {
        guard let store else { return }
        loaded = false
        do {
            let values = try await Task.detached { try store.usageRedlines() }.value
            guard !Task.isCancelled else { return }
            draft = values.mapValues(String.init)
            feedback = nil
            loaded = true
        } catch {
            if !Task.isCancelled { feedback = .loadFailed }
        }
    }

    private func save() async {
        guard let store, loaded, !saving, let values = Self.parse(draft) else { return }
        saving = true
        defer { saving = false }
        do {
            try await Task.detached { try store.setUsageRedlines(values) }.value
            draft = values.mapValues(String.init)
            feedback = .saved
        } catch { feedback = .saveFailed }
    }
}

private struct StorageSettingsPane: View {
    let model: DashboardModel
    private var store: AgentStore? { model.store }
    @State private var usageBytes: Int64?
    @State private var rebuilding = false
    @State private var outcome: Outcome?

    private enum Outcome {
        case rebuilt, unbacked, failed
    }

    var body: some View {
        Form {
            LabeledContent("Database Size") {
                Text(verbatim: usageBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                    .accessibilityIdentifier("indexStorageSize")
            }
            Section {
                Text("Rebuilds search, topics and usage from the local database without rereading source files.")
                    .foregroundStyle(.secondary)
                Button("Rebuild Index") { Task { await rebuild() } }
                    .disabled(store == nil || rebuilding)
                    .accessibilityIdentifier("rebuildLocalIndex")
                if rebuilding { ProgressView("Rebuilding index…") }
                switch outcome {
                case .rebuilt:
                    Text("Index rebuilt.").accessibilityIdentifier("indexRebuildSucceeded")
                case .unbacked:
                    Text("Some historical usage cannot be reconstructed. Nothing was changed.")
                        .foregroundStyle(.orange)
                case .failed:
                    Text("Could not rebuild the local index.").foregroundStyle(.red)
                case nil:
                    EmptyView()
                }
            }
            Section {
                Text("Rereads supported sources with existing access and keeps archived sessions.")
                    .foregroundStyle(.secondary)
                Button("Full Rescan") { model.rescanSources() }
                    .disabled(!model.canRescanSources)
                    .accessibilityIdentifier("rescanAllSources")
            }
        }
        .formStyle(.grouped)
        .task(id: store != nil) { await readSize() }
    }

    private func readSize() async {
        guard let store else { return }
        let size = await Task.detached { try? store.indexStorageBytes() }.value
        if !Task.isCancelled { usageBytes = size }
    }

    private func rebuild() async {
        guard let store, !rebuilding else { return }
        rebuilding = true
        defer { rebuilding = false }
        outcome = nil
        outcome = await Task.detached(priority: .utility) { () -> Outcome in
            do {
                _ = try LocalIndexMaintenance.rebuild(store)
                return .rebuilt
            } catch IndexRebuildError.unbackedUsage {
                return .unbacked
            } catch {
                return .failed
            }
        }.value
        await readSize()
    }
}

struct SourceOnboardingView: View {
    let model: DashboardModel
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.privacy
    @State private var addingSource = false
    @State private var saveFailed = false

    private enum Step: Int { case privacy = 1, sources, indexing }
    private struct PreviewKey: Equatable {
        let id: Int64?
        let access: AccessKind
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ProgressView(value: Double(step.rawValue), total: 3)
                .accessibilityLabel("Setup progress")
            switch step {
            case .privacy:
                Label("Your private, local dashboard", systemImage: "lock.shield").font(.title2)
                Text("Zero network. Read-only sources. Everything stays on this Mac.")
                Spacer()
                Button("Choose Sources") { step = .sources }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.chooseSources")
            case .sources:
                Text("Choose Sources").font(.title2)
                Text("Choose the local sources to index. File counts come from directory listings.")
                    .foregroundStyle(.secondary)
                List(model.sources) { source in
                    sourceRow(source)
                }
                .accessibilityIdentifier("onboarding.sources")
                .task(id: model.sources.map { PreviewKey(id: $0.id, access: $0.access) }) {
                    await model.previewOnboardingSources()
                }
                HStack {
                    Button("Back") { step = .privacy }
                    Button("Add Source") { addingSource = true }
                    Spacer()
                    Button("Continue Without Indexing") { finish(startSelected: false) }
                        .accessibilityIdentifier("onboarding.skipIndexing")
                    Button("Start Indexing") { finish(startSelected: true) }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("onboarding.startIndexing")
                        .disabled(model.onboardingChoice.isEmpty)
                }
                .sheet(isPresented: $addingSource) { AddSourceSheet(model: model) }
            case .indexing:
                Text("Your dashboard is ready").font(.title2)
                Text("Sessions appear as they are indexed. You can open the dashboard now.")
                    .foregroundStyle(.secondary)
                List(model.sources.filter { source in
                    guard let id = source.id else { return false }
                    return model.sourceIndexing.progress[id] != nil
                }) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: SecretMasker.mask(source.label))
                        if let id = source.id, let progress = model.sourceIndexing.progress[id] {
                            scanProgress(progress)
                        }
                    }
                }
                Button("Open Dashboard") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("onboarding.openDashboard")
            }
            if saveFailed { Text("Could not save source setup.").foregroundStyle(.red) }
        }
        .padding(24)
        .frame(width: 660, height: 520)
        .disabled(model.onboardingSaving)
        .interactiveDismissDisabled(model.onboardingRequired)
    }

    @ViewBuilder private func sourceRow(_ source: Source) -> some View {
        if let id = source.id {
            HStack {
                Toggle(isOn: Binding(get: { model.onboardingChoice.contains(id) }, set: {
                    model.setOnboardingSource(id, selected: $0)
                })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: SecretMasker.mask(source.label))
                        Text(verbatim: "\(SecretMasker.mask(source.environment)) · \(SecretMasker.mask(source.rootURL.path))")
                            .lineLimit(1).truncationMode(.middle)
                            .font(.caption).foregroundStyle(.secondary)
                        previewLabel(model.sourcePreviews[id])
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("onboarding.fileCount.\(id)")
                    }
                }
                .disabled(!canChoose(source, id: id))
                .accessibilityIdentifier("onboarding.source.\(id)")
                if model.sourcePreviews[id] == .unavailable {
                    Button("Grant access again") { Task { await model.grantAccess(to: source) } }
                }
            }
        }
    }

    @ViewBuilder private func previewLabel(_ reading: SourceFilePreview?) -> some View {
        switch reading {
        case .available(let count): Text("Discovered session files: \(count)")
        case .unsupported: Text("Indexing is not available for this agent.")
        case .unavailable: Text("Folder unavailable. Verify access to index it.")
        case nil: Text("Checking local folders…")
        }
    }

    @ViewBuilder private func scanProgress(_ progress: SourceIndexPresentation) -> some View {
        switch progress {
        case .starting: ProgressView("Finding session files…")
        case .scanning(let scan):
            ProgressView(value: Double(scan.checkedFiles), total: Double(max(1, scan.totalFiles))) {
                Text("Files checked: \(scan.checkedFiles) of \(scan.totalFiles)")
            }
        case .watching: Text("Watching for changes")
        case .rescanned: Text("Source scan finished")
        case .stopping: Text("Stopping indexing…")
        case .stopped: Text("Indexing stopped")
        case .failed: Text("Could not index this source. Verify access and try again.").foregroundStyle(.red)
        }
    }

    private func canChoose(_ source: Source, id: Int64) -> Bool {
        guard source.enabled, case .available(let count) = model.sourcePreviews[id] else { return false }
        return count > 0
    }

    private func finish(startSelected: Bool) {
        saveFailed = false
        Task {
            if await model.completeOnboarding(startSelected: startSelected) {
                if startSelected { step = .indexing }
                else { dismiss() }
            } else { saveFailed = true }
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
