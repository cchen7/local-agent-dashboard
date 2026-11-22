import ADCore
import ADInsights
import ADPricing
import ADPrivacy
import ADStore
import Foundation
import Observation
import SwiftUI

struct UsageNavigationRequest: Equatable, Sendable {
    let period: UsagePeriod
    let metric: UsageMetric
    let grouping: UsageGrouping
    let filter: UsageFilter
    let customStart: Date
    let customEnd: Date
    let revision: Int64

    func sameDisplayScope(as other: Self) -> Bool {
        period == other.period && metric == other.metric && grouping == other.grouping &&
            filter == other.filter && (period != .custom || (customStart == other.customStart && customEnd == other.customEnd))
    }

    func window(in store: AgentStore, now: Int64, zone: TimeZone) throws -> UsageWindow {
        let earliest = period == .all ? try store.firstUsageTimestamp(filter).map { min($0, now) } : nil
        let custom = period == .custom ? try UsageRange(
            lowerBound: Int64(customStart.timeIntervalSince1970 * 1000),
            upperBound: Int64(customEnd.timeIntervalSince1970 * 1000)) : nil
        return try UsageWindow.make(period, now: now, firstTimestamp: earliest, custom: custom, timeZone: zone)
    }
}

struct UsagePageSnapshot: Sendable {
    let report: UsageReport
    let plot: UsagePlot
    let request: UsageNavigationRequest
}

struct UsageLiveChart: Sendable {
    let chart: UsageChartSnapshot
    let plot: UsagePlot
    let request: UsageNavigationRequest
}

@MainActor @Observable
final class TokenUsageModel {
    private let store: AgentStore
    var usagePeriod: UsagePeriod = .day
    var usageMetric: UsageMetric = .tokens
    var usageGrouping: UsageGrouping = .agent
    var usageAgent: AgentKind?
    var usageProjectID: Int64?
    var usageCustomStart = Date().addingTimeInterval(-3600)
    var usageCustomEnd = Date()
    private(set) var usagePage: UsagePageSnapshot?
    private(set) var liveUsageChart: UsageLiveChart?
    private(set) var usageLoading = false
    private(set) var usageError: LocalizedStringResource?
    private(set) var usageRedlines: [AgentKind: Int64] = [:]
    private(set) var projects: [UsageProjectOption] = []
    private(set) var usageVersion: Int64 = 0

    let pricing: PricingModel

    init(store: AgentStore, pricing: PricingModel) {
        self.store = store
        self.pricing = pricing
    }

    var usageCurrency: PriceDisplayCurrency { pricing.currency }

    var usageRequest: UsageNavigationRequest {
        .init(period: usagePeriod, metric: usageMetric, grouping: usageGrouping,
              filter: .init(agent: usageAgent, projectID: usageProjectID), customStart: usageCustomStart,
              customEnd: usageCustomEnd, revision: usageVersion)
    }

    func observeUsage() async {
        let store = self.store
        let metadata = await Task.detached(priority: .utility) {
            (try? store.usageProjectOptions()) ?? []
        }.value
        guard !Task.isCancelled else { return }
        projects = metadata
        do {
            for try await revision in store.usageUpdates() {
                guard !Task.isCancelled else { return }
                usageVersion = revision
            }
        } catch {
            if !Task.isCancelled { usageError = "Could not read token usage." }
        }
    }

    func observeRedlines() async {
        do {
            for try await limits in store.usageRedlineUpdates() {
                guard !Task.isCancelled else { return }
                usageRedlines = limits
            }
        } catch {
            if !Task.isCancelled { usageRedlines = [:] }
        }
    }

    func loadUsage(_ request: UsageNavigationRequest) async {
        usageLoading = true
        usageError = nil
        defer { if usageRequest == request { usageLoading = false } }
        let store = self.store
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let zone = TimeZone.current
        let base = liveUsageChart
        do {
            let snapshot = try await Self.background {
                let window = try request.window(in: store, now: now, zone: zone)
                let report = try store.usage(window: window, filter: request.filter, metric: request.metric,
                                             grouping: request.grouping, reusing: base?.chart,
                                             liveAt: request.period == .custom ? nil : now)
                let plot = UsagePlot(report: report, period: request.period, metric: request.metric, reusing: base?.plot)
                return UsagePageSnapshot(report: report, plot: plot, request: request)
            }
            guard !Task.isCancelled, usageRequest == request else { return }
            usagePage = snapshot
            liveUsageChart = UsageLiveChart(chart: snapshot.report.chart, plot: snapshot.plot, request: request)
        } catch {
            guard !Task.isCancelled, usageRequest == request else { return }
            usagePage = nil
            liveUsageChart = nil
            usageError = request.period == .custom ? "Check the custom time range." : "Could not read token usage."
        }
    }

    func refreshUsageChart(_ request: UsageNavigationRequest) async {
        guard !usageLoading, request.period != .custom, usageRequest == request,
              let base = liveUsageChart, base.request == request else { return }
        let store = self.store
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let zone = TimeZone.current
        guard let latest = try? await Self.background({
            let chart = try store.usageChart(period: request.period, now: now, timeZone: zone,
                                             filter: request.filter, reusing: base.chart)
            return UsageLiveChart(chart: chart, plot: UsagePlot(chart: chart, period: request.period,
                                                                metric: request.metric, reusing: base.plot),
                                  request: request)
        }), !Task.isCancelled, !usageLoading, usageRequest == request, liveUsageChart?.chart.id == base.chart.id
        else { return }
        liveUsageChart = latest
    }

    func loadUsageLimits(agent: AgentKind?, includeThroughput: Bool) async -> UsageLimitReadings? {
        let store = self.store
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        return try? await Self.background {
            try store.usageLimitReadings(now: now, agent: agent, includeThroughput: includeThroughput)
        }
    }

    func displayText(_ text: String) -> String { SecretMasker.mask(text) }

    private nonisolated static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: operation)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// Holds period selection and observes only while the Usage page is presented.
struct TokenUsageEntry: View {
    @State private var model: TokenUsageModel
    let editRedlines: () -> Void
    let openPricing: () -> Void

    init(store: AgentStore, pricing: PricingModel, editRedlines: @escaping () -> Void,
         openPricing: @escaping () -> Void) {
        _model = State(initialValue: TokenUsageModel(store: store, pricing: pricing))
        self.editRedlines = editRedlines
        self.openPricing = openPricing
    }

    var body: some View {
        let request = model.usageRequest
        UsageView(model: model, editRedlines: editRedlines, openPricing: openPricing)
            .task { await model.observeUsage() }
            .task { await model.observeRedlines() }
            .task(id: request) { await model.loadUsage(request) }
    }
}

extension AgentKind {
    var title: LocalizedStringResource {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot CLI"
        case .grokBuild: "Grok Build"
        }
    }

    var badge: (text: String, color: Color) {
        switch self {
        case .claudeCode: ("CC", .orange)
        case .codex: ("CX", .mint)
        case .copilot: ("CP", .purple)
        case .grokBuild: ("GK", .blue)
        }
    }
}
