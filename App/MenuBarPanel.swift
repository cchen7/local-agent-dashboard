import ADCore
import ADInsights
import ADPricing
import ADPrivacy
import ADStore
import AppKit
import Charts
import SwiftUI

struct MenuBarPanel: View {
    let model: DashboardModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var reading: MenuUsageSnapshot?
    @State private var plot: UsagePlot?
    @State private var unavailable = false
    @State private var visible = false
    @State private var refreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextField("Search all agent sessions", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("menu.search")
                .onSubmit {
                    model.openMenuSearch(query)
                    openDashboard()
                }
            if let reading {
                readouts(reading)
                if let plot, !plot.samples.isEmpty { miniChart(plot) }
                activeSessions(reading)
            } else if unavailable || model.storageFailed {
                Text("Could not read menu usage.").font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            Divider()
            Button("Open Dashboard", action: openDashboard)
                .keyboardShortcut("d").accessibilityIdentifier("openDashboard")
            SettingsLink { Text("Settings…") }.keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 360)
        .onChange(of: visible) { _, shown in
            if !shown {
                reading = nil
                plot = nil
                unavailable = false
            }
        }
        .task(id: visible) {
            if visible { await model.load() }
        }
        .task(id: visible && model.store != nil) {
            guard visible, let store = model.store else { return }
            let handle = Task { @MainActor in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    await refresh(store)
                }
            }
            defer { handle.cancel() }
            do {
                for try await _ in store.menuUsageChanges() {
                    try Task.checkCancellation()
                    await refresh(store)
                }
            } catch {
                if !Task.isCancelled { unavailable = true }
            }
        }
        .background(WindowConfigurationView(identifier: "menuBarPanel", updateVisibility: {
            if visible != $0 { visible = $0 }
        }))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.needle").foregroundStyle(.orange)
                .frame(width: 30, height: 30)
                .background(.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent Dashboard").font(.headline)
                if let reading {
                    Text("\(reading.running) running · \(reading.waiting) waiting · \(reading.sessionsToday) sessions today")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if reading != nil && !unavailable {
                Label("Live", systemImage: "circle.fill").font(.caption2.weight(.semibold)).foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(.green.opacity(0.12), in: Capsule())
            }
        }
    }

    private func readouts(_ value: MenuUsageSnapshot) -> some View {
        HStack(spacing: 6) {
            tile("Now") {
                Text("\(value.currentTokens.formatted(.number.notation(.compactName))) tok/min")
                Text("\(value.limits.throughput.count) agents active").font(.caption2).foregroundStyle(.secondary)
            }
            tile("Today") {
                Text(value.today.counts.total.formatted(.number.notation(.compactName)))
                if value.today.hasPricedUsage {
                    Text(PriceDisplayCurrency.usd.formattedMicroUSD(Decimal(value.today.costMicroUSD)))
                        .font(.caption2).foregroundStyle(.secondary)
                    if value.today.unpricedTokens > 0 { Text("Partial estimate").font(.caption2).foregroundStyle(.secondary) }
                } else if value.today.unpricedTokens > 0 {
                    Text("Unpriced").font(.caption2).foregroundStyle(.secondary)
                }
            }
            tile("Limit headroom") {
                switch usageHeadroom(readings: value.limits, limits: value.redlines) {
                case .codex(let windows, _):
                    if let tightest = windows.min(by: { $0.remaining < $1.remaining }) {
                        Text(tightest.remaining.formatted(.percent.precision(.fractionLength(1))))
                        Text("Codex limits").font(.caption2).foregroundStyle(.secondary)
                    }
                case .manual(let redline):
                    Text(redline.remaining.formatted(.percent.precision(.fractionLength(1))))
                    Text(verbatim: redline.agent.sessionName).font(.caption2).foregroundStyle(.secondary)
                case .noRecentUsage: Text("No recent usage")
                case .notSet:
                    Button("Not set") {
                        model.settingsPage = .thresholds
                        openSettings()
                    }
                    .buttonStyle(.link)
                }
            }
        }
        .accessibilityIdentifier("menu.usage")
    }

    private func tile<Content: View>(_ title: LocalizedStringResource, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            content().font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
        .padding(6).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
    }

    private func miniChart(_ value: UsagePlot) -> some View {
        let agents = AgentKind.allCases.filter { agent in value.samples.contains { $0.agent == agent && $0.throughput > 0 } }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("Today · call-level throughput").lineLimit(1)
                Spacer(minLength: 0)
                ForEach(agents, id: \.self) { agent in
                    Label(agent.sessionInitials, systemImage: "circle.fill").foregroundStyle(agent.sessionColor)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            Chart(value.samples) { sample in
                LineMark(x: .value("Time", Date(timeIntervalSince1970: Double(sample.timestamp) / 1000)),
                         y: .value("Throughput", sample.throughput),
                         series: .value("Agent", sample.agent?.rawValue ?? "combined"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(sample.agent?.sessionColor ?? Color.primary)
                    .lineStyle(StrokeStyle(lineWidth: sample.agent == nil ? 1.8 : 1))
            }
            .chartLegend(.hidden).chartYAxis(.hidden).frame(height: 76)
        }
        .padding(7).background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    private func activeSessions(_ value: MenuUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Active Sessions").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !value.sessions.isEmpty { Button("See All") { model.openMenuSearch(""); openDashboard() }.buttonStyle(.link) }
            }
            if value.sessions.isEmpty {
                Text("No active sessions").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(value.sessions) { row in
                            Button {
                                model.openProjectSession(row.id)
                                openDashboard()
                            } label: { sessionRow(row, measuredAt: value.limits.measuredAt) }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 6 * 37)
            }
        }
        .accessibilityIdentifier("menu.sessions")
    }

    private func sessionRow(_ row: MenuUsageSession, measuredAt: Int64) -> some View {
        let session = SessionListItem(row.session)
        let project = row.project.map(SecretMasker.mask) ?? session.path?.split(separator: "/").last.map(String.init)
        return HStack(spacing: 6) {
            SessionAgentMark(agent: session.id.agent)
            VStack(alignment: .leading, spacing: 2) {
                SessionTitle(title: session.title).lineLimit(1)
                HStack(spacing: 4) {
                    if let project { Text(verbatim: project).lineLimit(1) }
                    Text(session.status.label).foregroundStyle(session.status.color)
                    if let began = session.startedAt, began >= 0, measuredAt >= began {
                        Text("\((measuredAt - began) / 60_000) min")
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if session.status == .waiting {
                switch session.statusReason.flatMap(StatusInferenceReason.init(rawValue:)) {
                case .possiblyNeedsApproval:
                    Text("Possibly needs approval").foregroundStyle(.orange).font(.caption2)
                case .needsApproval:
                    Text("Needs approval").foregroundStyle(.orange).font(.caption2)
                case .waitingForReply:
                    Text("Waiting for reply").foregroundStyle(.orange).font(.caption2)
                default: rate(row.tokensPerMinute)
                }
            } else { rate(row.tokensPerMinute) }
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder private func rate(_ tokens: Int64) -> some View {
        if tokens > 0 { Text("\(tokens.formatted(.number.notation(.compactName))) tok/min").font(.caption2).monospacedDigit() }
    }

    private func refresh(_ store: AgentStore) async {
        guard visible, !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let base = reading?.chart
        let priorPlot = plot
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        do {
            let (snapshot, rendered) = try await Task.detached(priority: .utility) {
                let snapshot = try store.menuUsage(now: now, timeZone: .current, reusing: base)
                return (snapshot, UsagePlot(chart: snapshot.chart, period: .day, metric: .tokens, reusing: priorPlot))
            }.value
            guard visible, !Task.isCancelled else { return }
            reading = snapshot
            plot = rendered
            unavailable = false
        } catch {
            guard visible, !Task.isCancelled else { return }
            reading = nil
            plot = nil
            unavailable = true
        }
    }

    private func openDashboard() {
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}
