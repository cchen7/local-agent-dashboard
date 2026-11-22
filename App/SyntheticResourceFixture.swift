#if AGENTDASH_SYNTHETIC_ONLY
import ADCore
import ADInsights
import ADStore
import AppKit
import Darwin
import Foundation

/// A large preindexed library, used only by the signed QA bundle.
struct SyntheticResourceFixture: Sendable {
    static let environmentKey = "AGENTDASH_SYNTHETIC_RESOURCES"
    static let current = try? request()
    private static let sessions = 1_000
    private static let eventsPerSession = 1_000
    private static let receiptBytes = Data("1000000 events, 1000 sessions\n".utf8)
    private static let first = SessionKey(agent: .codex, nativeID: "resource-preview-0")
    private static let firstTitle = "Synthetic resource baseline"

    enum Mode: String, Sendable { case prepare, dashboard, menuOnly = "menu-only", cleanup }
    let mode: Mode
    let root: URL
    private var receipt: URL { root.appendingPathComponent("verified-event-count") }
    private var index: URL { root.appendingPathComponent("index.sqlite") }

    static func request() throws -> Self? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard CommandLine.arguments.contains("--synthetic"), parts.count == 2,
              let mode = Mode(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1])) else { throw StoreError.invalidLocation }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDashboard-resources-\(id.uuidString)", isDirectory: true)
        return .init(mode: mode, root: root)
    }

    func openDirectory() throws -> URL {
        switch mode {
        case .prepare:
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        case .dashboard, .menuOnly:
            try verifyPrepared()
        case .cleanup:
            throw StoreError.invalidLocation
        }
        return root
    }

    private func verifyPrepared() throws {
        let files = FileManager.default
        let base = try files.attributesOfItem(atPath: root.path)
        let db = try files.attributesOfItem(atPath: index.path)
        let proof = try files.attributesOfItem(atPath: receipt.path)
        guard base[.type] as? FileAttributeType == .typeDirectory,
              (base[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (base[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              db[.type] as? FileAttributeType == .typeRegular,
              proof[.type] as? FileAttributeType == .typeRegular,
              (proof[.size] as? NSNumber)?.intValue == Self.receiptBytes.count,
              try Data(contentsOf: receipt) == Self.receiptBytes else { throw StoreError.invalidLocation }
    }

    func seed(_ store: AgentStore) async throws {
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: root) } }
        let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic resources",
            rootURL: root.appendingPathComponent("unused-source"), environment: "Synthetic"))
        let dayOld = Int64(Date().timeIntervalSince1970 * 1_000) - 86_400_000
        let decoder = JSONDecoder()
        for row in 0..<Self.sessions {
            guard let line = readLine(), line.utf8.count <= 1_048_576 else { throw StoreError.invalidStoredValue }
            let messages = try decoder.decode([String].self, from: Data(line.utf8))
            guard messages.count == Self.eventsPerSession,
                  messages.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else { throw StoreError.invalidStoredValue }
            let key = row == 0 ? Self.first : SessionKey(agent: .codex, nativeID: "resource-preview-\(row)")
            let time = dayOld - Int64(row) * 3_600_000
            var records: [NormalizedRecord] = [
                .session(.init(key: key, sourceID: source, environment: "Synthetic",
                    cwd: "/synthetic/projects/project-\(row % 40)",
                    title: row == 0 ? Self.firstTitle : "Synthetic session \(row)",
                    startedAt: time - 60_000, lastEventAt: time, status: .completed)),
            ]
            for (i, message) in messages.enumerated() {
                records.append(.event(.init(session: key, sequence: Int64(i), timestamp: time - 60_000 + Int64(i) * 60,
                    kind: i.isMultiple(of: 2) ? .user : .assistant, text: message, dedupeKey: "resource:\(row):\(i)")))
            }
            records.append(.tokens(.init(session: key, timestamp: time, model: "gpt-6.2-sol",
                                counts: .init(inputFresh: 73, cacheRead: 21, output: 31), dedupeKey: "resource:\(row):usage")))
            try store.write(records)
            guard try store.events(in: key).count == Self.eventsPerSession else { throw StoreError.invalidStoredValue }
        }
        guard readLine() == nil else { throw StoreError.invalidStoredValue }
        let topics = try TopicIndexPipeline(store: store)
        _ = try await topics.refresh()
        let status = SessionStatusPipeline(store: store)
        try await status.configure(.default)
        _ = try await status.refresh()
        try Self.receiptBytes.write(to: receipt, options: .withoutOverwriting)
        complete = true
    }

    func matches(_ session: SessionListItem) -> Bool {
        session.id == Self.first && session.title == Self.firstTitle
    }

    @MainActor func transcriptDidDraw(_ window: NSWindow) {
        guard window.isVisible else { return }
        switch mode {
        case .prepare: Self.report("prepared 1000000 events")
        case .dashboard: Self.report("dashboard ready")
        case .menuOnly:
            window.performClose(nil)
            DispatchQueue.main.async {
                let contentWindows = ["dashboardWindow", "settingsWindow", "menuBarPanel"]
                let contentVisible = NSApp.windows.contains { candidate in
                    candidate.isVisible && contentWindows.contains(candidate.accessibilityIdentifier())
                }
                Self.report(window.isVisible || contentVisible ? "close failed" : "menu-only ready")
            }
        case .cleanup: break
        }
    }

    static func runCleanup() -> Int32 {
        do {
            guard let fixture = try request(), fixture.mode == .cleanup else { throw StoreError.invalidLocation }
            try fixture.verifyPrepared()
            try FileManager.default.removeItem(at: fixture.root)
            return EXIT_SUCCESS
        } catch {
            report("cleanup failed")
            return EXIT_FAILURE
        }
    }

    static func report(_ marker: String) {
        FileHandle.standardOutput.write(Data("synthetic-resources: \(marker)\n".utf8))
    }
}
#endif
