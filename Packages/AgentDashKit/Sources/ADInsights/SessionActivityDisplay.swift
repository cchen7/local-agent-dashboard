import ADCore
import ADPrivacy
import ADStore
import Foundation

/// Masked and bounded readout for the current session. Only a recognized
/// shell tool's indexed input can be shown as a command.
public struct SessionActivityDisplay: Equatable, Sendable {
    public let action: PersistedRunningActivity.Action
    public let toolName: String?
    public let command: String?
    public let startedAt: Int64?
    public let lastEventAt: Int64?

    public init(_ indexed: IndexedSessionActivity, agent: AgentKind, maskSecrets: Bool = true) {
        action = indexed.action
        startedAt = indexed.startedAt
        lastEventAt = indexed.lastEventAt
        let name = indexed.toolName
        toolName = Self.visible(name, limit: 48, maskSecrets: maskSecrets)
        let command: String?
        switch (agent, name?.lowercased()) {
        case (.claudeCode, "bash"):
            command = indexed.toolInput
        case (.codex, "exec_command"), (.codex, "functions.exec_command"):
            command = Self.object(indexed.toolMetadata)?["command"] as? String
        case (.copilot, "bash"), (.copilot, "powershell"), (.copilot, "shell"),
             (.copilot, "run_command"), (.copilot, "exec_command"):
            let arguments = Self.object(indexed.toolInput)
            command = (arguments?["command"] ?? arguments?["cmd"]) as? String
        default:
            command = nil
        }
        // Adapters that bound strings to 2 KiB can retreat by up to three
        // bytes at a UTF-8 scalar boundary. Those prefixes may end mid-token.
        let complete = command.flatMap { $0.utf8.count < 2045 ? $0 : nil }
        self.command = Self.visible(complete, limit: 160, maskSecrets: maskSecrets)
    }

    /// Future, missing and overflowing timestamps cannot establish elapsed time.
    public static func seconds(since time: Int64?, at now: Int64) -> Int64? {
        guard let time, time <= now else { return nil }
        let age = now.subtractingReportingOverflow(time)
        return age.overflow ? nil : age.partialValue / 1000
    }

    private static func object(_ text: String?) -> [String: Any]? {
        guard let text else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func visible(_ text: String?, limit: Int, maskSecrets: Bool) -> String? {
        guard let text else { return nil }
        let masked = maskSecrets ? SecretMasker.mask(text) : text
        let singleLine = masked.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return nil }
        let prefix = singleLine.prefix(limit)
        return prefix.count == singleLine.count ? singleLine : String(prefix) + "…"
    }
}
