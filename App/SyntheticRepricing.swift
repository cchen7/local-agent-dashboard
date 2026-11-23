#if AGENTDASH_SYNTHETIC_ONLY
import ADCore
import ADStore
import AppKit
import Darwin
import Foundation

struct SyntheticRepricing: Sendable {
    static let environmentKey = "AGENTDASH_SYNTHETIC_REPRICE"
    static let current = try? request()
    static var measuring: Bool { current?.mode == .measure }

    enum Mode: String, Sendable { case install, measure, change, cleanup }
    let mode: Mode
    let root: URL
    var priceDirectory: URL { root.appendingPathComponent("prices", isDirectory: true) }
    private var index: URL { root.appendingPathComponent("index.sqlite") }
    private var receipt: URL { root.appendingPathComponent("proof.json") }

    struct Proof: Codable, Sendable {
        let records: Int
        let tokens: Int64
        let unpriced: Int64
        let before: Int64
        let after: Int64
        let origin: Int64
        let bytes: Int64

        var valid: Bool {
            records == 1_000_001 && tokens > 0 && unpriced == tokens - 3 &&
                before == 19 && after > before && (1...(Int64.max - 100_000_001)).contains(origin) &&
                (4_096...1_500_000_000).contains(bytes)
        }

        func contains(_ totals: UsageTotals) -> Bool { totals.records == records && totals.counts.total == tokens }
    }

    static func request() throws -> Self? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard CommandLine.arguments.contains("--synthetic"), parts.count == 2,
              let mode = Mode(rawValue: String(parts[0])), let id = UUID(uuidString: String(parts[1]))
        else { throw StoreError.invalidLocation }
        return .init(mode: mode, root: FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDashboard-native-reprice-\(id.uuidString)", isDirectory: true))
    }

    static func report(_ value: String) {
        FileHandle.standardOutput.write(Data("synthetic-reprice: \(value)\n".utf8))
    }

    static func runFixtureCommand() -> Int32 {
        do {
            guard let fixture = try request() else { throw StoreError.invalidLocation }
            switch fixture.mode {
            case .install:
                try fixture.install()
                report("installed 1000000 eligible rows")
            case .change:
                try fixture.change()
                report("changed \(DispatchTime.now().uptimeNanoseconds)")
            case .cleanup:
                _ = try fixture.proof()
                try FileManager.default.removeItem(at: fixture.root)
            case .measure: throw StoreError.invalidLocation
            }
            return EXIT_SUCCESS
        } catch {
            report("fixture unavailable")
            return EXIT_FAILURE
        }
    }

    func openMeasurementDirectory() throws -> URL {
        guard mode == .measure else { throw StoreError.invalidLocation }
        _ = try proof()
        return root
    }

    func proof() throws -> Proof {
        let files = FileManager.default
        let folder = try files.attributesOfItem(atPath: root.path)
        let db = try files.attributesOfItem(atPath: index.path)
        let metadata = try files.attributesOfItem(atPath: receipt.path)
        let prices = try files.attributesOfItem(atPath: priceDirectory.path)
        guard folder[.type] as? FileAttributeType == .typeDirectory,
              (folder[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (folder[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              db[.type] as? FileAttributeType == .typeRegular,
              prices[.type] as? FileAttributeType == .typeDirectory,
              metadata[.type] as? FileAttributeType == .typeRegular,
              let size = (metadata[.size] as? NSNumber)?.intValue, (1...1_024).contains(size)
        else { throw StoreError.invalidLocation }
        let proof = try JSONDecoder().decode(Proof.self, from: Data(contentsOf: receipt))
        guard proof.valid else { throw StoreError.invalidStoredValue }
        return proof
    }

    private func install() throws {
        var stage = "proof"
        do {
            guard let raw = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_REPRICE_PROOF"],
                  raw.utf8.count <= 1_024 else { throw StoreError.invalidStoredValue }
            let proof = try JSONDecoder().decode(Proof.self, from: Data(raw.utf8))
            guard proof.valid else { throw StoreError.invalidStoredValue }
            stage = "directory"
            let files = FileManager.default
            try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            var complete = false
            defer { if !complete { try? files.removeItem(at: root) } }
            try files.createDirectory(at: priceDirectory, withIntermediateDirectories: false)
            guard files.createFile(atPath: index.path, contents: nil) else { throw StoreError.invalidLocation }
            stage = "transfer"
            let output = try FileHandle(forWritingTo: index)
            var written: Int64 = 0
            do {
                defer { try? output.close() }
                while let chunk = try FileHandle.standardInput.read(upToCount: 262_144), !chunk.isEmpty {
                    if written == 0 && !chunk.starts(with: Data("SQLite format 3\0".utf8)) {
                        throw StoreError.invalidStoredValue
                    }
                    written += Int64(chunk.count)
                    guard written <= proof.bytes else { throw StoreError.invalidStoredValue }
                    try output.write(contentsOf: chunk)
                }
            }
            guard written == proof.bytes else { throw StoreError.invalidStoredValue }
            stage = "index"
            let store = try AgentStore(databaseURL: index)
            let week = try UsageWindow.make(.week, now: proof.origin + 100_000_001, timeZone: .gmt)
            stage = "report"
            let totals = try store.usage(window: week).totals
            guard proof.contains(totals), totals.unpricedTokens == proof.unpriced, totals.costMicroUSD == proof.before
            else { throw StoreError.invalidStoredValue }
            stage = "receipt"
            try JSONEncoder().encode(proof).write(to: receipt, options: .withoutOverwriting)
            complete = true
        } catch {
            let failure = error as NSError
            Self.report("install failed at \(stage) (domain \(failure.domain), code \(failure.code))")
            throw error
        }
    }

    private func change() throws {
        _ = try proof()
        let table = """
            {"schemaVersion":1,"currency":"USD","unit":"per_million_tokens","updatedAt":"2026-11-19","models":[
              {"id":"synthetic-primary","vendor":"synthetic","displayName":"Primary","prices":[
                {"effectiveFrom":"2020-01-01","input":5,"output":5,"cacheRead":1,"source":"https://example.invalid/synthetic","checkedAt":"2026-11-19"}]},
              {"id":"synthetic-added","vendor":"synthetic","displayName":"Added","prices":[
                {"effectiveFrom":"2020-01-01","input":3,"output":3,"cacheRead":1,"source":"https://example.invalid/synthetic","checkedAt":"2026-11-19"}]},
              {"id":"synthetic-history","vendor":"synthetic","displayName":"History","prices":[
                {"effectiveFrom":"2020-01-01","input":99,"output":99,"source":"https://example.invalid/synthetic","checkedAt":"2026-11-19"}]}
            ]}
            """
        try Data(table.utf8).write(to: priceDirectory.appendingPathComponent("pricing.json"), options: .atomic)
    }
}

@MainActor
final class SyntheticRepricingRun {
    static let shared = SyntheticRepricingRun()
    private enum Stage { case waiting, ready, between, switching, settling, done }
    private var stage = Stage.waiting
    private var watching = false
    private weak var model: TokenUsageModel?
    private weak var window: NSWindow?
    private var proof: SyntheticRepricing.Proof?
    private var interaction = 0
    private var actionTime: UInt64 = 0
    private var finalChartSeen = false
    private var reportedPendingChart = false

    func watcherDidStart() {
        watching = true
        reportReadyIfPossible()
    }

    private func reportReadyIfPossible() {
        guard stage == .waiting, watching, model != nil else { return }
        stage = .ready
        SyntheticRepricing.report("ready")
    }

    func sweepStarted() {
        guard stage == .ready else { return }
        SyntheticRepricing.report("sweep-start \(DispatchTime.now().uptimeNanoseconds)")
        stage = .between
        scheduleSwitch(after: .milliseconds(250))
    }

    func sweepFinished(failed: Bool) {
        guard stage == .between || stage == .switching else { return }
        let finished = DispatchTime.now().uptimeNanoseconds
        guard !failed, interaction == 2 else { return fail("sweep ended without two visible interactions") }
        stage = .settling
        SyntheticRepricing.report("sweep-done \(finished)")
        reportFinalIfPossible()
    }

    func chartDidDraw(model: TokenUsageModel, snapshot: UsagePageSnapshot, data: UsageChartSnapshot, window: NSWindow) {
        guard stage != .done, window.isVisible, snapshot.request.period == model.usagePeriod,
              snapshot.report.window.range == data.window.range
        else { return }
        if proof == nil { proof = try? SyntheticRepricing.current?.proof() }
        guard let proof, proof.contains(snapshot.report.totals), data.cumulative(.tokens) == proof.tokens
        else { return fail("drawn usage disagrees with the fixture") }
        let totals = snapshot.report.totals
        switch stage {
        case .waiting:
            guard totals.unpricedTokens == proof.unpriced && totals.costMicroUSD == proof.before
            else { return fail("usage was already repriced before the change") }
            self.model = model
            self.window = window
            reportReadyIfPossible()
        case .switching:
            guard model.pricing.backfilling else { return }
            guard (proof.before...proof.after).contains(totals.costMicroUSD) else { return fail("invalid in-flight cost") }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - actionTime) / 1_000_000
            SyntheticRepricing.report(String(format: "interaction %@ %.1f ms", snapshot.request.period.rawValue, elapsed))
            interaction += 1
            stage = .between
            if interaction < 2 { scheduleSwitch(after: .milliseconds(400)) }
        case .ready, .between, .settling, .done: break
        }
        finalChartSeen = totals.unpricedTokens == 0 && totals.costMicroUSD == proof.after &&
            data.cumulative(.cost) == proof.after
        if stage == .settling, !finalChartSeen, !reportedPendingChart {
            reportedPendingChart = true
            SyntheticRepricing.report("chart pending \(totals.unpricedTokens) unpriced, \(totals.costMicroUSD) microdollars")
        }
        reportFinalIfPossible()
    }

    private func scheduleSwitch(after delay: Duration) {
        Task {
            try? await Task.sleep(for: delay)
            guard stage == .between, let model, let window, window.isVisible, model.pricing.backfilling else {
                if stage != .done { fail("foreground window or sweep unavailable") }
                return
            }
            stage = .switching
            actionTime = DispatchTime.now().uptimeNanoseconds
            model.selectPeriod(interaction == 0 ? .month : .quarter)
        }
    }

    private func reportFinalIfPossible() {
        guard stage == .settling, finalChartSeen else { return }
        stage = .done
        SyntheticRepricing.report("final-chart \(DispatchTime.now().uptimeNanoseconds)")
    }

    private func fail(_ reason: String) {
        stage = .done
        SyntheticRepricing.report(reason)
    }
}
#endif
