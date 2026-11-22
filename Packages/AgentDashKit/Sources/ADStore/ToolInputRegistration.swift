import ADCore
import Foundation
import GRDB

public struct RegisteredToolInput: Equatable, Sendable {
    public let origin: ToolInputOrigin
    public let file: SourceFile
    public let source: Source
    public let rootIdentity: SourceRootIdentity?
    public let redact: Bool
}

public extension AgentStore {
    /// Reread the current registration and origin for this event. An unavailable
    /// file, removed source, foreign event key or invalid locator never grants access.
    func registeredToolInput(in session: SessionKey, eventKey: String) throws -> RegisteredToolInput? {
        try databasePool.read { db in
            guard let raw = try String.fetchOne(db, sql: """
                SELECT e.tool_input_origin FROM events e JOIN sessions s ON s.id=e.session_id
                WHERE s.agent=? AND s.native_id=? AND e.dedupe_key=? AND e.kind='tool_call'
                """, arguments: [session.agent.rawValue, session.nativeID, eventKey]),
                raw.utf8.count <= 4096,
                let origin = try? JSONDecoder().decode(ToolInputOrigin.self, from: Data(raw.utf8)),
                let row = try Row.fetchOne(db, sql: """
                    SELECT s.*,f.rel_path AS input_path,f.role AS input_role,f.parser_version AS input_parser,
                        r.volume AS root_volume,r.inode AS root_inode,r.birth_seconds AS root_birth_seconds,
                        r.birth_nanoseconds AS root_birth_nanoseconds
                    FROM source_files f JOIN sources s ON s.id=f.source_id
                    LEFT JOIN source_root_identities r ON r.source_id=s.id
                    WHERE f.id=? AND s.removed=0 AND f.state<>'gone' AND f.role IN ('session','subagent')
                    """, arguments: [origin.fileID]),
                let role = SourceFile.Role(rawValue: row["input_role"]) else { return nil }
            let source = try Self.decodeSource(row)
            guard let sourceID = source.id, source.agent == session.agent, source.agent == origin.format.agent else { return nil }

            let rootIdentity: SourceRootIdentity?
            if let stored: String = row["root_volume"] {
                guard let volume = UUID(uuidString: stored) else { return nil }
                rootIdentity = .init(volume: volume, inode: row["root_inode"], birthSeconds: row["root_birth_seconds"],
                                     birthNanoseconds: row["root_birth_nanoseconds"])
            } else { rootIdentity = nil }
            let file = SourceFile(id: origin.fileID, sourceID: sourceID, relativePath: row["input_path"],
                                  role: role, parserVersion: row["input_parser"])
            return .init(origin: origin, file: file, source: source, rootIdentity: rootIdentity,
                         redact: try IndexSecretRedaction.enabled(db))
        }
    }
}
