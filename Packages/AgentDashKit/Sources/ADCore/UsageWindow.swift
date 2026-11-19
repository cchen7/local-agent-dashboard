import Foundation

/// FR-TK-1: rolling periods are elapsed durations, not calendar months or quarters.
public enum UsagePeriod: String, CaseIterable, Sendable {
    case hour, day, week, month, quarter, all, custom
}

/// An immutable half-open interval [lowerBound, upperBound), in UTC epoch milliseconds.
/// Empty intervals can only be produced by All without elapsed history or Today at midnight.
public struct UsageRange: Equatable, Sendable {
    /// Inclusive UTC epoch millisecond boundary.
    public let lowerBound: Int64
    /// Exclusive UTC epoch millisecond boundary.
    public let upperBound: Int64

    /// Require increasing bounds and an elapsed duration representable by Int64.
    public init(lowerBound: Int64, upperBound: Int64) throws {
        try self.init(lowerBound: lowerBound, upperBound: upperBound, allowingEmpty: false)
    }

    fileprivate init(lowerBound: Int64, upperBound: Int64, allowingEmpty: Bool) throws {
        guard lowerBound < upperBound || (allowingEmpty && lowerBound == upperBound) else {
            throw UsageWindow.Failure.invalidRange
        }
        let (_, overflow) = upperBound.subtractingReportingOverflow(lowerBound)
        guard !overflow else { throw UsageWindow.Failure.arithmeticOverflow }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    fileprivate var duration: Int64 { upperBound - lowerBound }
}

/// Pure range and chart bucket selection; performs no I/O and never reads the current clock.
public struct UsageWindow: Equatable, Sendable {
    public enum Bucket: Equatable, Sendable {
        /// Epoch-aligned interval with a positive, fixed duration.
        case fixed(milliseconds: Int64)
        /// One Gregorian calendar day in the chart's display time zone.
        case localDay(timeZone: TimeZone)
    }

    /// Invalid inputs or results that cannot be represented without overflow.
    public enum Failure: Error, Equatable, Sendable {
        /// Reversed bounds or an empty range outside the supported All/Today cases.
        case invalidRange
        /// Custom was selected without supplying a range.
        case missingCustomRange
        /// Bucket width must be strictly positive.
        case invalidBucketWidth
        /// A duration, boundary or floored bucket origin does not fit in Int64.
        case arithmeticOverflow
        /// Foundation could not resolve the input to consistent local day boundaries.
        case invalidCalendarDate
    }

    /// Exact requested boundaries, never expanded to fit the chart buckets.
    public let range: UsageRange
    /// Adjacent equal-duration comparison, or nil for All; Today compares elapsed local days.
    public let previous: UsageRange?
    public let bucket: Bucket

    private static let minute: Int64 = 60_000

    /// Make a rolling 1/24/168/720/2160-hour window, All history, or an exact Custom range.
    /// All runs from firstTimestamp (or now if absent) to now and has no comparison.
    /// Custom requires a nonempty range and ignores now. Extra arguments for other periods
    /// are ignored. Supply the display time zone explicitly: 30D/90D use it for
    /// daily chart buckets; fixed-width periods ignore it.
    /// All/Custom select at most 500 intersecting, epoch-aligned buckets.
    public static func make(_ period: UsagePeriod, now: Int64, firstTimestamp: Int64? = nil,
                            custom: UsageRange? = nil, timeZone: TimeZone) throws -> UsageWindow {
        switch period {
        case .hour:
            return try rolling(now: now, duration: 3_600_000, bucket: .fixed(milliseconds: minute))
        case .day:
            return try rolling(now: now, duration: 86_400_000, bucket: .fixed(milliseconds: 300_000))
        case .week:
            return try rolling(now: now, duration: 604_800_000, bucket: .fixed(milliseconds: 3_600_000))
        case .month:
            return try rolling(now: now, duration: 2_592_000_000, bucket: .localDay(timeZone: timeZone))
        case .quarter:
            return try rolling(now: now, duration: 7_776_000_000, bucket: .localDay(timeZone: timeZone))
        case .all:
            let range = try UsageRange(lowerBound: firstTimestamp ?? now, upperBound: now, allowingEmpty: true)
            return try UsageWindow(range: range, previous: nil, bucket: .fixed(milliseconds: automaticBucket(for: range)))
        case .custom:
            guard let custom else { throw Failure.missingCustomRange }
            // An empty All/Today range is still invalid as Custom.
            let range = try UsageRange(lowerBound: custom.lowerBound, upperBound: custom.upperBound)
            return try UsageWindow(range: range, previous: preceding(range),
                                   bucket: .fixed(milliseconds: automaticBucket(for: range)))
        }
    }

    /// Run from the first moment of the supplied local day to now, using five-minute buckets.
    /// Compare the same elapsed milliseconds from the preceding local day's first moment,
    /// capped at that day's end when DST makes it shorter. Both ranges are empty at midnight.
    /// Gregorian calendar calculations use only the supplied time zone, never Calendar.current.
    public static func today(now: Int64, timeZone: TimeZone) throws -> UsageWindow {
        let day = try localDay(containing: now, timeZone: timeZone)
        let start = day.lowerBound
        let previousDay = try localDay(containing: subtract(start, 1), timeZone: timeZone)
        guard previousDay.upperBound == start else { throw Failure.invalidCalendarDate }
        let range = try UsageRange(lowerBound: start, upperBound: now, allowingEmpty: true)
        let previousEnd = try add(previousDay.lowerBound, min(range.duration, previousDay.duration))
        let previous = try UsageRange(lowerBound: previousDay.lowerBound, upperBound: previousEnd, allowingEmpty: true)
        return try UsageWindow(range: range, previous: previous, bucket: .fixed(milliseconds: 300_000))
    }

    /// Full chart bucket containing the timestamp. Intersect this with the exact
    /// report range before aggregation so partial first/last bars do not add events.
    public func bucketRange(containing timestamp: Int64) throws -> UsageRange {
        switch bucket {
        case .fixed(let width):
            let start = try Self.bucketStart(timestamp, width: width)
            return try UsageRange(lowerBound: start, upperBound: Self.add(start, width))
        case .localDay(let timeZone):
            return try Self.localDay(containing: timestamp, timeZone: timeZone)
        }
    }

    /// Floor a UTC epoch millisecond timestamp to a positive-width bucket anchored at epoch 0.
    /// Negative timestamps floor toward negative infinity. Invalid widths or an origin below
    /// Int64.min throw rather than trapping or returning a misaligned, saturated boundary.
    public static func bucketStart(_ timestamp: Int64, width: Int64) throws -> Int64 {
        guard width > 0 else { throw Failure.invalidBucketWidth }
        return try multiply(floorQuotient(timestamp, width: width), width)
    }

    private init(range: UsageRange, previous: UsageRange?, bucket: Bucket) throws {
        if range.duration > 0 {
            switch bucket {
            case .fixed(let width): _ = try Self.bucketStart(range.lowerBound, width: width)
            case .localDay(let timeZone):
                _ = try Self.localDay(containing: range.lowerBound, timeZone: timeZone)
                _ = try Self.localDay(containing: range.upperBound - 1, timeZone: timeZone)
            }
        }
        self.range = range
        self.previous = previous
        self.bucket = bucket
    }

    private static func rolling(now: Int64, duration: Int64, bucket: Bucket) throws -> UsageWindow {
        let range = try UsageRange(lowerBound: subtract(now, duration), upperBound: now)
        return try UsageWindow(range: range, previous: preceding(range), bucket: bucket)
    }

    private static func preceding(_ range: UsageRange) throws -> UsageRange {
        try UsageRange(lowerBound: subtract(range.lowerBound, range.duration), upperBound: range.lowerBound)
    }

    private static func automaticBucket(for range: UsageRange) throws -> Int64 {
        guard range.duration > 0 else { return minute }
        var width = try multiply(ceilingQuotient(ceilingQuotient(range.duration, width: 500), width: minute), minute)
        // A nonaligned range can intersect 501 buckets even when duration / width <= 500.
        let first = floorQuotient(range.lowerBound, width: width)
        let last = floorQuotient(range.upperBound - 1, width: width)
        if try add(subtract(last, first), 1) > 500 {
            // Reserve one point for the partial edges. This bound needs no widening loop.
            width = try multiply(ceilingQuotient(ceilingQuotient(range.duration, width: 499), width: minute), minute)
        }
        return width
    }

    private static func floorQuotient(_ value: Int64, width: Int64) -> Int64 {
        let quotient = value / width
        return value % width < 0 ? quotient - 1 : quotient
    }

    private static func ceilingQuotient(_ value: Int64, width: Int64) -> Int64 {
        value / width + (value % width == 0 ? 0 : 1)
    }

    private static func localDay(containing timestamp: Int64, timeZone: TimeZone) throws -> UsageRange {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        // Calendar day boundaries are whole seconds. Floor before making the
        // Date so the last millisecond cannot round into the following day.
        let date = Date(timeIntervalSince1970: Double(floorQuotient(timestamp, width: 1_000)))
        guard let day = calendar.dateInterval(of: .day, for: date) else { throw Failure.invalidCalendarDate }
        let start = try milliseconds(day.start), end = try milliseconds(day.end)
        guard start <= timestamp, timestamp < end else { throw Failure.invalidCalendarDate }
        return try UsageRange(lowerBound: start, upperBound: end)
    }

    private static func milliseconds(_ date: Date) throws -> Int64 {
        guard let value = Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded()) else {
            throw Failure.arithmeticOverflow
        }
        return value
    }

    private static func add(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw Failure.arithmeticOverflow }
        return value
    }

    private static func subtract(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard !overflow else { throw Failure.arithmeticOverflow }
        return value
    }

    private static func multiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw Failure.arithmeticOverflow }
        return value
    }
}
