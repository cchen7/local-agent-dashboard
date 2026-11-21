import ADCore
import ADPrivacy
import ADStore
import Foundation
import SwiftUI

struct ProjectsBrowser<Sidebar: View>: View {
    let store: AgentStore?
    let hostHome: String?
    @Binding var selection: IndexedProject.ID?
    let openSession: (SessionKey) -> Void
    @ViewBuilder let sidebar: () -> Sidebar
    @State private var projects: [DisplayProject] = []
    @State private var loaded = false
    @State private var failed = false

    var body: some View {
        NavigationSplitView {
            sidebar()
        } content: {
            projectList
                .navigationSplitViewColumnWidth(min: 300, ideal: 356, max: 420)
                .navigationTitle("Projects")
        } detail: {
            if let project = projects.first(where: { $0.id == selection }), let store {
                ProjectDetail(project: project, store: store, openSession: openSession)
                    .id(project.id)
            } else {
                EmptyPanel(title: "Select a project", symbol: "folder",
                           message: "Choose an indexed project to see its sessions and latest updates.")
            }
        }
        .task(id: store != nil) { await observeProjects() }
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
                    ProjectCell(project: project).tag(project.id)
                }
            }
            .accessibilityIdentifier("projects.list")
        }
    }

    private func observeProjects() async {
        guard let store else { return }
        do {
            for try await rows in store.indexedProjectUpdates(hostHome: hostHome) {
                let display = await Task.detached { rows.map(DisplayProject.init) }.value
                guard !Task.isCancelled else { return }
                projects = display
                if !display.contains(where: { $0.id == selection }) { selection = display.first?.id }
                loaded = true
                failed = false
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct ProjectCell: View {
    let project: DisplayProject

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if let agent = project.agents.first { SessionAgentMark(agent: agent) }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(verbatim: project.name).font(.body.weight(.semibold)).lineLimit(1)
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
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ProjectDetail: View {
    enum Tab: Hashable { case sessions, activity }

    let project: DisplayProject
    let store: AgentStore
    let openSession: (SessionKey) -> Void
    @State private var tab = Tab.activity
    @State private var agent: AgentKind?
    @State private var status: SessionStatus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("Project Details", selection: $tab) {
                Text("Sessions").tag(Tab.sessions)
                Text("Latest Updates").tag(Tab.activity)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .accessibilityIdentifier("projects.tabs")

            switch tab {
            case .sessions: sessions
            case .activity: ProjectTimeline(store: store, scope: project.activityScope, openSession: openSession)
            }
            if let latest = project.sessions.first {
                Divider()
                HStack {
                    Spacer()
                    Button("Open Latest Session") { openSession(latest.id) }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal, 18).padding(.vertical, 9)
            }
        }
        .accessibilityIdentifier("projects.detail")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: project.name).font(.title3.weight(.semibold)).lineLimit(1)
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
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
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
                            SessionListCell(session: item.session)
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
                                if let tool = entry.toolName {
                                    Text(verbatim: tool).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                } else {
                                    Text(entry.kind.transcriptLabel).font(.caption).foregroundStyle(.secondary)
                                }
                                if let text = entry.text { Text(verbatim: text).font(.callout).lineLimit(2) }
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
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
        do {
            for try await rows in try store.indexedProjectActivityUpdates(requested) {
                let display = await Task.detached { rows.map(DisplayProjectActivity.init) }.value
                guard !Task.isCancelled else { return }
                entries = display
                loaded = true
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
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
    var lastActivity: Int64? { sessions.first?.session.lastActivity }

    nonisolated init(_ project: IndexedProject) {
        id = project.id
        name = SecretMasker.mask(project.name)
        path = project.path.map(SecretMasker.mask)
        location = project.location.map(SecretMasker.mask)
        repository = project.repositoryURL.flatMap(Self.displayRepository)
        agents = project.agents
        branches = project.branches.map(SecretMasker.mask)
        sessions = project.sessions.map {
            .init(session: SessionListItem($0.session), worktree: $0.worktree.map(SecretMasker.mask))
        }
        activityScope = project.activityScope
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

private struct DisplayProjectActivity: Identifiable, Sendable {
    let id: String
    let session: SessionKey
    let timestamp: Int64
    let kind: EventKind
    let title: String?
    let toolName: String?
    let text: String?

    nonisolated init(_ event: IndexedProjectActivity) {
        id = event.id
        session = event.session
        timestamp = event.timestamp
        kind = event.kind
        title = event.sessionTitle.flatMap { $0.isEmpty ? nil : SecretMasker.mask($0) }
        toolName = event.toolName.map(SecretMasker.mask)
        // Mask the complete value before shortening it for the timeline.
        text = event.text.flatMap {
            let masked = SecretMasker.mask($0).trimmingCharacters(in: .whitespacesAndNewlines)
            return masked.isEmpty ? nil : String(masked.prefix(200))
        }
    }
}
