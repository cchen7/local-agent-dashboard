import Foundation
import GRDB
import ADCore

/// Store errors deliberately omit paths, record contents, and bookmark bytes.
public enum StoreError: Error, Equatable, Sendable {
    case invalidLocation, invalidRelativePath, invalidCheckpoint, invalidTokenCounts
    case missingSession, missingFile, invalidStoredValue, missingMigration
}

/// App-owned WAL database. The caller must supply a URL in its own container (or a
/// synthetic test directory), never an agent database. No source URL is opened here.
/// All SQL and GRDB types stay inside ADStore; synchronous calls belong off the UI actor.
public final class AgentStore: Sendable {
    let databasePool: DatabasePool

    /// Open an app-owned database, register the tokenizer on every connection, then migrate.
    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else { throw StoreError.invalidLocation }
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in db.add(tokenizer: AgentDashTokenizer.self) }
        databasePool = try DatabasePool(path: databaseURL.path, configuration: config)
        guard let url = Bundle.module.url(forResource: "v1", withExtension: "sql") else {
            throw StoreError.missingMigration
        }
        let schema = try String(contentsOf: url, encoding: .utf8)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in try db.execute(sql: schema) }
        try migrator.migrate(databasePool)
    }

    /// Upsert by (agent, root path); returns the stable row ID and never replaces children.
    @discardableResult
    public func upsertSource(_ source: Source) throws -> Int64 {
        guard source.rootURL.isFileURL else { throw StoreError.invalidLocation }
        let mappings = String(decoding: try JSONEncoder().encode(source.pathMappings), as: UTF8.self)
        let rules = String(decoding: try JSONEncoder().encode(source.environmentRules), as: UTF8.self)
        let kind: String
        let bookmark: Data?
        switch source.access {
        case .defaultLocation: kind = "default_location"; bookmark = nil
        case .bookmark(let data): kind = "bookmark"; bookmark = data
        }
        return try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO sources(agent,label,root_path,environment,path_mappings_json,env_rules_json,access_kind,bookmark,enabled)
                VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(agent,root_path) DO UPDATE SET
                label=excluded.label, environment=excluded.environment, path_mappings_json=excluded.path_mappings_json,
                env_rules_json=excluded.env_rules_json, access_kind=excluded.access_kind, bookmark=excluded.bookmark, enabled=excluded.enabled
                """, arguments: [source.agent.rawValue, source.label, source.rootURL.standardizedFileURL.path,
                                  source.environment, mappings, rules, kind, bookmark, source.enabled])
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM sources WHERE agent=? AND root_path=?",
                                              arguments: [source.agent.rawValue, source.rootURL.standardizedFileURL.path]) else {
                throw StoreError.invalidStoredValue
            }
            return id
        }
    }

    /// Load source settings/bookmarks. This does not resolve or access the source directories.
    public func sources() throws -> [Source] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sources ORDER BY id").map { row in
                guard let agent = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
                let kind: String = row["access_kind"]
                let access: AccessKind
                switch kind {
                case "default_location": access = .defaultLocation
                case "bookmark":
                    guard let data: Data = row["bookmark"] else { throw StoreError.invalidStoredValue }
                    access = .bookmark(data)
                default: throw StoreError.invalidStoredValue
                }
                let mappings: String = row["path_mappings_json"]
                let rules: String = row["env_rules_json"]
                return Source(id: row["id"], agent: agent, label: row["label"],
                              rootURL: URL(fileURLWithPath: row["root_path"]), environment: row["environment"],
                              pathMappings: try JSONDecoder().decode([PathMapping].self, from: Data(mappings.utf8)),
                              environmentRules: try JSONDecoder().decode([EnvironmentRule].self, from: Data(rules.utf8)),
                              access: access, enabled: row["enabled"])
            }
        }
    }

    /// Register a relative file without opening it. A nil checkpoint preserves prior
    /// progress and parser version so ingestion can detect that reparsing is required.
    @discardableResult
    public func upsertFile(_ file: SourceFile, checkpoint: Checkpoint?) throws -> Int64 {
        guard !file.relativePath.isEmpty, !file.relativePath.hasPrefix("/"),
              !file.relativePath.split(separator: "/").contains("..") else { throw StoreError.invalidRelativePath }
        return try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO source_files(source_id,rel_path,role,parser_version,state) VALUES(?,?,?,?,'ok')
                ON CONFLICT(source_id,rel_path) DO UPDATE SET role=excluded.role
                """, arguments: [file.sourceID, file.relativePath, file.role.rawValue, file.parserVersion])
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM source_files WHERE source_id=? AND rel_path=?",
                                              arguments: [file.sourceID, file.relativePath]) else { throw StoreError.missingFile }
            if let checkpoint { try Self.save(checkpoint, fileID: id, db: db) }
            return id
        }
    }

    /// A file without an observed inode/size has no durable read checkpoint yet.
    public func checkpoint(for fileID: Int64) throws -> Checkpoint? {
        try databasePool.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM source_files WHERE id=?", arguments: [fileID]),
                  let size: Int64 = row["size"] else { return nil }
            return Checkpoint(inode: row["inode"], size: size, offset: row["read_offset"],
                              parserVersion: row["parser_version"], sequence: row["last_seq"], previousTimestamp: row["previous_ts"])
        }
    }

    /// Atomically persist ordered records and optional file progress. Dedupe-key conflicts
    /// update the same row within a session; copied history keeps its original owner.
    /// This M0 primitive does not yet calculate rollups or insights.
    public func write(_ records: [NormalizedRecord], fileID: Int64? = nil, checkpoint: Checkpoint? = nil) throws {
        try databasePool.write { db in
            for record in records {
                switch record {
                case .session(let session): try Self.save(session, db: db)
                case .event(let event): try Self.save(event, db: db)
                case .tokens(let event): try Self.save(event, db: db)
                }
            }
            if let checkpoint {
                guard let fileID else { throw StoreError.missingFile }
                try Self.save(checkpoint, fileID: fileID, db: db)
            }
        }
    }

    /// Normalized transcript in file order. Paging/search APIs are added with M1/M3.
    public func events(in session: SessionKey) throws -> [EventRecord] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.* FROM events e JOIN sessions s ON s.id=e.session_id
                WHERE s.agent=? AND s.native_id=? ORDER BY e.seq,e.id
                """, arguments: [session.agent.rawValue, session.nativeID]).map { row in
                guard let kind = EventKind(rawValue: row["kind"]) else { throw StoreError.invalidStoredValue }
                return EventRecord(session: session, sequence: row["seq"], timestamp: row["ts"], kind: kind,
                                   toolName: row["tool_name"], text: row["text"], metadataJSON: row["meta_json"], dedupeKey: row["dedupe_key"])
            }
        }
    }

    private static func sessionID(_ key: SessionKey, db: Database) throws -> Int64 {
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE agent=? AND native_id=?",
                                          arguments: [key.agent.rawValue, key.nativeID]) else { throw StoreError.missingSession }
        return id
    }

    private static func save(_ value: SessionRecord, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO sessions(agent,native_id,source_id,file_id,environment,cwd,title,started_at,last_event_at,status)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(agent,native_id) DO UPDATE SET
            source_id=excluded.source_id,file_id=excluded.file_id,environment=excluded.environment,cwd=excluded.cwd,
            title=excluded.title,started_at=excluded.started_at,last_event_at=excluded.last_event_at,status=excluded.status
            """, arguments: [value.key.agent.rawValue, value.key.nativeID, value.sourceID, value.fileID,
                              value.environment, value.cwd, value.title, value.startedAt, value.lastEventAt, value.status.rawValue])
    }

    private static func save(_ value: EventRecord, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO events(session_id,seq,ts,kind,tool_name,text,meta_json,dedupe_key) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(dedupe_key) DO UPDATE SET seq=excluded.seq,ts=excluded.ts,
            kind=excluded.kind,tool_name=excluded.tool_name,text=excluded.text,meta_json=excluded.meta_json
            WHERE events.session_id=excluded.session_id
            """, arguments: [try sessionID(value.session, db: db), value.sequence, value.timestamp, value.kind.rawValue,
                              value.toolName, value.text, value.metadataJSON, value.dedupeKey])
    }

    private static func save(_ value: TokenEvent, db: Database) throws {
        let c = value.counts
        guard [c.inputFresh,c.cacheRead,c.cacheWrite,c.cacheWrite1h,c.output,c.reasoning].allSatisfy({ $0 >= 0 }),
              c.reasoning <= c.output else { throw StoreError.invalidTokenCounts }
        try db.execute(sql: """
            INSERT INTO token_events(session_id,agent,model,ts,input_fresh,cache_read,cache_write,cache_write_1h,output,reasoning,precision,dedupe_key)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(dedupe_key) DO UPDATE SET
            agent=excluded.agent,model=excluded.model,ts=excluded.ts,input_fresh=excluded.input_fresh,
            cache_read=excluded.cache_read,cache_write=excluded.cache_write,cache_write_1h=excluded.cache_write_1h,
            output=excluded.output,reasoning=excluded.reasoning,precision=excluded.precision
            WHERE token_events.session_id=excluded.session_id
            """, arguments: [try sessionID(value.session, db: db), value.session.agent.rawValue, value.model, value.timestamp,
                              c.inputFresh, c.cacheRead, c.cacheWrite, c.cacheWrite1h, c.output, c.reasoning, value.precision.rawValue, value.dedupeKey])
    }

    private static func save(_ checkpoint: Checkpoint, fileID: Int64, db: Database) throws {
        guard checkpoint.size >= 0, checkpoint.offset >= 0, checkpoint.offset <= checkpoint.size,
              checkpoint.parserVersion > 0, checkpoint.sequence >= -1 else { throw StoreError.invalidCheckpoint }
        try db.execute(sql: """
            UPDATE source_files SET inode=?,size=?,read_offset=?,parser_version=?,last_seq=?,previous_ts=? WHERE id=?
            """, arguments: [checkpoint.inode, checkpoint.size, checkpoint.offset, checkpoint.parserVersion,
                              checkpoint.sequence, checkpoint.previousTimestamp, fileID])
        guard db.changesCount == 1 else { throw StoreError.missingFile }
    }
}
