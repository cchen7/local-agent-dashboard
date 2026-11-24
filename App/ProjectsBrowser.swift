import ADCore
import ADInsights
import ADPricing
import ADPrivacy
import ADStore
import AppKit
import Foundation
import SwiftUI

struct ProjectsBrowser<Sidebar: View>: View {
    let store: AgentStore?
    let hostHome: String?
    let currency: PriceDisplayCurrency
    @Binding var selection: IndexedProject.ID?
    let openSession: (SessionKey) -> Void
    let searchTopic: (String) -> Void
    @ViewBuilder let sidebar: () -> Sidebar
    @Environment(\.secretMaskingEnabled) private var maskSecrets
    @State private var projects: [DisplayProject] = []
    @State private var loaded = false
    @State private var failed = false
    @State private var period = UsagePeriod.day
    @State private var customStart = Date().addingTimeInterval(-3600)
    @State private var customEnd = Date()
    @State private var tab = ProjectDetail.Tab.activity
    @State private var usageInput: ProjectUsageInput?
    @State private var usageChart: ProjectUsageDisplayChart?
    @State private var chartProject: IndexedProject.ID?
    @State private var pinError = false

    private var input: ProjectUsageInput {
        let custom = period == .custom ? try? UsageRange(
            lowerBound: Int64(customStart.timeIntervalSince1970 * 1000),
            upperBound: Int64(customEnd.timeIntervalSince1970 * 1000)) : nil
        return .init(ready: store != nil, period: period, custom: custom,
                     chartFor: tab == .usage ? selection : nil)
    }

    var body: some View {
        let request = input
        NavigationSplitView {
            sidebar()
        } content: {
            VStack(spacing: 0) {
                usageControls
                Divider()
                projectList
            }
                .navigationSplitViewColumnWidth(min: 300, ideal: 356, max: 420)
                .navigationTitle("Projects")
        } detail: {
            if let project = projects.first(where: { $0.id == selection }), let store {
                ProjectDetail(project: project, store: store, currency: currency, period: request.period,
                              totals: visibleTotals(project, request: request),
                              chart: usageInput == request && chartProject == project.id ? usageChart : nil,
                              invalidRange: request.period == .custom && request.custom == nil,
                              hostHome: hostHome, tab: $tab, togglePin: { togglePin(project) }, openSession: openSession,
                              searchTopic: searchTopic)
                    .id(project.id)
            } else {
                EmptyPanel(title: "Select a project", symbol: "folder",
                           message: "Choose an indexed project to see its sessions and latest updates.")
            }
        }
        .task(id: request) { await observeProjects(request) }
        .alert("Could not update the project pin.", isPresented: $pinError) {}
    }

    private func togglePin(_ project: DisplayProject) {
        guard let store else { return }
        let target = project.pinTarget
        let hostHome = hostHome
        let pinned = !project.pinned
        Task {
            do {
                try await Task.detached { try store.setProjectPinned(target, pinned: pinned, hostHome: hostHome) }.value
            } catch { pinError = true }
        }
    }

    private var usageControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Usage Period", selection: $period) {
                ForEach(UsagePeriod.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("projects.usage.period")
            if period == .custom {
                DatePicker("From", selection: $customStart)
                DatePicker("To", selection: $customEnd)
                if input.custom == nil {
                    Text("Check the custom time range.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func visibleTotals(_ project: DisplayProject, request: ProjectUsageInput) -> UsageTotals? {
        guard usageInput?.period == request.period, usageInput?.custom == request.custom else { return nil }
        return project.totals
    }

    @ViewBuilder private var projectList: some View {
        if failed {
            EmptyPanel(title: "Could not read projects", symbol: "exclamationmark.triangle",
                       message: "Open the window again to retry.")
        } else if !loaded && store != nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if projects.isEmpty {
            EmptyPanel(title: "No projects yet", symbol: "folder",
                       message: "Projects appear when sessions with a working directory are indexed.")
                .accessibilityIdentifier("empty.projects")
        } else {
            List(selection: $selection) {
                ForEach(projects) { project in
                    ProjectCell(project: project, totals: visibleTotals(project, request: input), currency: currency)
                        .tag(project.id)
                        .contextMenu {
                            Button { togglePin(project) } label: {
                                if project.pinned { Text("Unpin Project") } else { Text("Pin Project") }
                            }
                        }
                }
            }
            .accessibilityIdentifier("projects.list")
        }
    }

    private func observeProjects(_ request: ProjectUsageInput) async {
        guard let store else { return }
        let masking = maskSecrets
        do {
            for try await snapshot in store.indexedProjectUsageUpdates(
                hostHome: hostHome, period: request.period, custom: request.custom,
                timeZone: .current, chartFor: request.chartFor
            ) {
                let read = await Task.detached {
                    let projects = snapshot.projects.map { project in
                        DisplayProject(project, totals: snapshot.window == nil ? nil : snapshot.totals[project.id] ?? .empty,
                                       maskSecrets: masking)
                    }
                    let chart = snapshot.chart.map {
                        ProjectUsageDisplayChart(data: $0, plot: UsagePlot(chart: $0, period: request.period, metric: .tokens))
                    }
                    return (projects, chart)
                }.value
                guard !Task.isCancelled, input == request else { return }
                usageInput = request
                chartProject = snapshot.chartProject
                usageChart = read.1
                projects = read.0
                if !projects.contains(where: { $0.id == selection }) { selection = projects.first?.id }
                loaded = true
                failed = false
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct ProjectUsageDisplayChart: Sendable {
    let data: UsageChartSnapshot
    let plot: UsagePlot
}

private struct ProjectUsageInput: Equatable, Sendable {
    let ready: Bool
    let period: UsagePeriod
    let custom: UsageRange?
    let chartFor: IndexedProject.ID?
}

private struct ProjectCell: View {
    let project: DisplayProject
    let totals: UsageTotals?
    let currency: PriceDisplayCurrency

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if let agent = project.agents.first { SessionAgentMark(agent: agent) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: project.name).font(.body.weight(.semibold)).lineLimit(1)
                    if project.pinned {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary)
                            .accessibilityLabel(Text("Pinned Project"))
                    }
                    Spacer(minLength: 0)
                    if let date = project.lastActivity {
                        Text(sessionDate(date), style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let path = project.path {
                    Text(verbatim: path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let location = project.location {
                    Text(verbatim: location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let latest = project.sessions.first { SessionTitle(title: latest.session.title).font(.subheadline) }
                HStack(spacing: 8) {
                    Text("Sessions: \(project.sessions.count)")
                    Text("Agents: \(project.agents.count)")
                }
                .font(.caption).foregroundStyle(.secondary)
                if project.retainedOnly {
                    Text("Retained Usage").font(.caption).foregroundStyle(.secondary)
                }
                if let totals { ProjectUsageSummary(totals: totals, currency: currency).font(.caption) }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ProjectDetail: View {
    enum Tab: Hashable { case sessions, activity, usage }

    let project: DisplayProject
    let store: AgentStore
    let currency: PriceDisplayCurrency
    let period: UsagePeriod
    let totals: UsageTotals?
    let chart: ProjectUsageDisplayChart?
    let invalidRange: Bool
    let hostHome: String?
    @Binding var tab: Tab
    let togglePin: () -> Void
    let openSession: (SessionKey) -> Void
    let searchTopic: (String) -> Void
    @State private var topics: [String] = []
    @State private var agent: AgentKind?
    @State private var status: SessionStatus?
    @State private var finderTask: Task<Void, Never>?
    @State private var finderFeedback: LocalizedStringResource?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("Project Details", selection: $tab) {
                Text("Sessions").tag(Tab.sessions)
                Text("Latest Updates").tag(Tab.activity)
                Text("Usage").tag(Tab.usage)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .accessibilityIdentifier("projects.tabs")

            switch tab {
            case .sessions: sessions
            case .activity: ProjectTimeline(store: store, scope: project.activityScope, openSession: openSession)
            case .usage: projectChart
            }
            if let latest = project.sessions.first {
                Divider()
                VStack(alignment: .trailing, spacing: 4) {
                    if let finderFeedback {
                        Text(finderFeedback).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("projects.finder.feedback")
                    }
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Show in Finder") { showInFinder() }
                            .disabled(!project.canRevealDirectory || finderTask != nil)
                            .accessibilityIdentifier("projects.finder")
                        Button("Open Latest Session") { openSession(latest.id) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 9)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.detail")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: project.pinTarget) { await observeTopics() }
        .onDisappear {
            finderTask?.cancel()
            finderTask = nil
            finderFeedback = nil
        }
    }

    private func observeTopics() async {
        topics = []
        do {
            for try await update in store.indexedProjectTopicUpdates(project.pinTarget, hostHome: hostHome) {
                guard !Task.isCancelled else { return }
                topics = update
            }
        } catch {
            if !Task.isCancelled { topics = [] }
        }
    }

    private func showInFinder() {
        guard finderTask == nil else { return }
        finderFeedback = nil
        let store = store
        let pin = project.pinTarget
        let home = hostHome
        finderTask = Task {
            defer { if !Task.isCancelled { finderTask = nil } }
            do {
                let target = try await Task.detached {
                    guard let candidate = try store.projectDirectoryTarget(pin, hostHome: home) else {
                        throw IndexedProjectFailure.selectionChanged
                    }
                    return candidate
                }.value
                try Task.checkCancellation()
                try ProjectDirectory.withVerifiedLocalDirectory(target.path) { url in
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                finderFeedback = "Finder request sent"
            } catch {
                if !Task.isCancelled { finderFeedback = "The local project folder is unavailable." }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(verbatim: project.name).font(.title3.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: togglePin) {
                    if project.pinned { Label("Unpin Project", systemImage: "pin.fill") }
                    else { Label("Pin Project", systemImage: "pin") }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("projects.pin")
                .help(project.pinned ? Text("Unpin Project") : Text("Pin Project"))
            }
            if let path = project.path {
                Text(verbatim: path).font(.subheadline).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let location = project.location {
                Text(verbatim: location).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let repository = project.repository {
                Text(verbatim: repository).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            if !project.branches.isEmpty {
                Label {
                    Text(verbatim: project.branches.joined(separator: " · ")).lineLimit(1)
                } icon: { Image(systemName: "arrow.triangle.branch") }
                .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("Sessions: \(project.sessions.count)")
                HStack(spacing: 4) {
                    ForEach(project.agents, id: \.self) { SessionAgentMark(agent: $0) }
                }
                Spacer(minLength: 0)
                if let date = project.lastActivity {
                    Text(sessionDate(date), style: .relative).lineLimit(1)
                        .accessibilityLabel(Text("Last Activity"))
                }
            }
            .font(.caption).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
            if let totals {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tokens · Cost").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    ProjectUsageSummary(totals: totals, currency: currency).font(.caption)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("projects.usage.summary")
            }
            if !topics.isEmpty {
                MainTopicChips(terms: topics, compact: true, identifier: "projects.topics", search: searchTopic)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    @ViewBuilder private var projectChart: some View {
        if invalidRange {
            EmptyPanel(title: "Check the custom time range.", symbol: "calendar",
                       message: "Choose a start before the end time.")
        } else if let chart {
            if chart.data.points.isEmpty {
                EmptyPanel(title: "No dated usage in this period", symbol: "chart.xyaxis.line",
                           message: "Usage without timestamps is included in All totals.")
                    .accessibilityIdentifier("projects.usage.chart.empty")
            } else {
                let nav = UsageNavigationRequest(period: period, metric: .tokens, grouping: .agent, filter: .init(),
                    customStart: sessionDate(chart.data.window.range.lowerBound),
                    customEnd: sessionDate(chart.data.window.range.upperBound), revision: 0)
                ScrollView {
                    UsageChart(data: chart.data, plot: chart.plot,
                               request: nav, currency: currency, redlines: [:])
                        .frame(height: DashboardLayoutRules.minimumPlotHeight + 65)
                        .padding(12)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("projects.usage.chart")
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Agent", selection: $agent) {
                    Text("All Agents").tag(nil as AgentKind?)
                    ForEach(project.agents, id: \.self) { value in
                        Text(verbatim: value.sessionName).tag(Optional(value))
                    }
                }
                Picker("Status", selection: $status) {
                    Text("All Statuses").tag(nil as SessionStatus?)
                    ForEach([SessionStatus.running, .waiting, .completed, .failed, .unknown], id: \.self) { value in
                        Text(value.label).tag(Optional(value))
                    }
                }
            }
            .labelsHidden()
            .padding(.horizontal, 18).padding(.vertical, 6)

            let filtered = project.sessions.filter {
                (agent == nil || $0.id.agent == agent) && (status == nil || $0.session.status == status)
            }
            if filtered.isEmpty {
                EmptyPanel(title: "No matching sessions", symbol: "line.3.horizontal.decrease",
                           message: "Change the agent or status filter.")
            } else {
                List(filtered) { item in
                    Button { openSession(item.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            SessionListCell(session: item.session, currency: currency)
                            if let worktree = item.worktree {
                                Text("Worktree: \(worktree)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .accessibilityIdentifier("projects.sessions")
            }
        }
    }
}

private struct ProjectTimeline: View {
    let store: AgentStore
    let scope: IndexedProjectActivityScope
    let openSession: (SessionKey) -> Void
    @Environment(\.secretMaskingEnabled) private var maskSecrets
    @State private var entries: [DisplayProjectActivity] = []
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                EmptyPanel(title: "Could not read project updates", symbol: "exclamationmark.triangle",
                           message: "Open the project again to retry.")
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                EmptyPanel(title: "No project updates yet", symbol: "clock",
                           message: "Recent indexed messages and tool actions will appear here.")
            } else {
                List(entries) { entry in
                    Button { openSession(entry.session) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            SessionAgentMark(agent: entry.session.agent)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(alignment: .firstTextBaseline) {
                                    SessionTitle(title: entry.title).font(.caption.weight(.medium))
                                    Spacer(minLength: 5)
                                    Text(sessionDate(entry.timestamp), style: .relative)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ProjectTimelineDetail(entry: entry)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(entry.accessibilityID)
                }
                .accessibilityIdentifier("projects.timeline")
            }
        }
        .task(id: scope) { [scope] in await observe(scope) }
    }

    private func observe(_ requested: IndexedProjectActivityScope) async {
        loaded = false
        failed = false
        entries = []
        let masking = maskSecrets
        do {
            for try await rows in try store.indexedProjectActivityUpdates(requested) {
                let display = await Task.detached { rows.map { DisplayProjectActivity($0, maskSecrets: masking) } }.value
                guard !Task.isCancelled else { return }
                entries = display
                loaded = true
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct ProjectUsageSummary: View {
    let totals: UsageTotals
    let currency: PriceDisplayCurrency

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(totals.counts.total.formatted()) tokens").monospacedDigit()
            if totals.records > 0 {
                if totals.hasPricedUsage {
                    let amount = currency.formattedMicroUSD(Decimal(totals.costMicroUSD))
                    if totals.unpricedTokens > 0 {
                        Text("Partial estimate: \(amount)")
                    } else {
                        Text("List-price estimate: \(amount)")
                    }
                } else { Text("Unpriced") }
            }
        }
        .foregroundStyle(.secondary)
    }
}

private struct DisplayProject: Identifiable, Sendable {
    struct Member: Identifiable, Sendable {
        var id: SessionKey { session.id }
        let session: SessionListItem
        let worktree: String?
    }

    let id: IndexedProject.ID
    let name: String
    let path: String?
    let location: String?
    let repository: String?
    let agents: [AgentKind]
    let branches: [String]
    let sessions: [Member]
    let activityScope: IndexedProjectActivityScope
    let totals: UsageTotals?
    let retainedOnly: Bool
    let pinTarget: IndexedProjectPinTarget
    let pinned: Bool
    let canRevealDirectory: Bool
    var lastActivity: Int64? { sessions.first?.session.lastActivity }

    nonisolated init(_ project: IndexedProject, totals: UsageTotals?, maskSecrets: Bool) {
        func display(_ text: String) -> String { maskSecrets ? SecretMasker.mask(text) : text }
        id = project.id
        name = display(project.name)
        path = project.path.map(display)
        location = project.location.map(display)
        repository = project.repositoryURL.flatMap(Self.displayRepository)
        agents = project.agents
        branches = project.branches.map(display)
        sessions = project.sessions.map {
            .init(session: SessionListItem($0.session, maskSecrets: maskSecrets), worktree: $0.worktree.map(display))
        }
        activityScope = project.activityScope
        self.totals = totals
        retainedOnly = project.retainedOnly
        pinTarget = project.pinTarget
        pinned = project.pinned
        canRevealDirectory = project.canRevealDirectory
    }

    nonisolated private static func displayRepository(_ raw: String) -> String? {
        // Plain text only. Never display credentials or transport query parameters.
        guard var url = URLComponents(string: raw), let scheme = url.scheme?.lowercased(),
              ["https", "http", "ssh", "git"].contains(scheme), url.host != nil else { return nil }
        url.user = nil
        url.password = nil
        url.query = nil
        url.fragment = nil
        return url.string.map(SecretMasker.mask)
    }
}

private struct ProjectTimelineDetail: View {
    let entry: DisplayProjectActivity

    var body: some View {
        if let command = entry.command {
            VStack(alignment: .leading, spacing: 3) {
                Text("Command").font(.caption).foregroundStyle(.secondary)
                if let text = command.text {
                    Text(verbatim: text).font(.callout.monospaced()).lineLimit(2)
                }
                ToolActionMetrics(row: command).font(.caption).monospacedDigit()
            }
        } else if !entry.files.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Touched Files").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(entry.files.enumerated()), id: \.offset) { _, file in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if let name = file.detail, let op = ToolFileAction.Operation(rawValue: name) {
                                Text(label(for: op)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let path = file.text {
                                Text(verbatim: path).font(.callout).lineLimit(1).truncationMode(.middle)
                            }
                        }
                        ToolActionMetrics(row: file).font(.caption).monospacedDigit()
                    }
                }
                if entry.additionalFiles > 0 {
                    Text("\(entry.additionalFiles) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            if let tool = entry.toolName {
                Text(verbatim: tool).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(entry.kind.transcriptLabel).font(.caption).foregroundStyle(.secondary)
            }
            if let text = entry.text { Text(verbatim: text).font(.callout).lineLimit(2) }
        }
    }

    private func label(for operation: ToolFileAction.Operation) -> LocalizedStringResource {
        switch operation {
        case .read: "Read"
        case .edit: "Edit"
        case .write: "Write"
        case .delete: "Delete"
        }
    }
}

private struct DisplayProjectActivity: Identifiable, Sendable {
    let id: String
    let session: SessionKey
    let timestamp: Int64
    let kind: EventKind
    let title: String?
    let toolName: String?
    let text: String?
    let command: SessionOverviewDisplay.Row?
    let files: [SessionOverviewDisplay.Row]
    let additionalFiles: Int

    var accessibilityID: String {
        if command != nil { return "projects.timeline.command" }
        if !files.isEmpty { return "projects.timeline.files" }
        return "projects.timeline.event"
    }

    nonisolated init(_ event: IndexedProjectActivity, maskSecrets: Bool) {
        func display(_ text: String) -> String { maskSecrets ? SecretMasker.mask(text) : text }
        id = event.id
        session = event.session
        timestamp = event.timestamp
        kind = event.kind
        title = displayedSessionTitle(event.sessionTitle, maskSecrets: maskSecrets)
        toolName = event.toolName.map(display)
        switch event.action {
        case .command(let value):
            command = SessionOverviewDisplay.command(value, maskSecrets: maskSecrets)
            files = []
            additionalFiles = 0
        case .files(let values, let total):
            command = nil
            files = values.map { SessionOverviewDisplay.file($0, maskSecrets: maskSecrets) }
            additionalFiles = max(0, total - values.count)
        case nil:
            command = nil
            files = []
            additionalFiles = 0
        }
        // Mask the complete value before shortening it for the timeline.
        text = event.text.flatMap {
            let masked = display($0).trimmingCharacters(in: .whitespacesAndNewlines)
            return masked.isEmpty ? nil : String(masked.prefix(200))
        }
    }
}
