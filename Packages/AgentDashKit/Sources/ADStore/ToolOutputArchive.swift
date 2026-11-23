import ADCore
import Compression
import Foundation
import GRDB

public enum ToolOutputArchiveLimit: Int, CaseIterable, Sendable {
    case previewOnly = 0, small = 16_384, medium = 32_768, standard = 65_536
}

public struct ToolOutputDetails: Sendable {
    public let archivedText: String?
    public let hasOriginal: Bool
}

public struct RegisteredToolOutput: Equatable, Sendable {
    public let origin: ToolOutputOrigin
    public let file: SourceFile
    public let source: Source
    public let redact: Bool
}

public extension AgentStore {
    func toolOutputArchiveLimit() throws -> ToolOutputArchiveLimit {
        try databasePool.read { try ToolOutputArchive.limit($0) }
    }

    @discardableResult
    func setToolOutputArchiveLimit(_ limit: ToolOutputArchiveLimit) throws -> Bool {
        try databasePool.write { db in
            let old = try ToolOutputArchive.limit(db)
            guard old != limit else { return false }
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('tool_output_archive_limit',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [String(limit.rawValue)])
            if limit.rawValue < old.rawValue {
                try db.execute(sql: """
                    UPDATE events SET blob_id=NULL WHERE blob_id IN (SELECT id FROM blobs WHERE length(data)>?);
                    DELETE FROM blobs WHERE NOT EXISTS(SELECT 1 FROM events WHERE blob_id=blobs.id);
                    """, arguments: [limit.rawValue])
            } else {
                try db.execute(sql: """
                    UPDATE source_files SET parser_version=0,decoder_state=NULL
                    WHERE role IN ('session','subagent') AND state<>'gone'
                        AND source_id IN (SELECT id FROM sources WHERE removed=0 AND agent IN ('claude_code','codex','copilot'))
                    """)
            }
            return true
        }
    }

    func toolOutputDetails(in session: SessionKey, eventKey: String) throws -> ToolOutputDetails {
        try databasePool.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT b.codec,b.raw_len,b.data,e.tool_output_origin
                FROM events e JOIN sessions s ON s.id=e.session_id LEFT JOIN blobs b ON b.id=e.blob_id
                WHERE s.agent=? AND s.native_id=? AND e.dedupe_key=? AND e.kind='tool_result'
                """, arguments: [session.agent.rawValue, session.nativeID, eventKey])
            return .init(archivedText: row.flatMap(ToolOutputArchive.decode), hasOriginal: (row?["tool_output_origin"] as String?) != nil)
        }
    }

    /// Revalidate the event and source before the App requests read access.
    func registeredToolOutput(in session: SessionKey, eventKey: String) throws -> RegisteredToolOutput? {
        try databasePool.read { db in
            guard let raw = try String.fetchOne(db, sql: """
                SELECT e.tool_output_origin FROM events e JOIN sessions s ON s.id=e.session_id
                WHERE s.agent=? AND s.native_id=? AND e.dedupe_key=? AND e.kind='tool_result'
                """, arguments: [session.agent.rawValue, session.nativeID, eventKey]),
                let origin = try? JSONDecoder().decode(ToolOutputOrigin.self, from: Data(raw.utf8)),
                let row = try Row.fetchOne(db, sql: """
                    SELECT f.source_id,f.rel_path,f.role,f.parser_version,s.agent,s.label,s.root_path,s.environment,
                        s.path_mappings_json,s.env_rules_json,s.access_kind,s.bookmark,s.enabled
                    FROM source_files f JOIN sources s ON s.id=f.source_id WHERE f.id=? AND s.removed=0
                    """, arguments: [origin.fileID]),
                let agent = AgentKind(rawValue: row["agent"]), agent == session.agent,
                let role = SourceFile.Role(rawValue: row["role"]) else { return nil }
            let access: AccessKind
            if (row["access_kind"] as String) == "default_location" { access = .defaultLocation }
            else if let bookmark: Data = row["bookmark"] { access = .bookmark(bookmark) }
            else { return nil }
            let sourceID: Int64 = row["source_id"]
            let decoder = JSONDecoder()
            let mappings: String = row["path_mappings_json"]
            let rules: String = row["env_rules_json"]
            let source = Source(id: sourceID, agent: agent, label: row["label"], rootURL: URL(fileURLWithPath: row["root_path"]),
                                environment: row["environment"], pathMappings: try decoder.decode([PathMapping].self, from: Data(mappings.utf8)),
                                environmentRules: try decoder.decode([EnvironmentRule].self, from: Data(rules.utf8)),
                                access: access, enabled: row["enabled"])
            let file = SourceFile(id: origin.fileID, sourceID: sourceID, relativePath: row["rel_path"],
                                  role: role, parserVersion: row["parser_version"])
            return .init(origin: origin, file: file, source: source, redact: try IndexSecretRedaction.enabled(db))
        }
    }
}

enum ToolOutputArchive {
    static func limit(_ db: Database) throws -> ToolOutputArchiveLimit {
        guard let value = try String.fetchOne(db.cachedStatement(sql: "SELECT value FROM app_meta WHERE key='tool_output_archive_limit'"))
        else { return .standard }
        guard let int = Int(value), let limit = ToolOutputArchiveLimit(rawValue: int) else { throw StoreError.invalidStoredValue }
        return limit
    }

    static func encode(_ text: String, limit: ToolOutputArchiveLimit) -> (bytes: Data, rawCount: Int)? {
        let source = Data(text.utf8)
        guard source.count > ToolOutputCapture.searchableBytes, source.count <= ToolOutputCapture.decodedArchiveBytes,
              limit != .previewOnly else { return nil }
        var result = Data(count: limit.rawValue)
        let size = result.withUnsafeMutableBytes { output in
            source.withUnsafeBytes { input in
                guard let out = output.bindMemory(to: UInt8.self).baseAddress,
                      let bytes = input.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(out, output.count, bytes, input.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard size > 0 else { return nil }
        result.count = size
        return (result, source.count)
    }

    static func decode(_ row: Row) -> String? {
        guard (row["codec"] as String?) == "lzfse", let size: Int = row["raw_len"],
              size > 0, size <= ToolOutputCapture.decodedArchiveBytes,
              let bytes: Data = row["data"], !bytes.isEmpty, bytes.count <= ToolOutputArchiveLimit.standard.rawValue else { return nil }
        // One spare byte distinguishes exact output from a truncated decode.
        var output = Data(count: size + 1)
        let decoded = output.withUnsafeMutableBytes { plain in
            bytes.withUnsafeBytes { packed in
                guard let dst = plain.bindMemory(to: UInt8.self).baseAddress,
                      let src = packed.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, plain.count, src, packed.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard decoded == size else { return nil }
        return String(bytes: output.prefix(size), encoding: .utf8)
    }

    static func removeUnreferenced(_ id: Int64?, db: Database) throws {
        guard let id else { return }
        try db.cachedStatement(sql: "DELETE FROM blobs WHERE id=?1 AND NOT EXISTS(SELECT 1 FROM events WHERE blob_id=?1)")
            .execute(arguments: [id])
    }
}
