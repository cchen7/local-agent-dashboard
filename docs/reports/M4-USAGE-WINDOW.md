# M4 usage window primitive (FR-TK-1, SPEC §8.3 / §11.4)

## Scope and baseline

The change adds one pure ADCore source file, one synthetic ADCore test file and
this report. There are no Store, App, adapter, dependency or entitlement changes.
Verification uses synthetic inputs and no desktop tools or installations.

## Exact public API

```swift
public enum UsagePeriod: String, CaseIterable, Sendable {
    case hour, day, week, month, quarter, all, custom
}

public struct UsageRange: Equatable, Sendable {
    public let lowerBound: Int64
    public let upperBound: Int64
    public init(lowerBound: Int64, upperBound: Int64) throws
}

public struct UsageWindow: Equatable, Sendable {
    public enum Bucket: Equatable, Sendable {
        case fixed(milliseconds: Int64)
        case localDay(timeZone: TimeZone)
    }

    public enum Failure: Error, Equatable, Sendable {
        case invalidRange, missingCustomRange, invalidBucketWidth
        case arithmeticOverflow, invalidCalendarDate
    }

    public let range: UsageRange
    public let previous: UsageRange?
    public let bucket: Bucket

    public static func make(
        _ period: UsagePeriod,
        now: Int64,
        firstTimestamp: Int64? = nil,
        custom: UsageRange? = nil,
        timeZone: TimeZone
    ) throws -> UsageWindow

    public static func today(now: Int64, timeZone: TimeZone) throws -> UsageWindow

    public func bucketRange(containing timestamp: Int64) throws -> UsageRange
    public static func bucketStart(_ timestamp: Int64, width: Int64) throws -> Int64
}
```

Coordinator integration note: **`bucketStart` throws**. Its result is mathematical
floor division anchored at Unix epoch zero. A nonpositive width or an origin below
`Int64.min` is an error; it never traps, truncates negative timestamps toward zero,
or saturates to an unaligned boundary. The caller must pass the display zone
to `make`. For daily bars, use `bucketRange(containing:)` for aggregation and
hover lookup; intersect the full bucket with the half-open report range.

## Behavior and proposed integration decisions

- Every boundary is an exact UTC epoch millisecond. Ranges are half-open and are
  never padded or rounded to a bucket boundary. Values are immutable; public range
  construction requires strictly increasing bounds and an Int64-representable
  duration. Only All and Today can internally produce empty ranges, including
  Today's empty comparison at the local day boundary. Passing an empty range
  obtained from either factory to Custom is rejected.
- Hour/day/week/month/quarter are exactly 1/24/168/720/2160 elapsed hours. Their
  comparisons are the immediately preceding equal-length ranges. The first three
  use 1-minute/5-minute/1-hour fixed buckets. Month and quarter use Gregorian days
  in the supplied display time zone, including 23- and 25-hour DST days.
- All spans `[firstTimestamp ?? now, now)` and has `previous == nil`. A missing
  first timestamp, or one equal to now, yields an empty range with a one-minute
  bucket. A future first timestamp is invalid. All does not invent a baseline
  before the available history.
- Custom uses exactly the supplied nonempty range, independent of now. It compares
  the adjacent preceding equal duration. An absent range is an error. Arguments
  not used by the selected period have no effect.
- All/Custom start with a minute-rounded width sufficient for 500 duration-based
  points, then count the actual intersecting epoch-aligned buckets. If partial
  edges cause 501 intersections, a width based on 499 intervals reserves one edge
  point. This is bounded arithmetic, without an unbounded widening loop. An empty
  range has no intersecting buckets. Bucket origins are independent of the range
  lower bound, local time zone and refresh time for a given width.
- Today uses a Gregorian calendar with the supplied time zone and five-minute
  buckets. Its range starts at the first real moment of the local day. The
  previous comparison starts at the preceding real local day's start and covers
  the same elapsed milliseconds, **capped at that day's end** when it was shorter.
  This avoids comparing part of today against itself after a short DST day. This
  cap and the Today bucket choice are explicit integration decisions for review.
- Boundary arithmetic and date-to-Int64 conversions are checked. Window creation
  also rejects a nonempty range whose first aligned bucket origin is not
  representable. It throws if a required previous interval would underflow.

Calendar behavior was checked against Apple's Foundation documentation using the
Context7 skill. Calendar day starts handle missing or repeated midnight:
<https://developer.apple.com/documentation/foundation/calendar/startofday(for:)>
and <https://developer.apple.com/documentation/foundation/calendar/dateinterval(of:for:)>
describe the relevant day-boundary operations. Concrete behavior was also executed
in the synthetic DST tests below.

No agent-file format changed, so `FORMATS.md` is unchanged. Per
`DEVELOPMENT_PLAN.md`, shared SPEC/DECISIONS incorporation remains with the
coordinator; this report records the primitive's explicit semantics.

## Executed verification (2026-11-19)

The task-local harness copies only the worktree's `Sources/ADCore` and
`Tests/ADCoreTests`. Its dependency-free manifest preserves macOS 27, Swift 6
language mode and the production target's strict-concurrency setting. This runs
ADCore without building Store/App or fetching GRDB. The project manifest and
lockfiles are unchanged. Copies were compared byte-for-byte with the worktree
after verification.

The test-first red run exited 1 because `UsagePeriod` did not exist. After adding
the implementation, this exact command exited 0:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$task_scratch/clang-cache" \
swift test \
  --package-path "$task_scratch/harness" \
  --scratch-path "$task_scratch/build" \
  --cache-path "$task_scratch/cache" \
  --config-path "$task_scratch/config" \
  --security-path "$task_scratch/security" \
  --manifest-cache local --disable-sandbox
```

Observed results (Apple Swift 6.4.2 / Xcode 27.2 / arm64):

- **36 ADCore test functions passed**, zero failures or skips; no compiler warnings.
  This includes **20 new UsageWindow functions**, 13 existing synthetic source-reader
  functions and 3 existing contract functions. Several functions are parameterized.
- The tests cover all seven raw period values; exact rolling durations; fixed
  widths; exact half-open boundaries; adjacent previous periods; empty All;
  invalid/future/missing/custom-empty inputs; 500 aligned versus 501 intersecting
  buckets; deterministic automatic widths across negative timestamps and durations
  near Int64 limits; mathematical floor for negative timestamps; invalid widths;
  unrepresentable bucket origins; range and comparison overflow; Shanghai midnight
  and milliseconds; UTC pre-epoch Today; Los Angeles spring/fall DST; shorter-day
  comparison caps; and Sao Paulo's missing midnight.
- `Tools/forbid-apis.sh`: exit 0, 24 production source files inspected.
- `Tools/check-dependencies.sh`: exit 0, GRDB.swift exactly 7.11.1, lockfiles consistent.
- Source/test copy verification and whitespace checks passed.

Test output is `tests.log` in scratch; the expected initial compile failure is
`red.log`. Full-package, Store, App, UI, entitlement/runtime and performance checks
were not run: this assignment is limited to the pure ADCore primitive. There is
no store/chart/menu integration claim.

Review follow-up: 64 package tests passed, including 38 ADCore functions. Both
daily periods are covered on either side of Shanghai midnight and on 23-hour
and 25-hour Los Angeles days, with exact rolling ranges unchanged.
The same suite passed after removing the default. A separate Swift type check
verified that omitting the zone now fails with a missing `timeZone` argument.
