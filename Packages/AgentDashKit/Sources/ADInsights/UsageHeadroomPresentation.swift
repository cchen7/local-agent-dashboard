import ADCore
import ADStore

public struct ManualUsageHeadroom: Equatable, Sendable {
    public let agent: AgentKind
    public let tokensPerMinute: Int64
    public let limit: Int64
    public var remaining: Double { max(0, 1 - Double(tokensPerMinute) / Double(limit)) }
    public var overRedline: Bool { tokensPerMinute > limit }
}

public enum UsageHeadroomDisplay: Equatable, Sendable {
    case codex([UsageHeadroom], otherAgents: ManualUsageHeadroom?)
    case manual(ManualUsageHeadroom)
    case noRecentUsage
    case notSet
}

public func usageHeadroom(readings: UsageLimitReadings, limits: [AgentKind: Int64],
                          agent selected: AgentKind? = nil) -> UsageHeadroomDisplay {
    let activeCodex = selected == nil || selected == .codex ? readings.codex : []
    let enabled = limits.filter {
        $0.value > 0 && (selected == nil || selected == $0.key) && (activeCodex.isEmpty || $0.key != .codex)
    }
    let lead = readings.throughput.compactMap { sample -> ManualUsageHeadroom? in
        guard let limit = enabled[sample.agent], sample.tokensPerMinute > 0 else { return nil }
        return ManualUsageHeadroom(agent: sample.agent, tokensPerMinute: sample.tokensPerMinute, limit: limit)
    }.sorted {
        if $0.tokensPerMinute != $1.tokensPerMinute { return $0.tokensPerMinute > $1.tokensPerMinute }
        if $0.remaining != $1.remaining { return $0.remaining < $1.remaining }
        return $0.agent.rawValue < $1.agent.rawValue
    }.first
    if !activeCodex.isEmpty { return .codex(activeCodex, otherAgents: lead) }
    if let lead { return .manual(lead) }
    return enabled.isEmpty ? .notSet : .noRecentUsage
}

public struct UsageRedlineGuide: Identifiable, Equatable, Sendable {
    public struct Segment: Identifiable, Equatable, Sendable {
        public let start: Int64
        public let end: Int64
        public let value: Double
        public var id: Int64 { start }
    }

    public let agent: AgentKind
    public let limit: Int64
    public let segments: [Segment]
    public var id: AgentKind { agent }

    /// Rates use the plotted unit. Bucket totals use their actual covered
    /// duration, including partial edges and 23/25-hour local days.
    public static func make(limits: [AgentKind: Int64], agent selected: AgentKind?,
                            window: UsageWindow, unit: UsagePlot.AxisUnit) -> [Self] {
        let durations: [(start: Int64, end: Int64, minutes: Double)]
        guard window.range.lowerBound < window.range.upperBound else { return [] }
        switch unit {
        case .minute, .hour:
            durations = [(window.range.lowerBound, window.range.upperBound, unit == .hour ? 60 : 1)]
        case .day, .bucket:
            guard let buckets = try? window.chartBuckets() else { return [] }
            durations = buckets.map { bucket in
                let start = max(bucket.lowerBound, window.range.lowerBound)
                let end = min(bucket.upperBound, window.range.upperBound)
                return (start, end, Double(end - start) / 60_000)
            }
        case .costHour, .costDay: return []
        }
        return AgentKind.allCases.compactMap { agent in
            guard selected == nil || selected == agent, let limit = limits[agent], limit > 0 else { return nil }
            var segments: [Segment] = []
            for entry in durations {
                let value = Double(limit) * entry.minutes
                if let previous = segments.last, previous.value == value, previous.end == entry.start {
                    segments[segments.count - 1] = Segment(start: previous.start, end: entry.end, value: value)
                } else {
                    segments.append(Segment(start: entry.start, end: entry.end, value: value))
                }
            }
            return Self(agent: agent, limit: limit, segments: segments)
        }
    }
}
