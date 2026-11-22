import ADCore
import ADInsights
import ADStore
import Charts
import SwiftUI

struct SessionOverviewOptions: Sendable {
    var enabled = true
    var searchTopic: @MainActor @Sendable (String) -> Void = { _ in }
}

private struct SessionOverviewOptionsKey: EnvironmentKey {
    static let defaultValue = SessionOverviewOptions()
}

extension EnvironmentValues {
    var sessionOverviewOptions: SessionOverviewOptions {
        get { self[SessionOverviewOptionsKey.self] }
        set { self[SessionOverviewOptionsKey.self] = newValue }
    }
}

struct SessionOverview: View {
    let session: SessionListItem
    let store: AgentStore
    @Environment(\.sessionOverviewOptions) private var options
    @Environment(\.secretMaskingEnabled) private var maskSecrets
    @State private var value: SessionOverviewDisplay?
    @State private var loaded = false
    @State private var failed = false
    @State private var usage: [SessionTokenBucket] = []
    nonisolated private static let scorer = try? TopicScorer()

    var body: some View {
        Group {
            if failed {
                EmptyPanel(title: "Could not read the overview", symbol: "exclamationmark.triangle",
                           message: "Select the session again to retry.")
            } else if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let value, !value.isEmpty || !usage.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        if let activity = session.lastActivity, activity > 0 {
                            LabeledContent("Session Activity") {
                                Text(Date(timeIntervalSince1970: Double(activity) / 1000), style: .relative)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                        }
                        if !value.topics.isEmpty { topicChips(value.topics) }
                        if value.summary != nil || value.lastPrompt != nil || value.lastReply != nil {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Latest Progress").font(.headline)
                                excerpt("Agent Summary", value.summary)
                                excerpt("Last Prompt", value.lastPrompt)
                                excerpt("Last Reply", value.lastReply)
                            }
                        }
                        rows("Recent Actions", value.recentActions)
                        rows("Touched Files", value.files)
                        rows("Commands Run", value.commands)
                        if !usage.isEmpty { tokenChart }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("session.overview")
            } else {
                EmptyPanel(title: "No overview yet", symbol: "text.bubble",
                           message: "Indexed summaries and recent actions will appear here.")
            }
        }
        .task(id: session.id) { await observe() }
        .task(id: session.id) { await observeUsage() }
    }

    private var tokenChart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Session Tokens").font(.headline)
            Chart(usage) { point in
                let date = Date(timeIntervalSince1970: Double(point.timestamp) / 1000)
                if point.callTokens > 0 {
                    BarMark(x: .value("Time", date), y: .value("Tokens", point.callTokens))
                        .foregroundStyle(Color.accentColor)
                }
                if point.coarseTokens > 0 {
                    BarMark(x: .value("Time", date), y: .value("Tokens", point.coarseTokens))
                        .foregroundStyle(.secondary.opacity(0.55))
                }
            }
            .frame(height: 88)
            .accessibilityIdentifier("session.usage.chart")
            if usage.contains(where: { $0.coarseTokens > 0 }) {
                Label("Includes session-level estimates", systemImage: "square.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func observeUsage() async {
        usage = []
        do {
            for try await buckets in store.sessionTokenChartUpdates(in: session.id) {
                guard !Task.isCancelled else { return }
                usage = buckets
            }
        } catch {
            if !Task.isCancelled { usage = [] }
        }
    }

    private func topicChips(_ topics: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Main Topics").font(.headline)
            ScrollView(.horizontal) {
                HStack(spacing: 5) {
                    ForEach(topics, id: \.self) { term in
                        Button { options.searchTopic(term) } label: { Text(verbatim: term) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    @ViewBuilder private func excerpt(_ title: LocalizedStringResource, _ text: String?) -> some View {
        if let text {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Text(verbatim: text).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder private func rows(_ title: LocalizedStringResource, _ entries: [SessionOverviewDisplay.Row]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.headline)
                ForEach(Array(entries.enumerated()), id: \.offset) { _, row in OverviewRowView(row: row) }
            }
        }
    }

    private func observe() async {
        let masking = maskSecrets
        do {
            for try await raw in store.sessionOverviewUpdates(in: session.id) {
                let safe = await Task.detached {
                    raw.map { SessionOverviewDisplay($0, scorer: Self.scorer, maskSecrets: masking) }
                }.value
                guard !Task.isCancelled else { return }
                value = safe
                loaded = true
                failed = false
            }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

private struct OverviewRowView: View {
    let row: SessionOverviewDisplay.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label { Text(title) } icon: { Image(systemName: icon) }
                if let detail = row.detail { Text(verbatim: detail).lineLimit(1) }
                Spacer(minLength: 4)
                if row.timestamp > 0 {
                    Text(Date(timeIntervalSince1970: Double(row.timestamp) / 1000), style: .time)
                }
            }
            .foregroundStyle(.secondary)
            if let text = row.text {
                Text(verbatim: text).lineLimit(3).textSelection(.enabled)
            }
            if row.added != nil || row.removed != nil || row.exitCode != nil || row.durationMS != nil {
                HStack(spacing: 8) {
                    if let added = row.added, added >= 0 { Text(verbatim: "+\(added)") }
                    if let removed = row.removed, removed >= 0 { Text(verbatim: "−\(removed)") }
                    if let code = row.exitCode { Text("Exit \(code)") }
                    if let duration = row.durationMS, duration >= 0 { Text("\(duration) ms") }
                }
                .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private var title: LocalizedStringResource {
        switch row.kind {
        case .file: "File"
        case .command: "Command"
        case .tool(.toolResult): "Tool Result"
        case .tool: "Tool Call"
        }
    }

    private var icon: String {
        switch row.kind {
        case .file: "doc"
        case .command, .tool(.toolCall): "terminal"
        case .tool: "doc.text"
        }
    }
}
