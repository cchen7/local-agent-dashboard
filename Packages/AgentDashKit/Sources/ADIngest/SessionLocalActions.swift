import ADAdapters
import ADCore
import ADStore
import Foundation

public enum SessionLocalActionFailure: Error, Equatable, Sendable {
    case unavailable
}

/// Prepare commands and explicit local Finder targets. There is no process
/// launch, shell execution, or external URL inference in this layer.
public enum SessionLocalActions {
    public static func resumeCommand(_ input: IndexedSessionActions, hostHome: String?) -> String? {
        guard input.canResume, let raw = input.workspace, let sourceID = input.source.id,
              let workspace = try? PathMapper.map(raw, using: input.source.pathMappings, hostHome: hostHome),
              !workspace.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        let session = SessionRecord(key: input.key, sourceID: sourceID, environment: input.environment, cwd: workspace)
        let command: String?
        switch input.key.agent {
        case .claudeCode: command = ClaudeCodeAdapter().resumeCommand(for: session)
        case .codex: command = CodexAdapter().resumeCommand(for: session)
        case .copilot: command = CopilotAdapter().resumeCommand(for: session)
        case .grokBuild: command = nil
        }
        guard let command else { return nil }
        let expected = hostHome.map {
            URL(fileURLWithPath: $0).appendingPathComponent(input.key.agent.defaultSourceDirectoryName).standardizedFileURL.path
        }
        let hostLocal = expected.map { $0.utf8.elementsEqual(input.source.rootURL.standardizedFileURL.path.utf8) } ?? false
        if hostLocal && input.environment == "Local" { return command }
        // Do not interpolate untrusted environment names into shell comments.
        return "# Use the same environment and agent configuration as this session.\n" + command
    }

    /// Verify that the currently reachable file is still the indexed input.
    /// The caller holds the registered source grant through the Finder action.
    public static func withVerifiedRecordURL<Value>(_ record: IndexedRecordLocation, authorizedRoot: URL,
                                                     _ use: (URL) throws -> Value) throws -> Value {
        let root = try SourceFileReader.directoryIdentity(root: authorizedRoot)
        if let expected = record.rootIdentity, try SourceFileReader.registrationIdentity(root: authorizedRoot) != expected {
            throw SessionLocalActionFailure.unavailable
        }
        let reader = try SourceFileReader(root: authorizedRoot, relativePath: record.relativePath, expectedRoot: root)
        let snapshot = try reader.snapshot()
        guard snapshot.device == record.device, snapshot.inode == record.inode,
              try SourceFileReader.directoryIdentity(root: authorizedRoot) == root else {
            throw SessionLocalActionFailure.unavailable
        }
        return try withExtendedLifetime(reader) {
            try use(authorizedRoot.appendingPathComponent(record.relativePath))
        }
    }
}
