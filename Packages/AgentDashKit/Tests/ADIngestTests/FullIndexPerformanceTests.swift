import ADAdapters
import ADCore
import ADIngest
import ADPricing
import Darwin
import Foundation
import GRDB
import Synchronization
import Testing
@testable import ADStore

@Test("NFR-3/NFR-8: first index and SQLite footprint on the generated corpus",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_FULL_INDEX_CORPUS"] != nil),
      .timeLimit(.minutes(12)))
func firstIndexFromSyntheticCorpus() async throws {
    let corpus = try IndexCorpus.open()
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-full-index-\(UUID().uuidString)")
    let db = temp.appendingPathComponent("index.sqlite")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: db)
    let priceTable = try PriceTable.decode(Data(contentsOf: IndexCorpus.bundledPrices))
    _ = try store.activatePricing(TokenQuoteEngine.make(table: priceTable))

    let serial = ProcessInfo.processInfo.environment["AGENTDASH_FULL_INDEX_SERIAL"] == "1"
    let importStarted = ContinuousClock.now
    let results: [ScanResult]
    if serial {
        results = try await [measure(ClaudeCodeAdapter()), measure(CodexAdapter()), measure(CopilotAdapter())]
    } else {
        // Start each source independently, as the onboarding controller does.
        async let claude = measure(ClaudeCodeAdapter())
        async let codex = measure(CodexAdapter())
        async let copilot = measure(CopilotAdapter())
        results = try await [claude, codex, copilot]
    }
    let elapsed = seconds(importStarted.duration(to: .now))
    for result in results { try verify(result) }
    let totalBytes = results.reduce(0) { $0 + $1.scan.bytesRead }
    let liveBytes = try store.indexStorageBytes()
    let checkpointStarted = ContinuousClock.now
    _ = try await store.databasePool.writeWithoutTransaction { database in
        try database.checkpoint(.truncate)
    }
    let settledSeconds = seconds(checkpointStarted.duration(to: .now))
    let settledBytes = try store.indexStorageBytes()
    let mainFile = try FileManager.default.attributesOfItem(atPath: db.path)
    let mainBytes = try #require((mainFile[.size] as? NSNumber)?.int64Value)
    try store.databasePool.close()
    let throughput = Double(totalBytes) / elapsed / 1_000_000
    let settledRatio = Double(settledBytes) / Double(totalBytes)
    let liveRatio = Double(liveBytes) / Double(totalBytes)
    report(String(format: """
        first-index all supported (%@): %lld/%lld raw bytes in %.3f s (%.2f MB/s); \
        omitted unsupported: %lld bytes
        index: %lld live bytes (%.2f%%), %lld checkpointed bytes (%.2f%%), %lld main bytes; checkpoint %.3f s
        """, serial ? "serial" : "concurrent", totalBytes, corpus.manifest.rawBytes, elapsed, throughput, corpus.manifest.rawBytes - totalBytes,
        liveBytes, liveRatio * 100, settledBytes, settledRatio * 100, mainBytes, settledSeconds))
    #expect(liveBytes >= settledBytes && settledBytes >= mainBytes && mainBytes > 4096)
    if corpus.manifest.profile != "smoke", !serial {
        #expect(throughput >= 50, "Supported inputs must reach the SPEC raw-byte rate")
        #expect(liveRatio <= 0.35, "Count both main SQLite and its live sidecars for the index size")
        #expect(settledRatio <= 0.35)
        if corpus.manifest.profile == "benchmark-native" {
            #expect(totalBytes == 5_000_000_000 && elapsed < 180, "Index all 5 GB in under three minutes")
        }
    }

    @Sendable func measure<A: AgentAdapter>(_ adapter: A) async throws -> ScanResult {
        let agent = A.kind.rawValue
        let expected = try #require(corpus.manifest.agents[agent])
        let root = corpus.root.appendingPathComponent(agent, isDirectory: true)
        try IndexCorpus.requireFileType(root, .typeDirectory)
        let input = Source(agent: A.kind, label: "Synthetic benchmark", rootURL: root)
        let sourceID = try store.upsertSource(input)
        var source = input
        source.id = sourceID
        let done = Mutex<SourceIndexScan?>(nil)
        report("first-index \(agent): starting \(expected.sessions) generated files")
        let started = ContinuousClock.now
        try await JSONLSourceIndexing.run(source: source, authorizedRoot: root, adapter: adapter,
                                          store: store, mode: .fullRescan) { update in
            if case .rescanned(let stats) = update { done.withLock { $0 = stats } }
            if case .scanning(let stats) = update, stats.checkedFiles > 0, stats.checkedFiles.isMultiple(of: 125) {
                report(String(format: "first-index %@: progress %d/%d, %.1f s", agent,
                              stats.checkedFiles, stats.totalFiles, seconds(stats.elapsed)))
            }
        }
        let duration = started.duration(to: .now)
        let scanned = done.withLock { $0 }
        return ScanResult(agent: agent, sourceID: sourceID, scan: try #require(scanned), duration: duration)
    }

    func verify(_ result: ScanResult) throws {
        let expected = try #require(corpus.manifest.agents[result.agent])
        let persisted = try IndexCorpus.verify(store, sourceID: result.sourceID)
        let scan = result.scan
        let duration = seconds(result.duration)
        let rate = Double(scan.bytesRead) / duration / 1_000_000
        report(String(format: """
            first-index %@: %d/%d files, %lld raw records, %lld bytes, %.3f s (%.2f MB/s), \
            %lld priced token rows; failed files %d, unknown records %lld
            """, result.agent, scan.checkedFiles, scan.totalFiles, persisted.records, scan.bytesRead, duration,
            rate, persisted.priced, scan.failedFiles, persisted.unknown))
        #expect(scan.failedFiles == 0 && scan.totalFiles == expected.sessions && scan.checkedFiles == expected.sessions)
        #expect(scan.bytesRead == expected.rawBytes && persisted.offset == expected.rawBytes)
        #expect(persisted.records == expected.records && persisted.sessions == expected.sessions && persisted.unknown == 0)
        #expect(persisted.tokens == expected.expectedTokens)
        #expect(persisted.priced > 0)
    }
}

private struct ScanResult: Sendable {
    let agent: String
    let sourceID: Int64
    let scan: SourceIndexScan
    let duration: Duration
}

private struct IndexCorpus: Sendable {
    struct Manifest: Decodable, Sendable {
        struct Agent: Decodable, Sendable {
            let sessions: Int
            let records: Int64
            let rawBytes: Int64
            let expectedTokens: [String: Int64]
        }
        let schemaVersion: Int
        let profile: String
        let rawBytes: Int64
        let agents: [String: Agent]
    }

    let root: URL
    let manifest: Manifest

    static var bundledPrices: URL {
        // Packages/AgentDashKit/Tests/ADIngestTests/this file
        (0..<5).reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appendingPathComponent("pricing/pricing.json")
    }

    static func requireFileType(_ url: URL, _ type: FileAttributeType) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        try #require(attributes[.type] as? FileAttributeType == type)
    }

    static func open() throws -> Self {
        let name = try #require(ProcessInfo.processInfo.environment["AGENTDASH_FULL_INDEX_CORPUS"])
        let prefix = "agentdash-synth-"
        let suffix = name.dropFirst(prefix.count).utf8
        try #require(name.hasPrefix(prefix) && suffix.count == 32 &&
                     suffix.allSatisfy { (48...57).contains($0) || (97...102).contains($0) })
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        try #require(attributes[.type] as? FileAttributeType == .typeDirectory &&
                     (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() &&
                     (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let file = root.appendingPathComponent("manifest.json")
        try requireFileType(file, .typeRegular)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
        let declaredBytes = ["benchmark": 5_000_000_000 as Int64, "benchmark-native": 5_000_000_000, "smoke": 1_000_000]
        let agents = AgentKind.allCases.filter { manifest.profile != "benchmark-native" || $0 != .grokBuild }
        try #require(manifest.schemaVersion == 1 && declaredBytes[manifest.profile] == manifest.rawBytes)
        try #require(Set(manifest.agents.keys) == Set(agents.map(\.rawValue)))
        try #require(manifest.agents.values.allSatisfy { $0.rawBytes > 0 && $0.rawBytes <= manifest.rawBytes })
        try #require(manifest.agents.values.reduce(0) { $0 + $1.rawBytes } == manifest.rawBytes)
        return .init(root: root, manifest: manifest)
    }

    static func verify(_ store: AgentStore, sourceID: Int64) throws
    -> (sessions: Int, records: Int64, offset: Int64, unknown: Int64, priced: Int64, tokens: [String: Int64]) {
        try store.databasePool.read { db in
            let checkpoints = try Row.fetchOne(db, sql: """
                SELECT sum(last_seq+1), sum(read_offset), sum(unknown_records)
                FROM source_files WHERE source_id=?
                """, arguments: [sourceID])
            let sessions = try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions WHERE source_id=?",
                                            arguments: [sourceID])
            let totals = try Row.fetchOne(db, sql: """
                SELECT sum(input_fresh),sum(cache_read),sum(cache_write),sum(cache_write_1h),sum(output),sum(reasoning),
                       count(*) FILTER (WHERE price_status IN ('priced','approx'))
                FROM token_events JOIN sessions ON sessions.id=token_events.session_id WHERE sessions.source_id=?
                """, arguments: [sourceID])
            let tokens = try #require(totals)
            let cursor = try #require(checkpoints)
            let fields = ["inputFresh", "cacheRead", "cacheWrite", "cacheWrite1h", "output", "reasoning"]
            let counters = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($0.element, tokens[$0.offset] as Int64? ?? 0) })
            return (try #require(sessions), cursor[0] as Int64? ?? 0, cursor[1] as Int64? ?? 0,
                    cursor[2] as Int64? ?? 0, tokens[6], counters)
        }
    }
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private func report(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
