import ADCore
import ADInsights
import ADPricing
import ADStore
import Charts
import SwiftUI

struct UsageView: View {
    @DashboardClock private var clock
    @Bindable var model: TokenUsageModel
    let editRedlines: () -> Void
    let openPricing: () -> Void
    private typealias Width = UsageBreakdownColumns

    var body: some View {
        GeometryReader { viewport in
            if model.usageError == nil, let snapshot = model.usagePage, snapshot.report.totals.records > 0,
               snapshot.request.sameDisplayScope(as: model.usageRequest) {
                ScrollView {
                    UsageViewportLayout(viewport: max(0, viewport.size.height - 8)) {
                        VStack(alignment: .leading, spacing: 10) {
                            controls
                            rangeLabel(snapshot)
                            readouts(snapshot, showCaptions: DashboardLayoutRules.usageCaptions(width: viewport.size.width))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        liveChart(snapshot)
                        breakdown(snapshot, availableWidth: max(0, viewport.size.width - 24))
                    }
                    .padding(.bottom, 8)
                }
                .accessibilityIdentifier("usage.presented")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    controls
                    if let error = model.usageError {
                        EmptyPanel(title: error, symbol: "exclamationmark.triangle", message: "Try a different period or filter.")
                    } else if model.usageLoading ||
                        (model.usagePage.map { !$0.request.sameDisplayScope(as: model.usageRequest) } ?? false) {
                        ProgressView("Loading token usage…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        EmptyPanel(title: "No token usage yet", symbol: "gauge.with.needle",
                                   message: "Usage and list-price estimates will appear after indexing.")
                            .accessibilityIdentifier("empty.tokens")
                    }
                }
            }
        }
        .padding(14)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.usageMetric == .cost ? "Estimated spend" : "Token throughput")
                    .font(.title3.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Picker("Period", selection: $model.usagePeriod) {
                    ForEach(UsagePeriod.allCases, id: \.self) { Text($0.displayLabel).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize()
            }
            HStack {
                Spacer(minLength: 0)
                Picker("Metric", selection: $model.usageMetric) {
                    Text("Tokens").tag(UsageMetric.tokens)
                    Text("Output only").tag(UsageMetric.output)
                    Text("Cost").tag(UsageMetric.cost)
                }
                .accessibilityIdentifier("usage.metric")
                Picker("Agent", selection: $model.usageAgent) {
                    Text("All agents").tag(nil as AgentKind?)
                    ForEach(AgentKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
                Picker("Project", selection: $model.usageProjectID) {
                    Text("All projects").tag(nil as Int64?)
                    ForEach(model.projects) { Text(verbatim: model.displayText($0.name)).tag(Optional($0.id)) }
                }
                if model.usageMetric == .cost, model.pricing.currencies.count > 1 {
                    UsageCurrencyPicker(pricing: model.pricing)
                }
            }
            if model.usagePeriod == .custom {
                HStack {
                    Spacer(minLength: 0)
                    DatePicker("From", selection: $model.usageCustomStart, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("To", selection: $model.usageCustomEnd, displayedComponents: [.date, .hourAndMinute])
                }
                .environment(\.locale, clock.locale)
            }
        }
    }

    private func rangeLabel(_ snapshot: UsagePageSnapshot) -> some View {
        let range = snapshot.report.window.range
        return Text("Summary window: \(usageDate(range.lowerBound).formatted(clock.month().day().hour().minute())) – \(usageDate(range.upperBound).formatted(clock.month().day().hour().minute()))")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    private struct ChartRefreshKey: Equatable {
        let scope: UsageNavigationRequest
        let tick: Int64
    }

    private func liveChart(_ snapshot: UsagePageSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 5)) { tick in
            let live = model.liveUsageChart.flatMap { $0.request == snapshot.request ? $0 : nil }
            let data = live?.chart ?? snapshot.report.chart
            let plot = live?.plot ?? snapshot.plot
            Group {
                if snapshot.request.metric == .cost && !data.points.contains(where: { $0.totals.hasPricedUsage }) {
                    Text("No priced usage in this period.").font(.callout).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: DashboardLayoutRules.minimumPlotHeight,
                               idealHeight: DashboardLayoutRules.minimumPlotHeight, maxHeight: .infinity)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
                } else {
                    UsageChart(data: data, plot: plot, request: snapshot.request,
                               currency: model.usageCurrency, redlines: model.usageRedlines)
                }
            }
            .task(id: ChartRefreshKey(scope: snapshot.request, tick: Int64(tick.date.timeIntervalSince1970 / 5))) {
                await model.refreshUsageChart(snapshot.request)
            }
        }
    }

    private func readouts(_ value: UsagePageSnapshot, showCaptions: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) { tiles(value, showCaptions: showCaptions) }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(showCaptions ? "usage.readouts.standard" : "usage.readouts.compact")
    }

    @ViewBuilder private func tiles(_ snapshot: UsagePageSnapshot, showCaptions: Bool) -> some View {
        let report = snapshot.report
        let metric = snapshot.request.metric
        let currency = model.usageCurrency
        UsageTile(title: metric == .cost ? "Peak spend rate" : "Peak throughput") {
            if let peak = report.peak {
                if metric == .cost {
                    Text("\(currency.formattedMicroUSD(Decimal(peak.value) * 60)) / h")
                } else {
                    Text("\(peak.value.formatted()) tok/min")
                }
                if showCaptions {
                    Text(verbatim: usageDate(peak.timestamp).formatted(clock.hour().minute())).font(.caption).foregroundStyle(.secondary)
                }
            } else if metric == .cost { Text("No priced call-level usage") }
            else { Text("No call-level usage") }
        }
        UsageTile(title: "Period total") {
            totalValue(report.totals, metric: metric, currency: currency)
            if showCaptions { comparison(report: report, metric: metric) }
            if showCaptions, metric == .tokens, let hit = report.totals.cacheHitRate {
                Text("Cache hit: \(hit.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        UsageTile(title: "Estimated cost · list price") {
            totalValue(report.totals, metric: .cost, currency: currency)
            if showCaptions {
                if metric != .cost { comparison(report: report, metric: .cost) }
                cacheSavings(report, currency: currency)
                if let date = currency.asOf {
                    Text("Static exchange rate dated \(date.rawValue)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if report.totals.unpricedTokens > 0 {
                Button { openPricing() } label: {
                    Text("\(report.totals.unpricedTokens.formatted()) unpriced tokens")
                }
                .buttonStyle(.link).font(.caption)
                .accessibilityIdentifier("usage.openPricing")
            }
        }
        UsageTile(title: "Limit headroom") {
            UsageHeadroomReadout(model: model, agent: snapshot.request.filter.agent, compact: !showCaptions,
                                 showCaption: showCaptions, editRedlines: editRedlines)
        }
    }

    @ViewBuilder private func cacheSavings(_ report: UsageReport, currency: PriceDisplayCurrency) -> some View {
        let totalReads = report.totals.counts.cacheRead
        if totalReads > 0 {
            if let saving = report.cacheSavings, saving.measuredCacheReadTokens > 0 {
                let value = Decimal(saving.microUSD)
                let amount = currency.formattedMicroUSD(value < 0 ? -value : value)
                if saving.microUSD < 0 {
                    Text("Extra cache-read cost: \(amount)").font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("Cache savings: \(amount)").font(.caption2).foregroundStyle(.secondary)
                }
                if saving.measuredCacheReadTokens < totalReads {
                    Text("Some cache-read rates are unavailable.").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Cache savings unavailable").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func comparison(report: UsageReport, metric: UsageMetric) -> some View {
        if let previous = report.previous, previous.value(metric) > 0,
           metric != .cost || (report.totals.hasPricedUsage && previous.hasPricedUsage) {
            let prior = previous.value(metric)
            let change = Double(report.totals.value(metric)) / Double(prior) - 1
            Text("\(change.formatted(.percent.precision(.fractionLength(1)))) vs previous period")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func totalValue(_ totals: UsageTotals, metric: UsageMetric,
                                          currency: PriceDisplayCurrency) -> some View {
        if metric != .cost { Text(totals.value(metric).formatted()) }
        else if totals.hasPricedUsage { Text(currency.formattedMicroUSD(Decimal(totals.costMicroUSD))) }
        else { Text("Unpriced") }
    }

    private func breakdown(_ snapshot: UsagePageSnapshot, availableWidth: CGFloat) -> some View {
        let columns = UsageBreakdownColumns(width: availableWidth, showCost: snapshot.request.metric != .cost)
        return breakdown(snapshot, columns: columns)
    }

    private func breakdown(_ snapshot: UsagePageSnapshot, columns: UsageBreakdownColumns) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Usage breakdown").font(.headline)
                Spacer()
                Picker("Group by", selection: $model.usageGrouping) {
                    Text("Agent").tag(UsageGrouping.agent)
                    Text("Project").tag(UsageGrouping.project)
                    Text("Model").tag(UsageGrouping.model)
                }
                .labelsHidden().fixedSize()
            }
            breakdownGrid(snapshot, columns: columns)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
    }

    private func breakdownGrid(_ snapshot: UsagePageSnapshot, columns: UsageBreakdownColumns) -> some View {
        let report = snapshot.report
        let metric = snapshot.request.metric
        let currency = model.usageCurrency
        let denominator = report.totals.value(metric)
        return Grid(alignment: .leading, horizontalSpacing: Width.spacing, verticalSpacing: 7) {
            GridRow {
                cell(columns.flexible, alignment: .leading) { Text("Name") }
                cell(Width.peak) { Text(metric == .cost ? "Peak spend / h" : "Peak tok/min") }
                if columns.showPeakTime {
                    cell(Width.peakTime) { Text("Peak time").accessibilityIdentifier("usage.breakdown.peakTime") }
                }
                cell(Width.total) { Text("Total") }
                if columns.showCache {
                    cell(Width.cache) { Text("Cache hit rate").accessibilityIdentifier("usage.breakdown.cacheRate") }
                }
                if columns.showCost { cell(Width.cost) { Text("Estimated cost") } }
                cell(columns.flexible, alignment: .leading) { Text("Share") }
                cell(Width.sessions) { Text("Sessions") }
            }
            .foregroundStyle(.secondary)
            ForEach(report.breakdown) { row in
                GridRow {
                    cell(columns.flexible, alignment: .leading) {
                        if let agent = row.agent { Text(agent.title).foregroundStyle(agent.badge.color) }
                        else if let label = row.label { Text(verbatim: model.displayText(label)) }
                        else { Text("Unassigned") }
                    }
                    breakdownValues(row.peak, totals: row.totals, sessions: row.sessions, metric: metric,
                                    currency: currency, denominator: denominator, columns: columns)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                cell(columns.flexible, alignment: .leading) { Text("All matching usage") }
                breakdownValues(report.peak, totals: report.totals, sessions: report.sessionCount, metric: metric,
                                currency: currency, denominator: denominator, columns: columns)
            }
            .fontWeight(.semibold)
        }
        .font(.caption).monospacedDigit()
    }

    @ViewBuilder private func breakdownValues(_ peak: UsagePeak?, totals: UsageTotals, sessions: Int,
                                               metric: UsageMetric, currency: PriceDisplayCurrency,
                                               denominator: Int64, columns: UsageBreakdownColumns) -> some View {
        cell(Width.peak) {
            if let peak {
                if metric == .cost { Text(currency.formattedMicroUSD(Decimal(peak.value) * 60)) }
                else { Text(peak.value.formatted()) }
            } else { Text("—") }
        }
        if columns.showPeakTime {
            cell(Width.peakTime) {
                if let peak { Text(verbatim: usageDate(peak.timestamp).formatted(clock.hour().minute())) }
                else { Text("—") }
            }
        }
        cell(Width.total) { totalValue(totals, metric: metric, currency: currency) }
        if columns.showCache {
            cell(Width.cache) {
                if let hit = totals.cacheHitRate { Text(hit.formatted(.percent.precision(.fractionLength(0)))) }
                else { Text("—") }
            }
        }
        if columns.showCost { cell(Width.cost) { totalValue(totals, metric: .cost, currency: currency) } }
        cell(columns.flexible, alignment: .leading) {
            if denominator > 0, metric != .cost || totals.hasPricedUsage {
                shareBar(Double(totals.value(metric)) / Double(denominator))
            }
            else { Text("—") }
        }
        cell(Width.sessions) { Text(sessions.formatted()) }
    }

    private func shareBar(_ share: Double) -> some View {
        HStack(spacing: 5) {
            GeometryReader { proxy in
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Color.accentColor).frame(width: proxy.size.width * min(1, max(0, share)))
                    }
            }
            .frame(height: 4)
            Text(share.formatted(.percent.precision(.fractionLength(0)))).fixedSize()
        }
    }

    private func cell<Content: View>(_ width: CGFloat, alignment: Alignment = .trailing,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        content().lineLimit(1).frame(width: width, alignment: alignment)
    }


}

extension UsagePeriod {
    var displayLabel: LocalizedStringResource {
        switch self {
        case .hour: "1H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        case .quarter: "90D"
        case .all: "All"
        case .custom: "Custom…"
        }
    }
}

/// Three vertically stacked blocks. Only the chart receives spare viewport
/// height; when content is taller than the viewport, the ScrollView scrolls it.
private struct UsageViewportLayout: Layout {
    let viewport: CGFloat
    private let gap: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 3 else { return .zero }
        let width = proposal.width ?? 760
        let heights = blockHeights(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.reduce(0, +) + 2 * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let heights = blockHeights(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (index, child) in subviews.enumerated() {
            child.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                        proposal: ProposedViewSize(width: bounds.width, height: heights[index]))
            y += heights[index] + gap
        }
    }

    private func blockHeights(width: CGFloat, subviews: Subviews) -> [CGFloat] {
        let intrinsic = ProposedViewSize(width: width, height: nil)
        let header = subviews[0].sizeThatFits(intrinsic).height
        let chart = subviews[1].sizeThatFits(intrinsic).height
        let table = subviews[2].sizeThatFits(intrinsic).height
        return [header, DashboardLayoutRules.chartBlockHeight(viewport: viewport, header: header, table: table,
                                                               naturalChart: chart, spacing: gap), table]
    }
}

struct UsageCurrencyPicker: View {
    let pricing: PricingModel

    var body: some View {
        Picker("Display currency", selection: Binding(
            get: { pricing.currency.code },
            set: { pricing.selectCurrency($0) }
        )) {
            ForEach(pricing.currencies) { currency in
                Text(verbatim: currency.code).tag(currency.code)
            }
        }
        .help(pricing.currency.asOf.map { String(localized: "Static exchange rate dated \($0.rawValue)") } ?? "")
    }
}

extension PriceDisplayCurrency {
    func formattedMicroUSD(_ value: Decimal) -> String {
        amount(microUSD: value)?.formatted(.currency(code: code).precision(.fractionLength(2...6))) ?? "—"
    }
}

struct UsageHeadroomReadout: View {
    @DashboardClock private var clock
    let model: TokenUsageModel
    let agent: AgentKind?
    let compact: Bool
    var showCaption = true
    let editRedlines: () -> Void
    @State private var response: Response?

    private struct Response {
        let agent: AgentKind?
        let readings: UsageLimitReadings?
    }

    private struct RefreshKey: Equatable {
        let slot: Int64
        let version: Int64
        let agent: AgentKind?
        let includeThroughput: Bool
    }

    var body: some View {
        // Refresh this short snapshot only while the card is on screen.
        // It never asks for the historical chart or overview again.
        TimelineView(.periodic(from: .now, by: 5)) { tick in
            let key = RefreshKey(slot: Int64(tick.date.timeIntervalSince1970 / 5),
                                 version: model.usageVersion, agent: agent,
                                 includeThroughput: model.usageRedlines.keys.contains { agent == nil || agent == $0 })
            contents
                .task(id: key) {
                    let readings = await model.loadUsageLimits(agent: key.agent, includeThroughput: key.includeThroughput)
                    if !Task.isCancelled { response = Response(agent: key.agent, readings: readings) }
                }
        }
    }

    @ViewBuilder private var contents: some View {
        if let response, response.agent == agent {
            if let reading = response.readings {
                let display = usageHeadroom(readings: reading, limits: model.usageRedlines, agent: agent)
                switch display {
                case .codex(let windows, let other):
                    if let tightest = windows.min(by: { $0.remaining < $1.remaining }) {
                        Text(tightest.remaining.formatted(.percent.precision(.fractionLength(1))))
                    }
                    if compact {
                        if showCaption { Text("Codex limits").font(.caption2).foregroundStyle(.secondary) }
                    } else {
                        ForEach(windows) { window in
                            HStack(spacing: 4) {
                                Text(window.window == .primary ? "Primary" : "Secondary")
                                Text("\((window.usedPercent / 100).formatted(.percent.precision(.fractionLength(0)))) used")
                                if let reset = window.resetAt {
                                    Text("Reset \(usageDate(reset).formatted(clock.month().day().hour().minute()))")
                                }
                            }
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let other {
                            HStack(spacing: 4) {
                                Text(other.agent.title)
                                Text("\(other.remaining.formatted(.percent.precision(.fractionLength(1)))) left")
                            }
                            .font(.caption2).foregroundStyle(other.overRedline ? Color.orange : Color.secondary)
                        }
                    }
                case .manual(let limit):
                    Text(limit.remaining.formatted(.percent.precision(.fractionLength(1))))
                        .foregroundStyle(limit.overRedline ? Color.orange : Color.primary)
                    if showCaption || limit.overRedline {
                        HStack(spacing: 4) {
                            if showCaption { Text(limit.agent.title) }
                            if limit.overRedline { Text("Over redline") }
                        }
                        .font(.caption2).foregroundStyle(.secondary)
                    }
                    if !compact {
                        Text("\(limit.tokensPerMinute.formatted()) / \(limit.limit.formatted()) tok/min · last 60 s")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                case .noRecentUsage:
                    Text("No recent throughput").font(.caption2).foregroundStyle(.secondary)
                case .notSet:
                    Button("Not set", action: editRedlines)
                        .buttonStyle(.link)
                        .accessibilityIdentifier("usage.editRedlines")
                }
            } else { Text("Limit readings unavailable").font(.caption2).foregroundStyle(.secondary) }
        } else { Text("Reading limits…").font(.caption2).foregroundStyle(.secondary) }
    }
}

private struct UsageTile<Value: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let value: () -> Value

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).lineLimit(1)
            value().font(.body.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 55, alignment: .leading)
        .padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct UsageChart: View {
    @DashboardClock private var clock
    let data: UsageChartSnapshot
    let plot: UsagePlot
    let request: UsageNavigationRequest
    let currency: PriceDisplayCurrency
    let redlines: [AgentKind: Int64]
    @State private var hovered: Int64?
    @State private var peakOverflow: [String] = []

    private struct StackedBar: Identifiable {
        let sample: UsageDisplaySample
        let lower: Double
        let upper: Double
        var id: String { sample.id }
    }

    private var longPeriod: Bool { request.period == .month || request.period == .quarter }
    private var combined: [UsageDisplaySample] { plot.samples.filter { $0.agent == nil } }
    private var guides: [UsageRedlineGuide] {
        guard request.metric == .tokens else { return [] }
        return UsageRedlineGuide.make(limits: redlines, agent: request.filter.agent,
                                      window: data.window, unit: plot.axisUnit)
    }
    private var ceiling: Double {
        max(1, plot.maxThroughput, guides.flatMap(\.segments).map(\.value).max() ?? 0)
    }
    private var scale: Double { plot.maxCumulative > 0 ? ceiling / plot.maxCumulative : 0 }
    private var fallback: [UsageDisplaySample] { combined.filter { $0.coarseThroughput > 0 } }
    private var peaks: [UsageCurvePeak] { UsageCurvePeak.select(from: plot.samples) }

    private var bars: [StackedBar] {
        var levels: [Int64: Double] = [:]
        return plot.samples.filter { $0.agent != nil && $0.throughput > 0 }.map { sample in
            let lower = levels[sample.timestamp, default: 0]
            let upper = lower + sample.throughput
            levels[sample.timestamp] = upper
            return StackedBar(sample: sample, lower: lower, upper: upper)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(axisLabel).font(.caption.weight(.semibold))
                Spacer(minLength: 4)
                if !fallback.isEmpty { Text("Hatched: session-level precision").font(.caption2).foregroundStyle(.secondary) }
                Text("Dashed: cumulative").font(.caption2).foregroundStyle(.secondary)
            }
            if let recent = data.recent { nowReadout(recent) }
            chart.frame(minHeight: DashboardLayoutRules.minimumPlotHeight, idealHeight: DashboardLayoutRules.minimumPlotHeight,
                        maxHeight: .infinity)
                .layoutPriority(1)
            let overflow = peaks.filter { peakOverflow.contains($0.id) }
            if !overflow.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Peaks").font(.caption2.weight(.semibold))
                    ForEach(overflow) { peak in peakDescription(peak) }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !guides.isEmpty {
                HStack(spacing: 8) {
                    Text("Throughput redlines").foregroundStyle(.red)
                    ForEach(guides) { guide in
                        Text(guide.agent.title)
                        Text("\(guide.limit.formatted()) tok/min")
                    }
                }
                .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            }
            if let hovered { hoverValues(hovered) }
        }
        .padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("usage.chart")
    }

    private var chart: some View {
        Chart {
            if longPeriod {
                ForEach(bars) { bar in
                    BarMark(x: .value("Bucket", barCenter(bar.sample)), yStart: .value("Base", bar.lower),
                            yEnd: .value("Throughput", bar.upper), width: .ratio(0.82))
                        .foregroundStyle(bar.sample.agent?.badge.color ?? Color.primary)
                }
            } else {
                ForEach(combined) { sample in
                    AreaMark(x: .value("Time", plottedDate(sample.timestamp)), y: .value("Combined", sample.throughput))
                        .interpolationMethod(.monotone).foregroundStyle(Color.primary.opacity(0.06))
                }
                ForEach(plot.samples) { sample in
                    LineMark(x: .value("Time", plottedDate(sample.timestamp)), y: .value("Throughput", sample.throughput),
                             series: .value("Agent", sample.agent?.rawValue ?? "combined"))
                        .interpolationMethod(.monotone).foregroundStyle(sample.agent?.badge.color ?? Color.primary)
                        .lineStyle(StrokeStyle(lineWidth: sample.agent == nil ? 2.2 : 1.4))
                }
            }
            ForEach(combined) { sample in
                LineMark(x: .value("Time", plottedDate(sample.timestamp)), y: .value("Cumulative", sample.cumulative * scale),
                         series: .value("Agent", "cumulative"))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
            }
            ForEach(guides) { guide in
                ForEach(guide.segments) { segment in
                    RuleMark(xStart: .value("Time", usageDate(segment.start)),
                             xEnd: .value("Time", usageDate(segment.end)),
                             y: .value("Redline", segment.value))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .foregroundStyle(Color.red.opacity(0.8))
                }
            }
            if let hovered {
                let position = max(hovered, data.window.range.lowerBound)
                RuleMark(x: .value("Selected time", usageDate(position))).foregroundStyle(.secondary)
            }
            if data.recent != nil {
                RuleMark(x: .value("Now", usageDate(data.window.range.upperBound)))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartXScale(domain: usageDate(data.window.range.lowerBound)...usageDate(data.window.range.upperBound))
        .chartYScale(domain: 0...ceiling * 1.08)
        .chartYAxis {
            if request.metric == .cost {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(axisValue(amount)) }
                    }
                }
            } else {
                AxisMarks(position: .leading)
            }
            if scale > 0 {
                AxisMarks(position: .trailing) { value in
                    AxisValueLabel {
                        if let amount = value.as(Double.self) { Text(axisValue(amount / scale)) }
                    }
                }
            }
        }
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Canvas { context, _ in
                    guard let anchor = proxy.plotFrame, let zero = proxy.position(forY: 0.0) else { return }
                    let plot = geometry[anchor]
                    let barWidth = max(2, plot.width / Double(max(1, combined.count)) * 0.8)
                    for sample in fallback {
                        guard let x = proxy.position(forX: plottedDate(sample.timestamp)),
                              let y = proxy.position(forY: sample.coarseThroughput) else { continue }
                        let rect = CGRect(x: plot.minX + x, y: plot.minY + y, width: barWidth, height: max(0, zero - y)).intersection(plot)
                        guard !rect.isEmpty else { continue }
                        var layer = context
                        layer.clip(to: Path(rect))
                        var stripes = Path()
                        var line = rect.minX - rect.height
                        while line < rect.maxX {
                            stripes.move(to: CGPoint(x: line, y: rect.maxY))
                            stripes.addLine(to: CGPoint(x: line + rect.height, y: rect.minY))
                            line += 4
                        }
                        layer.stroke(stripes, with: .color(.secondary.opacity(0.60)), lineWidth: 0.8)
                    }
                }
                .allowsHitTesting(false)
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            guard let anchor = proxy.plotFrame, geometry[anchor].contains(location),
                                  let date = proxy.value(atX: location.x - geometry[anchor].minX, as: Date.self) else { hovered = nil; return }
                            let time = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
                            let range = data.window.range
                            guard time >= range.lowerBound, time < range.upperBound else { hovered = nil; return }
                            hovered = try? data.window.bucketRange(containing: time).lowerBound
                        case .ended: hovered = nil
                        }
                    }
                if let anchor = proxy.plotFrame {
                    peakOverlay(proxy: proxy, frame: geometry[anchor])
                        .allowsHitTesting(false)
                }
            }
        }
        .onPreferenceChange(PeakOverflowKey.self) { peakOverflow = $0 }
        .environment(\.locale, clock.locale)
    }

    private struct PeakOverflowKey: PreferenceKey {
        static let defaultValue: [String] = []
        static func reduce(value: inout [String], nextValue: () -> [String]) { value = nextValue() }
    }

    private func plottedDate(_ timestamp: Int64) -> Date {
        usageDate(max(timestamp, data.window.range.lowerBound))
    }

    private func barCenter(_ sample: UsageDisplaySample) -> Date {
        let lower = plottedDate(sample.timestamp)
        let upper = usageDate(min(sample.endTimestamp, data.window.range.upperBound))
        return lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
    }

    private func position(_ proxy: ChartProxy, date: Date, height: Double) -> CGPoint? {
        guard let x = proxy.position(forX: date), let y = proxy.position(forY: height),
              x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    private func peakRequests(_ peaks: [UsageCurvePeak], proxy: ChartProxy) -> [PeakChipRequest] {
        let dailyBars = longPeriod ? bars : []
        return peaks.compactMap { peak in
            let date: Date
            let y: Double
            if longPeriod {
                if let agent = peak.agent {
                    guard let bar = dailyBars.first(where: { $0.sample.agent == agent && $0.sample.timestamp == peak.timestamp })
                    else { return nil }
                    date = barCenter(bar.sample)
                    y = bar.upper
                } else {
                    guard let sample = combined.first(where: { $0.timestamp == peak.timestamp }) else { return nil }
                    date = barCenter(sample)
                    y = peak.value
                }
            } else {
                date = plottedDate(peak.timestamp)
                y = peak.value
            }
            guard let anchor = position(proxy, date: date, height: y) else { return nil }
            let width: CGFloat = peak.agent == nil ? 146 : 78
            return PeakChipRequest(id: peak.id, anchor: anchor, size: CGSize(width: width, height: 18))
        }
    }

    private func peakObstacles(proxy: ChartProxy, bounds: CGRect) -> [CGRect] {
        let clearance: CGFloat = 2.5
        let baseline = proxy.position(forY: 0.0) ?? bounds.height
        var result: [CGRect] = []
        if longPeriod {
            // Block each bucket's full horizontal space up to its stack,
            // conservatively wider than the drawn bar.
            for sample in combined where sample.throughput > 0 {
                guard let first = position(proxy, date: plottedDate(sample.timestamp), height: sample.throughput),
                      let last = proxy.position(forX: usageDate(min(sample.endTimestamp, data.window.range.upperBound)))
                else { continue }
                result.append(CGRect(x: first.x, y: first.y, width: max(0, last - first.x),
                                     height: max(0, baseline - first.y)).insetBy(dx: -clearance, dy: -clearance))
            }
        } else {
            let lanes = Dictionary(grouping: plot.samples) { $0.agent?.rawValue ?? "combined" }
            for lane in lanes.values {
                let points = lane.compactMap { position(proxy, date: plottedDate($0.timestamp), height: $0.throughput) }
                result.append(contentsOf: PeakChipLayout.curveObstacles(points, clearance: clearance))
            }
        }
        let cumulative = combined.compactMap { position(proxy, date: plottedDate($0.timestamp), height: $0.cumulative * scale) }
        result.append(contentsOf: PeakChipLayout.curveObstacles(cumulative, clearance: clearance))
        let hatchWidth = max(2, bounds.width / Double(max(1, combined.count)) * 0.8)
        for sample in fallback {
            guard let point = position(proxy, date: plottedDate(sample.timestamp), height: sample.coarseThroughput) else { continue }
            result.append(CGRect(x: point.x, y: point.y, width: hatchWidth, height: max(0, baseline - point.y))
                .insetBy(dx: -clearance, dy: -clearance))
        }
        for guide in guides {
            for segment in guide.segments {
                guard let start = position(proxy, date: usageDate(segment.start), height: segment.value),
                      let end = position(proxy, date: usageDate(segment.end), height: segment.value) else { continue }
                result.append(contentsOf: PeakChipLayout.curveObstacles([start, end], clearance: clearance))
            }
        }
        if data.recent != nil, let now = proxy.position(forX: usageDate(data.window.range.upperBound)) {
            result.append(CGRect(x: now - clearance, y: 0, width: 2 * clearance, height: bounds.height))
        }
        return result
    }

    private func peakOverlay(proxy: ChartProxy, frame: CGRect) -> some View {
        let peaks = peaks
        let peakByID = Dictionary(uniqueKeysWithValues: peaks.map { ($0.id, $0) })
        let requests = peakRequests(peaks, proxy: proxy)
        let bounds = CGRect(origin: .zero, size: frame.size)
        let plan = PeakChipLayout.place(requests, in: bounds, obstacles: peakObstacles(proxy: proxy, bounds: bounds))
        let shown = Set(plan.placed.map(\.id))
        return ZStack(alignment: .topLeading) {
            ForEach(requests, id: \.id) { point in
                if let peak = peakByID[point.id] {
                    Circle()
                        .fill(peak.agent?.badge.color ?? Color.primary)
                        .frame(width: 4, height: 4)
                        .position(x: frame.minX + point.anchor.x, y: frame.minY + point.anchor.y)
                        .accessibilityHidden(true)
                }
            }
            ForEach(plan.placed) { label in
                if let peak = peakByID[label.id] {
                    peakChip(peak, size: label.frame.size)
                        .position(x: frame.minX + label.frame.midX, y: frame.minY + label.frame.midY)
                }
            }
        }
        .preference(key: PeakOverflowKey.self, value: peaks.filter { !shown.contains($0.id) }.map(\.id))
    }

    private func peakChip(_ peak: UsageCurvePeak, size: CGSize) -> some View {
        let color = peak.agent?.badge.color ?? Color.primary
        return Group {
            if peak.agent == nil {
                Text("Total peak \(axisValue(peak.value)) @ \(plottedDate(peak.timestamp).formatted(clock.hour().minute()))")
            }
            else { Text(axisValue(peak.value)) }
        }
        .font(.caption2.weight(.semibold)).monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.65)
        .padding(.horizontal, 4)
        .frame(width: size.width, height: size.height)
        .foregroundStyle(color)
        .background(.background, in: RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.65)) }
        .accessibilityRepresentation { peakDescription(peak) }
    }

    private func peakDescription(_ peak: UsageCurvePeak) -> some View {
        HStack(spacing: 5) {
            if let agent = peak.agent { Text(agent.title).foregroundStyle(agent.badge.color) }
            else { Text("Total peak") }
            Text(axisValue(peak.value))
            Text(verbatim: plottedDate(peak.timestamp).formatted(clock.month().day().hour().minute()))
        }
        .accessibilityElement(children: .combine)
    }

    private var axisLabel: LocalizedStringResource {
        switch plot.axisUnit {
        case .minute: "Tokens per minute"
        case .hour: "Tokens per hour"
        case .day: "Tokens per day"
        case .bucket: "Tokens per bucket"
        case .costHour: "\(currency.code) per hour"
        case .costDay: "\(currency.code) per day"
        }
    }

    private func axisValue(_ amount: Double) -> String {
        if request.metric == .cost {
            return amount.isFinite ? currency.formattedMicroUSD(Decimal(amount)) : "—"
        }
        return amount.formatted(.number.notation(.compactName))
    }

    private func nowReadout(_ recent: UsageTotals) -> some View {
        HStack(spacing: 8) {
            Text("NOW \(usageDate(data.window.range.upperBound).formatted(clock.hour().minute()))")
            if request.metric == .cost {
                if recent.hasPricedUsage {
                    Text("\(currency.formattedMicroUSD(Decimal(recent.costMicroUSD) * 60)) / h")
                } else { Text("No priced call-level usage") }
            } else {
                Text("\(recent.value(request.metric).formatted()) tok/min")
            }
            if let cumulative = data.cumulative(request.metric) {
                let amount = request.metric == .cost ? currency.formattedMicroUSD(Decimal(cumulative)) : cumulative.formatted()
                Text("Cumulative: \(amount)")
            }
        }
        .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        .accessibilityIdentifier("usage.now")
    }

    private func hoverValues(_ time: Int64) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: usageDate(time).formatted(clock.month().day().hour().minute()))
            ForEach(plot.samples.filter { $0.timestamp == time }) { sample in
                if let agent = sample.agent { Text(agent.title).foregroundStyle(agent.badge.color) }
                else { Text("All agents") }
                if request.metric == .cost, sample.hasUnpricedUsage, !sample.hasPricedUsage {
                    Text("Unpriced")
                } else if request.metric == .cost {
                    Text(axisValue(sample.throughput + sample.coarseThroughput))
                } else {
                    Text(sample.throughput.formatted(.number.precision(.fractionLength(0...1))))
                }
            }
            if request.metric == .cost,
               combined.first(where: { $0.timestamp == time })?.hasUnpricedUsage == true {
                Text("Some usage is unpriced.")
            }
        }
        .font(.caption2).lineLimit(1).foregroundStyle(.secondary)
    }
}

private func usageDate(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
