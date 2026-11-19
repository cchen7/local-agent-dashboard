import ADCore
import Foundation
import Testing

@Suite("FR-TK-1: exact usage ranges and chart buckets")
private struct UsageWindowTests {
    @Test("The public period raw values are stable and exhaustive")
    func periods() {
        #expect(UsagePeriod.allCases.map(\.rawValue) == [
            "hour", "day", "week", "month", "quarter", "all", "custom"
        ])
        #expect(UsagePeriod(rawValue: "day") == .day)
        #expect(UsagePeriod(rawValue: "today") == nil)
    }

    @Test("Rolling periods use exact elapsed durations and adjacent comparisons",
          arguments: rollingCases)
    func rolling(_ sample: RollingCase) throws {
        let extreme: [Int64] = sample.bucket == nil ? [] : [.max]
        for now in [-1, 0, 1_800_000_123_456] + extreme {
            let window = try UsageWindow.make(sample.period, now: now, timeZone: .gmt)
            #expect(try window.range == UsageRange(lowerBound: now - sample.duration, upperBound: now))
            #expect(try window.previous == UsageRange(lowerBound: now - 2 * sample.duration,
                                                  upperBound: now - sample.duration))
            #expect(window.bucket == (sample.bucket.map { .fixed(milliseconds: $0) } ?? .localDay(timeZone: .gmt)))
        }
    }

    @Test("30D and 90D split at Shanghai midnight without changing either elapsed range",
          arguments: [UsagePeriod.month, .quarter])
    func shanghaiDailyBuckets(_ period: UsagePeriod) throws {
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let midnight = try timestamp("2026-11-18T16:00:00Z")
        let now = try timestamp("2026-11-19T07:12:34Z") + 567
        let window = try UsageWindow.make(period, now: now, timeZone: zone)
        let utc = try UsageWindow.make(period, now: now, timeZone: .gmt)
        #expect(window.range == utc.range)
        #expect(window.previous == utc.previous)
        let before = try window.bucketRange(containing: midnight - 1)
        let after = try window.bucketRange(containing: midnight + 30 * 60_000)
        #expect(try before.lowerBound == timestamp("2026-11-17T16:00:00Z"))
        #expect(before.upperBound == midnight)
        #expect(after.lowerBound == midnight)
        #expect(try after.upperBound == timestamp("2026-11-19T16:00:00Z"))
        #expect(try window.bucketRange(containing: midnight) == after)
    }

    @Test("Daily chart buckets use 23-hour and 25-hour calendar days",
          arguments: [UsagePeriod.month, .quarter])
    func daylightSavingBuckets(_ period: UsagePeriod) throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        for (start, end, hours) in [("2026-03-08T08:00:00Z", "2026-03-09T07:00:00Z", 23),
                                    ("2026-11-01T07:00:00Z", "2026-11-02T08:00:00Z", 25)] {
            let lower = try timestamp(start), upper = try timestamp(end)
            let window = try UsageWindow.make(period, now: upper + 1, timeZone: zone)
            let day = try window.bucketRange(containing: lower)
            #expect(day.lowerBound == lower)
            #expect(day.upperBound == upper)
            #expect(day.upperBound - day.lowerBound == Int64(hours) * 3_600_000)
            #expect(try window.bucketRange(containing: upper - 1) == day)
            #expect(try window.bucketRange(containing: upper).lowerBound == day.upperBound)
        }
    }

    @Test("Ranges preserve exact milliseconds and exclude the upper endpoint")
    func halfOpenRange() throws {
        let window = try UsageWindow.make(.hour, now: 3_600_123, timeZone: .gmt)
        let timestamps: [Int64] = [122, 123, 124, 3_600_122, 3_600_123]
        let included = timestamps.filter { window.range.lowerBound <= $0 && $0 < window.range.upperBound }
        #expect(included == [123, 124, 3_600_122])
    }

    @Test("Public ranges reject empty, reversed and unrepresentable durations")
    func invalidRanges() throws {
        for bounds: (Int64, Int64) in [(0, 0), (1, 0), (.min, .min), (.max, .max)] {
            #expect(throws: UsageWindow.Failure.invalidRange) {
                try UsageRange(lowerBound: bounds.0, upperBound: bounds.1)
            }
        }
        #expect(throws: UsageWindow.Failure.arithmeticOverflow) {
            try UsageRange(lowerBound: .min, upperBound: .max)
        }
        #expect(try UsageRange(lowerBound: .min, upperBound: -1).lowerBound == .min)
        #expect(try UsageRange(lowerBound: 0, upperBound: .max).upperBound == .max)
    }

    @Test("All with no history or history at now is empty, with no comparison")
    func emptyAll() throws {
        for now: Int64 in [.min, -1, 0, 1_800_000_123_456, .max] {
            for first in [nil, Optional(now)] {
                let window = try UsageWindow.make(.all, now: now, firstTimestamp: first, timeZone: .gmt)
                #expect(window.range.lowerBound == now)
                #expect(window.range.upperBound == now)
                #expect(window.previous == nil)
                #expect(window.bucket == .fixed(milliseconds: 60_000))
            }
        }
    }

    @Test("All uses the exact first timestamp, with no invented preceding history")
    func allHistory() throws {
        let window = try UsageWindow.make(.all, now: 12_345_678, firstTimestamp: 123, timeZone: .gmt)
        #expect(try window.range == UsageRange(lowerBound: 123, upperBound: 12_345_678))
        #expect(window.previous == nil)
        #expect(window.bucket == .fixed(milliseconds: 60_000))
        #expect(throws: UsageWindow.Failure.invalidRange) {
            try UsageWindow.make(.all, now: 10, firstTimestamp: 11, timeZone: .gmt)
        }
        #expect(throws: UsageWindow.Failure.arithmeticOverflow) {
            try UsageWindow.make(.all, now: .max, firstTimestamp: .min, timeZone: .gmt)
        }
    }

    @Test("Custom preserves supplied bounds and compares with the adjacent equal duration")
    func customRange() throws {
        for bounds: (Int64, Int64) in [(-123_457, 12_345_678), (123, 10_123), (-10_123, -123)] {
            let range = try UsageRange(lowerBound: bounds.0, upperBound: bounds.1)
            let window = try UsageWindow.make(.custom, now: .min, firstTimestamp: .max, custom: range, timeZone: .gmt)
            #expect(window.range == range)
            #expect(try window.previous == UsageRange(lowerBound: bounds.0 - (bounds.1 - bounds.0),
                                                  upperBound: bounds.0))
        }
    }

    @Test("Custom requires a nonempty range, even when passed an empty All range")
    func missingOrEmptyCustom() throws {
        #expect(throws: UsageWindow.Failure.missingCustomRange) {
            try UsageWindow.make(.custom, now: 0, timeZone: .gmt)
        }
        let empty = try UsageWindow.make(.all, now: 0, timeZone: .gmt).range
        #expect(throws: UsageWindow.Failure.invalidRange) {
            try UsageWindow.make(.custom, now: 0, custom: empty, timeZone: .gmt)
        }
    }

    @Test("Automatic widths count intersecting aligned buckets, including partial edges")
    func alignedBucketLimit() throws {
        let exact = try UsageRange(lowerBound: 0, upperBound: 500 * 60_000)
        let shifted = try UsageRange(lowerBound: 1, upperBound: 500 * 60_000 + 1)
        #expect(try UsageWindow.make(.custom, now: 0, custom: exact, timeZone: .gmt).bucket == .fixed(milliseconds: 60_000))
        #expect(try UsageWindow.make(.custom, now: 0, custom: shifted, timeZone: .gmt).bucket == .fixed(milliseconds: 120_000))
        let negative = try UsageRange(lowerBound: -500 * 60_000, upperBound: 0)
        #expect(try UsageWindow.make(.custom, now: 0, custom: negative, timeZone: .gmt).bucket == .fixed(milliseconds: 60_000))
    }

    @Test("Automatic axes stay deterministic, minute-multiple and within 500 points")
    func automaticAxes() throws {
        let spans: [Int64] = [1, 60_000, 499 * 60_000, 500 * 60_000, 501 * 60_000,
                             86_400_123, 1_000_000 * 60_000, Int64.max - 1_000_000]
        for lower: Int64 in [-120_001, -1, 0, 1, 59_999] {
            for span in spans {
                let window = try UsageWindow.make(.all, now: lower + span, firstTimestamp: lower, timeZone: .gmt)
                guard case .fixed(let width) = window.bucket else {
                    Issue.record("All should use a fixed bucket")
                    continue
                }
                #expect(width >= 60_000)
                #expect(width % 60_000 == 0)
                let first = try UsageWindow.bucketStart(lower, width: width)
                let last = try UsageWindow.bucketStart(lower + span - 1, width: width)
                #expect(last / width - first / width + 1 <= 500)
                #expect(first <= lower)
                #expect(lower - first < width)
                #expect(try UsageWindow.make(.all, now: lower + span, firstTimestamp: lower, timeZone: .gmt) == window)
            }
        }
    }

    @Test("UTC bucket origins remain stable as a window advances")
    func stableAlignment() throws {
        let first = try UsageWindow.make(.all, now: 20_000_123, firstTimestamp: 123, timeZone: .gmt)
        let next = try UsageWindow.make(.all, now: 20_000_124, firstTimestamp: 123, timeZone: .gmt)
        #expect(first.bucket == next.bucket)
        #expect(try first.bucketRange(containing: 19_999_999).lowerBound == 19_980_000)
        #expect(try next.bucketRange(containing: 19_999_999).lowerBound == 19_980_000)
    }

    @Test("Buckets floor toward negative infinity, independent of the window", arguments: bucketCases)
    func floorBuckets(_ sample: BucketCase) throws {
        #expect(try UsageWindow.bucketStart(sample.timestamp, width: sample.width) == sample.expected)
    }

    @Test("Invalid widths and unrepresentable floor origins throw without trapping")
    func bucketErrors() throws {
        for width: Int64 in [0, -1, .min] {
            #expect(throws: UsageWindow.Failure.invalidBucketWidth) {
                try UsageWindow.bucketStart(0, width: width)
            }
        }
        for width: Int64 in [3, 60_000, .max] {
            #expect(throws: UsageWindow.Failure.arithmeticOverflow) {
                try UsageWindow.bucketStart(.min, width: width)
            }
        }
    }

    @Test("Current or previous range underflow throws, including custom comparisons",
          arguments: rollingCases)
    func windowOverflow(_ sample: RollingCase) throws {
        for now in [Int64.min, Int64.min + sample.duration] {
            #expect(throws: UsageWindow.Failure.arithmeticOverflow) {
                try UsageWindow.make(sample.period, now: now, timeZone: .gmt)
            }
        }
        let range = try UsageRange(lowerBound: .min, upperBound: Int64.min + 1)
        #expect(throws: UsageWindow.Failure.arithmeticOverflow) {
            try UsageWindow.make(.custom, now: 0, custom: range, timeZone: .gmt)
        }
    }

    @Test("Today uses supplied local midnight and exact elapsed milliseconds")
    func localToday() throws {
        let zone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try timestamp("2026-11-19T07:12:34Z") + 567
        let window = try UsageWindow.today(now: now, timeZone: zone)
        #expect(try window.range == UsageRange(lowerBound: timestamp("2026-11-18T16:00:00Z"), upperBound: now))
        #expect(try window.previous == UsageRange(lowerBound: timestamp("2026-11-17T16:00:00Z"),
                                              upperBound: timestamp("2026-11-18T07:12:34Z") + 567))
        #expect(window.bucket == .fixed(milliseconds: 300_000))
        #expect(try window.range != UsageWindow.make(.day, now: now, timeZone: .gmt).range)
    }

    @Test("Today at local midnight has empty current and comparison ranges")
    func emptyToday() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 8 * 3_600))
        let now = try timestamp("2026-11-18T16:00:00Z")
        let window = try UsageWindow.today(now: now, timeZone: zone)
        #expect(window.range.lowerBound == now)
        #expect(window.range.upperBound == now)
        let previous = try #require(window.previous)
        #expect(try previous.lowerBound == timestamp("2026-11-17T16:00:00Z"))
        #expect(previous.lowerBound == previous.upperBound)
    }

    @Test("Spring and fall DST compare elapsed time from each local midnight",
          arguments: dstCases)
    func daylightSaving(_ sample: DayCase) throws {
        let zone = try #require(TimeZone(identifier: sample.zone))
        let window = try UsageWindow.today(now: timestamp(sample.now), timeZone: zone)
        #expect(try window.range.lowerBound == timestamp(sample.start))
        #expect(try window.range.upperBound == timestamp(sample.now))
        #expect(try window.previous == UsageRange(lowerBound: timestamp(sample.previousStart),
                                              upperBound: timestamp(sample.previousEnd)))
    }

    @Test("A comparison cannot run beyond the previous local day's end",
          arguments: shortDayCases)
    func cappedPreviousDay(_ sample: DayCase) throws {
        try daylightSaving(sample)
    }

    @Test("Today preserves a pre-epoch final millisecond")
    func preEpochToday() throws {
        let zone = try #require(TimeZone(secondsFromGMT: 0))
        let window = try UsageWindow.today(now: -1, timeZone: zone)
        #expect(try window.range == UsageRange(lowerBound: -86_400_000, upperBound: -1))
        #expect(try window.previous == UsageRange(lowerBound: -172_800_000, upperBound: -86_400_001))
    }

    @Test("Unrepresentable calendar dates fail without integer conversion traps")
    func calendarOverflow() {
        for now: Int64 in [.min, .max] {
            #expect(throws: UsageWindow.Failure.self) {
                try UsageWindow.today(now: now, timeZone: .gmt)
            }
        }
    }
}

private struct RollingCase: Sendable {
    let period: UsagePeriod
    let duration: Int64
    let bucket: Int64?
}

private let rollingCases = [
    RollingCase(period: .hour, duration: 3_600_000, bucket: 60_000),
    RollingCase(period: .day, duration: 86_400_000, bucket: 300_000),
    RollingCase(period: .week, duration: 604_800_000, bucket: 3_600_000),
    RollingCase(period: .month, duration: 2_592_000_000, bucket: nil),
    RollingCase(period: .quarter, duration: 7_776_000_000, bucket: nil)
]

private struct BucketCase: Sendable {
    let timestamp: Int64
    let width: Int64
    let expected: Int64
}

private let bucketCases = [
    BucketCase(timestamp: 60_001, width: 60_000, expected: 60_000),
    BucketCase(timestamp: 60_000, width: 60_000, expected: 60_000),
    BucketCase(timestamp: 59_999, width: 60_000, expected: 0),
    BucketCase(timestamp: 0, width: 60_000, expected: 0),
    BucketCase(timestamp: -1, width: 60_000, expected: -60_000),
    BucketCase(timestamp: -60_000, width: 60_000, expected: -60_000),
    BucketCase(timestamp: -60_001, width: 60_000, expected: -120_000),
    BucketCase(timestamp: -8, width: 7, expected: -14),
    BucketCase(timestamp: .min, width: 1, expected: .min),
    BucketCase(timestamp: .min, width: 2, expected: .min),
    BucketCase(timestamp: Int64.min + 1, width: 2, expected: .min),
    BucketCase(timestamp: .max, width: 1, expected: .max),
    BucketCase(timestamp: .max, width: .max, expected: .max),
    BucketCase(timestamp: Int64.max - 1, width: .max, expected: 0),
    BucketCase(timestamp: -1, width: .max, expected: -Int64.max)
]

private struct DayCase: Sendable {
    let zone: String
    let now: String
    let start: String
    let previousStart: String
    let previousEnd: String
}

private let dstCases = [
    DayCase(zone: "America/Los_Angeles", now: "2026-03-08T19:00:00Z", start: "2026-03-08T08:00:00Z",
            previousStart: "2026-03-07T08:00:00Z", previousEnd: "2026-03-07T19:00:00Z"),
    DayCase(zone: "America/Los_Angeles", now: "2026-11-01T20:00:00Z", start: "2026-11-01T07:00:00Z",
            previousStart: "2026-10-31T07:00:00Z", previousEnd: "2026-10-31T20:00:00Z"),
    DayCase(zone: "America/Sao_Paulo", now: "2018-11-04T15:00:00Z", start: "2018-11-04T03:00:00Z",
            previousStart: "2018-11-03T03:00:00Z", previousEnd: "2018-11-03T15:00:00Z")
]

private let shortDayCases = [
    DayCase(zone: "America/Los_Angeles", now: "2026-03-10T06:30:00Z", start: "2026-03-09T07:00:00Z",
            previousStart: "2026-03-08T08:00:00Z", previousEnd: "2026-03-09T07:00:00Z"),
    DayCase(zone: "America/Los_Angeles", now: "2026-11-02T07:30:00Z", start: "2026-11-01T07:00:00Z",
            previousStart: "2026-10-31T07:00:00Z", previousEnd: "2026-11-01T07:00:00Z")
]

private func timestamp(_ value: String) throws -> Int64 {
    let date = try #require(ISO8601DateFormatter().date(from: value))
    return try #require(Int64(exactly: (date.timeIntervalSince1970 * 1_000).rounded()))
}
