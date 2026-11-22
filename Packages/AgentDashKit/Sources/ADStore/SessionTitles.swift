import ADCore
import ADPrivacy
import Foundation
import GRDB

public enum SessionTitleSource: String, Equatable, Sendable {
    case user, agent
    case firstPrompt = "first_prompt"
}

public enum SessionTitleFailure: Error, Equatable, Sendable {
    case invalidTitle
}

public enum SessionTitleRules {
    public static let maximumCharacters = 80

    public static func validatedCustomTitle(_ raw: String) -> String? {
        // Bound the input before walking all of its grapheme clusters.
        guard raw.utf8.prefix(513).count <= 512 else { return nil }
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= maximumCharacters,
              !title.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || CharacterSet.newlines.contains($0)
              })
        else { return nil }
        return title
    }

    static let meaningfulPrompt = DatabaseFunction("agentdash_meaningful_prompt", argumentCount: 1, pure: true) {
        (values: [DatabaseValue]) -> Bool in
        guard let raw = String.fromDatabaseValue(values[0]) else { return false }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let contextTags = ["<environment_context>", "<user_instructions>", "<permissions instructions>",
                           "<system-reminder>", "# AGENTS.md instructions"]
        guard !contextTags.contains(where: text.hasPrefix) else { return false }

        // A command such as /clear should not name a session, but a prompt
        // beginning with a path such as /work/app.swift is still useful.
        let prefix = text.prefix { !$0.isWhitespace }
        if prefix.hasPrefix("/") {
            let command = prefix.dropFirst()
            if command.isEmpty || command.allSatisfy({
                $0.isASCII && ($0.isLetter || $0.isNumber || "_-:".contains($0))
            }) { return false }
        }
        return true
    }
}

public extension AgentStore {
    /// An optional override in the owned index. Nil resumes automatic titles.
    /// Imported/replayed session metadata never writes this column.
    func setCustomSessionTitle(_ rawTitle: String?, for key: SessionKey) async throws {
        let title: String?
        if let rawTitle {
            guard let validated = SessionTitleRules.validatedCustomTitle(rawTitle) else {
                throw SessionTitleFailure.invalidTitle
            }
            title = validated
        } else {
            title = nil
        }
        try await databasePool.write { db in
            let stored = try IndexSecretRedaction.enabled(db) ? title.map(IndexSecretMasker.text) : title
            try db.execute(sql: "UPDATE sessions SET user_title=? WHERE agent=? AND native_id=?",
                           arguments: [stored, key.agent.rawValue, key.nativeID])
            guard db.changesCount == 1 else { throw StoreError.missingSession }
        }
    }
}
