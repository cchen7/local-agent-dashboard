#if AGENTDASH_SYNTHETIC_ONLY
import ADCore
import ADStore
import Darwin
import Foundation

struct SyntheticLiveUpdateFixture: Sendable {
    static let environmentKey = "AGENTDASH_SYNTHETIC_LIVE_UPDATE"
    static let current = try? request()
    private static let existingID = "00000000-0000-4000-8000-000000000041"
    private static let newID = "00000000-0000-4000-8000-000000000042"
    private static let appendedTitle = "追加合成消息"
    private static let newTitle = "新建合成会话"
    private static let workspace = "/synthetic/live-update"

    let agent: AgentKind
    let root: URL

    static func request() throws -> Self? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard CommandLine.arguments.contains("--synthetic"), parts.count == 2,
              let agent = AgentKind(rawValue: String(parts[0])), agent != .grokBuild,
              let id = UUID(uuidString: String(parts[1])) else { throw StoreError.invalidLocation }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDashboard-live-\(id.uuidString)", isDirectory: true)
        return .init(agent: agent, root: root)
    }

    func register(in store: AgentStore) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700
        else { throw StoreError.invalidLocation }
        try store.upsertSource(.init(agent: agent, label: "Synthetic live update", rootURL: root,
                                    environment: "Synthetic"))
    }

    func matches(_ source: Source) -> Bool {
        source.agent == agent && source.rootURL.standardizedFileURL.path == root.standardizedFileURL.path
    }

    func marker(for session: SessionListItem) -> String? {
        guard session.id.agent == agent else { return nil }
        return switch (session.id.nativeID, session.title) {
        case (Self.existingID, nil): "synthetic-live-update: baseline row drawn"
        case (Self.existingID, Self.appendedTitle): "synthetic-live-update: appended row drawn"
        case (Self.newID, Self.newTitle): "synthetic-live-update: created row drawn"
        default: nil
        }
    }

    /// Invoked by a developer tool in a separate QA process before UI, model,
    /// or store setup. The dashboard process never calls these writer methods.
    static func runWriter() -> Int32 {
        do {
            guard let fixture = try request() else { throw StoreError.invalidLocation }
            try fixture.writeCommands()
            return EXIT_SUCCESS
        } catch {
            report("writer unavailable")
            return EXIT_FAILURE
        }
    }

    private static func report(_ marker: String) {
        FileHandle.standardOutput.write(Data("synthetic-live-update: \(marker)\n".utf8))
    }

    private func writeCommands() throws {
        try requireCommand("prepare")
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        let existing = sessionFile(Self.existingID)
        let initial = try jsonl(Self.existingID)
        try write(initial, to: existing)
        Self.report("writer prepared")

        try requireCommand("append")
        let appendLine = try jsonl(Self.existingID, title: Self.appendedTitle, includeInitial: false)
        let handle = try FileHandle(forWritingTo: existing)
        do {
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: appendLine)
        }
        Self.report("writer appended")

        try requireCommand("create")
        let created = sessionFile(Self.newID)
        let newLines = try jsonl(Self.newID, title: Self.newTitle)
        try write(newLines, to: created)
        Self.report("writer created")
        try requireCommand("finish")
        guard try Data(contentsOf: existing) == initial + appendLine,
              try Data(contentsOf: created) == newLines else { throw StoreError.invalidLocation }
    }

    private func requireCommand(_ expected: String) throws {
        guard readLine() == expected else { throw StoreError.invalidLocation }
    }

    private func write(_ bytes: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .withoutOverwriting)
    }

    private func sessionFile(_ id: String) -> URL {
        let relative = switch agent {
        case .claudeCode: "projects/synthetic/\(id).jsonl"
        case .codex: "sessions/2026/01/01/rollout-\(id).jsonl"
        case .copilot: "session-state/\(id)/events.jsonl"
        case .grokBuild: "" // request() disallows this agent
        }
        return root.appendingPathComponent(relative)
    }

    private func jsonl(_ id: String, title: String? = nil, includeInitial: Bool = true) throws -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: .now)
        func row(_ type: String, _ fields: [String: Any]) -> [String: Any] {
            fields.merging(["type": type, "timestamp": stamp]) { existing, _ in existing }
        }
        var records: [[String: Any]] = []
        if includeInitial {
            switch agent {
            case .claudeCode:
                records.append(row("assistant", ["uuid": UUID().uuidString, "sessionId": id, "cwd": Self.workspace,
                    "message": ["content": [["type": "text", "text": "Synthetic baseline"]]]]))
            case .codex:
                records.append(row("session_meta", ["payload": ["id": id, "cwd": Self.workspace]]))
            case .copilot:
                records.append(row("session.start", ["id": UUID().uuidString,
                    "data": ["sessionId": id, "context": ["cwd": Self.workspace]]]))
            case .grokBuild: throw StoreError.invalidLocation
            }
        }
        if let title {
            switch agent {
            case .claudeCode:
                records.append(row("user", ["uuid": UUID().uuidString, "sessionId": id, "cwd": Self.workspace,
                    "message": ["content": title]]))
            case .codex:
                records.append(row("event_msg", ["payload": ["type": "user_message", "message": title]]))
            case .copilot:
                records.append(row("user.message", ["id": UUID().uuidString, "data": ["content": title]]))
            case .grokBuild: throw StoreError.invalidLocation
            }
        }
        var bytes = Data()
        for record in records {
            bytes.append(try JSONSerialization.data(withJSONObject: record))
            bytes.append(0x0A)
        }
        return bytes
    }
}
#endif
