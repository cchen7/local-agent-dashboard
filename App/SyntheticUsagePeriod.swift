#if AGENTDASH_SYNTHETIC_ONLY
import ADCore
import ADStore
import AppKit
import Darwin
import Foundation
import QuartzCore
import SwiftUI

struct SyntheticUsagePeriod: Sendable {
    static let environmentKey = "AGENTDASH_SYNTHETIC_USAGE_PERIOD"
    static let current = try? request()
    static var measuring: Bool { current?.metric != nil }
    static let count: Int64 = 1_000_000
    private static let spacing: Int64 = 7_683
    private static let price: Int64 = 37

    enum Mode: String, Sendable { case prepare, tokens, cost, cleanup }
    let mode: Mode
    let root: URL
    var metric: UsageMetric? {
        switch mode {
        case .tokens: .tokens
        case .cost: .cost
        default: nil
        }
    }
    private var receipt: URL { root.appendingPathComponent("verified-usage-origin") }
    private var index: URL { root.appendingPathComponent("index.sqlite") }

    static func request() throws -> Self? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard CommandLine.arguments.contains("--synthetic"), parts.count == 2,
              let mode = Mode(rawValue: String(parts[0])), let id = UUID(uuidString: String(parts[1]))
        else { throw StoreError.invalidLocation }
        return .init(mode: mode, root: FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDashboard-usage-period-\(id.uuidString)", isDirectory: true))
    }

    static func report(_ text: String) {
        FileHandle.standardOutput.write(Data("synthetic-period: \(text)\n".utf8))
    }

    static func runFixtureCommand() -> Int32 {
        do {
            guard let fixture = try request() else { throw StoreError.invalidLocation }
            switch fixture.mode {
            case .prepare:
                try fixture.prepare()
                report("prepared 1000000 token rows")
            case .cleanup:
                _ = try fixture.origin()
                try FileManager.default.removeItem(at: fixture.root)
            case .tokens, .cost: throw StoreError.invalidLocation
            }
            return EXIT_SUCCESS
        } catch {
            report("fixture unavailable")
            return EXIT_FAILURE
        }
    }

    func openMeasurementDirectory() throws -> URL {
        guard metric != nil else { throw StoreError.invalidLocation }
        _ = try origin()
        return root
    }

    func origin() throws -> Int64 {
        let files = FileManager.default
        let directory = try files.attributesOfItem(atPath: root.path)
        let database = try files.attributesOfItem(atPath: index.path)
        let proof = try files.attributesOfItem(atPath: receipt.path)
        guard directory[.type] as? FileAttributeType == .typeDirectory,
              (directory[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (directory[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              database[.type] as? FileAttributeType == .typeRegular,
              proof[.type] as? FileAttributeType == .typeRegular,
              let size = (proof[.size] as? NSNumber)?.intValue, (1...32).contains(size),
              let origin = Int64(try String(contentsOf: receipt, encoding: .utf8)), origin > 0
        else { throw StoreError.invalidLocation }
        return origin
    }

    private func prepare() throws {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? files.removeItem(at: root) } }
        let store = try AgentStore(databaseURL: index)
        let end = Int64(Date().timeIntervalSince1970 * 1_000) - 120_000
        let origin = end - (Self.count - 1) * Self.spacing
        let codex = try store.upsertSource(.init(agent: .codex, label: "Synthetic usage",
            rootURL: root.appendingPathComponent("unused-codex"), environment: "Synthetic"))
        let claude = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic usage",
            rootURL: root.appendingPathComponent("unused-claude"), environment: "Synthetic"))
        let sessions = (0..<2_000).map { row in
            SessionKey(agent: row.isMultiple(of: 2) ? .codex : .claudeCode, nativeID: "period-fixture-\(row)")
        }
        try store.write(sessions.enumerated().map { row, key in
            .session(.init(key: key, sourceID: key.agent == .codex ? codex : claude, environment: "Synthetic",
                           cwd: "/synthetic/projects/project-\(row % 40)", startedAt: origin, status: .completed))
        })
        for offset in stride(from: Int64(0), to: Self.count, by: 2_000) {
            let upper = min(Self.count, offset + 2_000)
            let records = (offset..<upper).map { row -> NormalizedRecord in
                let key = sessions[Int(row % 2_000)]
                return .tokens(.init(session: key, timestamp: origin + row * Self.spacing,
                                     model: key.agent == .codex ? "gpt-6.2-sol" : "claude-haiku-5-5",
                                     counts: .init(inputFresh: 10, cacheRead: 2, output: 3),
                                     precision: row.isMultiple(of: 15) ? .checkpoint : .call,
                                     dedupeKey: "period-fixture:\(row)"))
            }
            try store.write(records)
            if upper.isMultiple(of: 200_000) {
                FileHandle.standardError.write(Data("Synthetic period preparation: \(upper) / \(Self.count) rows\n".utf8))
            }
        }
        let basis = TokenRateBasis(reference: "synthetic-period-basis", bytes: Data([1, 2, 3]))
        var next = Optional(try store.activatePricing { input, _ in
            TokenQuote(microUSD: Self.price, status: input.precision == .call ? .priced : .approximate,
                       basis: basis, cacheSavingsMicroUSD: 3)
        })
        var quoted = 0
        while let cursor = next {
            let batch = try store.backfillUnpriced(cursor, limit: 4_096)
            quoted += batch.priced
            next = batch.next
        }
        guard quoted == Int(Self.count) else { throw StoreError.invalidStoredValue }
        let window = try UsageWindow.make(.all, now: end + 1, firstTimestamp: origin, timeZone: .gmt)
        let totals = try store.usage(window: window).totals
        guard totals.records == Int(Self.count), totals.counts.total == Self.count * 15,
              totals.costMicroUSD == Self.count * Self.price else { throw StoreError.invalidStoredValue }
        try Data(String(origin).utf8).write(to: receipt, options: .withoutOverwriting)
        complete = true
    }

    @MainActor static func configure(_ model: TokenUsageModel) {
        guard let fixture = current, let metric = fixture.metric, let origin = try? fixture.origin() else { return }
        model.usageMetric = metric
        model.usageCustomStart = Date(timeIntervalSince1970: Double(origin + 20 * 86_400_000) / 1_000)
        model.usageCustomEnd = Date(timeIntervalSince1970: Double(origin + 50 * 86_400_000) / 1_000)
    }

    static func verifies(_ report: UsageReport, data: UsageChartSnapshot, origin: Int64) -> Bool {
        func before(_ stamp: Int64) -> Int64 {
            guard stamp > origin else { return 0 }
            let (delta, overflow) = stamp.subtractingReportingOverflow(origin)
            return overflow ? count : min(count, delta / spacing + (delta.isMultiple(of: spacing) ? 0 : 1))
        }
        let range = report.window.range
        let expected = before(range.upperBound) - before(range.lowerBound)
        return expected > 0 && report.totals.records == Int(expected) &&
            report.totals.counts.total == expected * 15 && report.totals.costMicroUSD == expected * price &&
            data.window.range == range &&
            data.cumulative(.tokens) == expected * 15 && data.cumulative(.cost) == expected * price
    }
}

struct SyntheticPeriodChartMarker: Sendable {
    let id: UUID
    let draw: @MainActor @Sendable (NSWindow) -> Void
}

private struct SyntheticPeriodMarkerKey: EnvironmentKey {
    static let defaultValue: SyntheticPeriodChartMarker? = nil
}

extension EnvironmentValues {
    var syntheticPeriodMarker: SyntheticPeriodChartMarker? {
        get { self[SyntheticPeriodMarkerKey.self] }
        set { self[SyntheticPeriodMarkerKey.self] = newValue }
    }
}

@MainActor
final class SyntheticPeriodRun {
    static let shared = SyntheticPeriodRun()
    private enum Phase { case warm, settling, switching, done }
    private var phase = Phase.warm
    private var origin: Int64?
    private let order: [UsagePeriod] = [.hour, .week, .month, .quarter, .all, .custom, .day]
    private var index = 0
    private var began: UInt64 = 0
    private let cycles: Int = {
        guard let value = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_PERIOD_CYCLES"],
              let runs = Int(value), (1...10).contains(runs) else { return 3 }
        return runs
    }()

    func chartDidDraw(model: TokenUsageModel, snapshot: UsagePageSnapshot, data: UsageChartSnapshot, window: NSWindow) {
        guard window.isVisible, let fixture = SyntheticUsagePeriod.current, let metric = fixture.metric else { return }
        let expected: UsagePeriod
        switch phase {
        case .warm: expected = .day
        case .switching: expected = order[index % order.count]
        case .settling, .done: return
        }
        guard model.usagePeriod == expected, snapshot.request.period == expected,
              model.usageMetric == metric, snapshot.request.metric == metric else { return }
        let measured = phase == .switching
        phase = .settling
        window.displayIfNeeded()
        CATransaction.flush()
        let finished = DispatchTime.now().uptimeNanoseconds
        let elapsed = Double(finished - began) / 1_000_000
        if origin == nil { origin = try? fixture.origin() }
        guard let origin, SyntheticUsagePeriod.verifies(snapshot.report, data: data, origin: origin) else {
            phase = .done
            SyntheticUsagePeriod.report("drawn usage did not match the fixture")
            return
        }
        if measured {
            if began <= snapshot.syntheticQueryStart &&
                snapshot.syntheticQueryStart <= snapshot.syntheticPublish && snapshot.syntheticPublish <= finished {
                let queued = Double(snapshot.syntheticQueryStart - began) / 1_000_000
                let draw = Double(finished - snapshot.syntheticPublish) / 1_000_000
                FileHandle.standardError.write(Data(String(format: "usage-native-phase %@ %@ queued=%.1f draw=%.1f\n",
                    metric.rawValue, expected.rawValue, queued, draw).utf8))
            }
            SyntheticUsagePeriod.report(String(format: "drawn %@ %@ %.1f ms, %d rows, query %.1f ms, plot %.1f ms",
                metric.rawValue, expected.rawValue, elapsed, snapshot.report.totals.records,
                snapshot.syntheticQueryMS, snapshot.syntheticPlotMS))
            index += 1
        } else {
            SyntheticUsagePeriod.report("ready \(metric.rawValue)")
        }
        guard index < order.count * cycles else {
            phase = .done
            SyntheticUsagePeriod.report("done")
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard phase == .settling, window.isVisible else { return }
            phase = .switching
            began = DispatchTime.now().uptimeNanoseconds
            model.selectPeriod(order[index % order.count])
        }
    }
}
#endif
