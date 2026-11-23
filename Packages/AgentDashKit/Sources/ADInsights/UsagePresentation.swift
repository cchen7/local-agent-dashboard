import ADCore
import ADStore
import Foundation

public struct UsageDisplaySample: Identifiable, Equatable, Sendable {
    public let timestamp: Int64
    public let endTimestamp: Int64
    public let agent: AgentKind?
    public let throughput: Double
    public let coarseThroughput: Double
    public let hasPricedUsage: Bool
    public let hasUnpricedUsage: Bool
    /// Combined cumulative usage includes all precision lanes.
    public let cumulative: Double
    public var id: String { "\(agent?.rawValue ?? "combined"):\(timestamp)" }
}

public struct UsagePlot: Equatable, Sendable {
    public enum AxisUnit: Sendable { case minute, hour, day, bucket, costHour, costDay }
    public let samples: [UsageDisplaySample]
    public let axisUnit: AxisUnit
    public let maxThroughput: Double
    public let maxCumulative: Double
    public let rebuiltBucketCount: Int
    private let chartID: UUID
    private let period: UsagePeriod
    private let metric: UsageMetric
    private let divisor: Double
    private let agents: [AgentKind]
    private let rendered: [Int64: RenderedBucket]

    private struct RenderedBucket: Sendable {
        let neighbors: [Int64]
        let lanes: [UsageDisplaySample]
        let subtotal: Double
    }

    public static func == (lhs: UsagePlot, rhs: UsagePlot) -> Bool {
        lhs.samples == rhs.samples && lhs.axisUnit == rhs.axisUnit
            && lhs.maxThroughput == rhs.maxThroughput && lhs.maxCumulative == rhs.maxCumulative
    }

    public init(report: UsageReport, period: UsagePeriod, metric: UsageMetric, reusing base: UsagePlot? = nil) {
        self.init(chart: report.chart, period: period, metric: metric, reusing: base)
    }

    public init(chart: UsageChartSnapshot, period: UsagePeriod, metric: UsageMetric, reusing base: UsagePlot? = nil) {
        self.chartID = chart.id
        self.period = period
        self.metric = metric
        let window = chart.window
        let divisor: Double
        let fixedWidth: Int64
        if case .fixed(let width) = window.bucket { fixedWidth = width }
        else { fixedWidth = 0 }
        if metric == .cost {
            switch window.bucket {
            case .localDay: axisUnit = .costDay; divisor = 1
            case .fixed:
                // Long automatic windows report a daily rate even if their
                // 500-point budget chooses a sub-day sampling bucket.
                let elapsed = window.range.upperBound - window.range.lowerBound
                let daily = elapsed >= 30 * 86_400_000
                axisUnit = daily ? .costDay : .costHour
                divisor = Double(fixedWidth) / (daily ? 86_400_000 : 3_600_000)
            }
        } else {
            switch period {
            case .hour, .day: axisUnit = .minute; divisor = Double(fixedWidth) / 60_000
            case .week: axisUnit = .hour; divisor = Double(fixedWidth) / 3_600_000
            case .month, .quarter: axisUnit = .day; divisor = 1
            case .all, .custom: axisUnit = .bucket; divisor = 1
            }
        }
        self.divisor = divisor
        let agents = Set(chart.points.map(\.agent)).sorted { $0.rawValue < $1.rawValue }
        self.agents = agents
        guard !chart.points.isEmpty, divisor > 0, let buckets = try? window.chartBuckets() else {
            samples = []; rendered = [:]; rebuiltBucketCount = 0; maxThroughput = 0; maxCumulative = 0; return
        }
        let previous: UsagePlot? = base.flatMap { value in
            value.chartID == chart.reusedFrom && value.period == period && value.metric == metric
                && value.divisor == divisor && value.agents == agents ? value : nil
        }
        var known: [Int64: RenderedBucket] = [:]
        var neighbors: [Int64: [Int64]] = [:]
        var inputs: Set<Int64> = []
        for (index, bucket) in buckets.enumerated() {
            let first = period == .hour ? max(0, index - 2) : index
            let keys = buckets[first...index].map(\.lowerBound)
            neighbors[bucket.lowerBound] = keys
            if let rendered = previous?.rendered[bucket.lowerBound],
               rendered.neighbors == keys && keys.allSatisfy({ chart.reusedBuckets.contains($0) }) {
                known[bucket.lowerBound] = rendered
            } else {
                inputs.formUnion(keys)
            }
        }
        var precise: [AgentKind: [Int64: Double]] = [:]
        var coarse: [AgentKind: [Int64: Double]] = [:]
        var priced: [AgentKind: Set<Int64>] = [:]
        var unpriced: [AgentKind: Set<Int64>] = [:]
        for point in chart.points where inputs.contains(point.timestamp) {
            if point.coarse { coarse[point.agent, default: [:]][point.timestamp, default: 0] += Double(point.totals.value(metric)) }
            else { precise[point.agent, default: [:]][point.timestamp, default: 0] += Double(point.totals.value(metric)) }
            if metric == .cost {
                if point.totals.hasPricedUsage { priced[point.agent, default: []].insert(point.timestamp) }
                if point.totals.unpricedTokens > 0 { unpriced[point.agent, default: []].insert(point.timestamp) }
            }
        }
        var result: [UsageDisplaySample] = []
        var running: Double = 0
        var maximum: Double = 0
        var rebuilt = 0
        for bucket in buckets {
            let time = bucket.lowerBound
            let band: RenderedBucket
            if let prior = known[time] {
                band = prior
            } else {
                let keys = neighbors[time] ?? [time]
                var combined: Double = 0, wide: Double = 0, subtotal: Double = 0
                var anyPriced = false, anyUnpriced = false
                var lanes: [UsageDisplaySample] = []
                for agent in agents {
                    let raw = precise[agent]?[time] ?? 0
                    let fallback = coarse[agent]?[time] ?? 0
                    let sum = keys.reduce(0.0) { $0 + (precise[agent]?[$1] ?? 0) }
                    let smoothed = sum / Double(keys.count) / divisor
                    let hasPrice = priced[agent]?.contains(time) == true
                    let unknown = unpriced[agent]?.contains(time) == true
                    lanes.append(.init(timestamp: time, endTimestamp: bucket.upperBound, agent: agent,
                                       throughput: smoothed, coarseThroughput: fallback / divisor,
                                       hasPricedUsage: hasPrice, hasUnpricedUsage: unknown, cumulative: 0))
                    anyPriced = anyPriced || hasPrice
                    anyUnpriced = anyUnpriced || unknown
                    combined += smoothed; wide += fallback / divisor; subtotal += raw + fallback
                }
                lanes.append(.init(timestamp: time, endTimestamp: bucket.upperBound, agent: nil,
                                   throughput: combined, coarseThroughput: wide,
                                   hasPricedUsage: anyPriced, hasUnpricedUsage: anyUnpriced, cumulative: 0))
                band = RenderedBucket(neighbors: keys, lanes: lanes, subtotal: subtotal)
                known[time] = band
                rebuilt += 1
            }
            running += band.subtotal
            result.append(contentsOf: band.lanes.dropLast())
            if let combined = band.lanes.last {
                // Prefix totals rebase when an expired head bucket leaves
                // the rolling range; clean throughput lanes stay as-is.
                result.append(.init(timestamp: time, endTimestamp: combined.endTimestamp, agent: nil,
                                    throughput: combined.throughput, coarseThroughput: combined.coarseThroughput,
                                    hasPricedUsage: combined.hasPricedUsage, hasUnpricedUsage: combined.hasUnpricedUsage,
                                    cumulative: running))
                maximum = max(maximum, combined.throughput, combined.coarseThroughput)
            }
        }
        samples = result
        rendered = known
        rebuiltBucketCount = rebuilt
        maxThroughput = maximum
        maxCumulative = running
    }
}
