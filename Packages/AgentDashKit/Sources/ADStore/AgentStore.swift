import Foundation
import GRDB
import ADCore

/// Store errors deliberately omit paths, record contents, and bookmark bytes.
public enum StoreError: Error, Equatable, Sendable {
    case invalidLocation, invalidRelativePath, invalidCheckpoint, invalidTokenCounts, invalidCustomSource
    case missingSession, missingFile, invalidStoredValue, missingMigration, staleCheckpoint
}

/// A duplicate choice leaves the existing source and all of its children intact.
public enum CustomSourceRegistration: Equatable, Sendable {
    case added(Int64)
    case alreadyRegistered(Int64)
    case pathConflict
}

public enum SourceAccessRenewal: Equatable, Sendable {
    case renewed, wrongDirectory, pathConflict
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
        migrator.registerMigration("v2_jsonl_checkpoint") { db in
            try db.execute(sql: """
                ALTER TABLE source_files ADD COLUMN device INTEGER;
                ALTER TABLE source_files ADD COLUMN decoder_state BLOB;
                """)
        }
        migrator.registerMigration("v3_session_parent_hint") { db in
            try db.execute(sql: """
                ALTER TABLE sessions ADD COLUMN parent_native_id TEXT;
                CREATE INDEX sessions_parent_hint ON sessions(agent, parent_native_id)
                WHERE parent_native_id IS NOT NULL;
                """)
        }
        migrator.registerMigration("source_root_identity") { db in
            try db.execute(sql: """
                CREATE TABLE source_root_identities (
                    source_id INTEGER PRIMARY KEY REFERENCES sources(id) ON DELETE CASCADE,
                    volume TEXT NOT NULL, inode INTEGER NOT NULL,
                    birth_seconds INTEGER NOT NULL, birth_nanoseconds INTEGER NOT NULL
                );
                CREATE INDEX source_root_identity_lookup ON source_root_identities(volume,inode,birth_seconds,birth_nanoseconds);
                CREATE TRIGGER source_root_identity_permission_changed
                AFTER UPDATE OF access_kind,bookmark ON sources
                WHEN old.access_kind IS NOT new.access_kind OR old.bookmark IS NOT new.bookmark
                BEGIN
                    DELETE FROM source_root_identities WHERE source_id=new.id;
                END;
                """)
        }
        try migrator.migrate(databasePool)
    }

    /// Upsert by (agent, root path); returns the stable row ID and never replaces children.
    @discardableResult
    public func upsertSource(_ source: Source) throws -> Int64 {
        guard case .added(let id) = try saveSource(source, registration: nil) else {
            throw StoreError.invalidStoredValue
        }
        return id
    }

    /// Register a selected local root. The caller supplies its observed identity
    /// and optionally an older authorized source observed to refer to that root.
    /// `occupiedPath` identifies a saved path whose current occupant matched
    /// the selected identity, even when the two path spellings differ.
    /// The store validates both source snapshots without opening either path.
    public func registerCustomSource(_ source: Source, identity: SourceRootIdentity,
                                     existing: Source? = nil, occupiedPath: Source? = nil) throws -> CustomSourceRegistration {
        guard Source.isLocalRoot(source.rootURL) else { throw StoreError.invalidLocation }
        guard case .bookmark(let data) = source.access, !data.isEmpty,
              !source.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !source.environment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw StoreError.invalidCustomSource }
        return try saveSource(source, registration: (identity, existing, occupiedPath))
    }

    /// Refresh an existing source by ID and directory identity. The caller
    /// reads filesystem metadata and supplies an opaque read-only bookmark.
    /// Legacy custom rows need independent evidence from their old bookmark.
    public func renewSourceAccess(_ source: Source, selectedRoot: URL, identity: SourceRootIdentity,
                                  bookmark: Data, legacyBookmarkIdentity: SourceRootIdentity? = nil)
    throws -> SourceAccessRenewal {
        guard Source.isLocalRoot(selectedRoot) else { throw StoreError.invalidLocation }
        guard !bookmark.isEmpty else { throw StoreError.invalidCustomSource }
        let root = selectedRoot.standardizedFileURL.path
        return try databasePool.write { db in
            let id = try Self.validateObservedSource(source, for: source.agent, db: db)
            let storedMatch = try Bool.fetchOne(db, sql: """
                SELECT volume=? AND inode=? AND birth_seconds=? AND birth_nanoseconds=?
                FROM source_root_identities WHERE source_id=?
                """, arguments: [identity.volume.uuidString, identity.inode,
                                  identity.birthSeconds, identity.birthNanoseconds, id])
            let matches: Bool
            if let storedMatch {
                matches = storedMatch
            } else {
                switch source.access {
                case .defaultLocation: matches = root.utf8.elementsEqual(source.rootURL.standardizedFileURL.path.utf8)
                case .bookmark: matches = legacyBookmarkIdentity == identity
                }
            }
            guard matches else { return .wrongDirectory }
            if try Int.fetchOne(db, sql: "SELECT 1 FROM sources WHERE agent=? AND root_path=? AND id<>?",
                                arguments: [source.agent.rawValue, root, id]) != nil { return .pathConflict }
            try db.execute(sql: "UPDATE sources SET root_path=?, access_kind='bookmark', bookmark=? WHERE id=?",
                           arguments: [root, bookmark, id])
            // The general permission-change trigger invalidates old identity
            // metadata. Restore the verified identity in the same transaction.
            try Self.saveRootIdentity(identity, for: id, db: db)
            return .renewed
        }
    }

    private func saveSource(_ source: Source, registration: (identity: SourceRootIdentity, existing: Source?, occupiedPath: Source?)?)
    throws -> CustomSourceRegistration {
        guard source.rootURL.isFileURL else { throw StoreError.invalidLocation }
        let root = source.rootURL.standardizedFileURL.path
        let mappings = String(decoding: try JSONEncoder().encode(source.pathMappings), as: UTF8.self)
        let rules = String(decoding: try JSONEncoder().encode(source.environmentRules), as: UTF8.self)
        let kind: String
        let bookmark: Data?
        switch source.access {
        case .defaultLocation: kind = "default_location"; bookmark = nil
        case .bookmark(let data): kind = "bookmark"; bookmark = data
        }
        let conflict = registration == nil ? """
            DO UPDATE SET label=excluded.label, environment=excluded.environment, path_mappings_json=excluded.path_mappings_json,
            env_rules_json=excluded.env_rules_json, access_kind=excluded.access_kind, bookmark=excluded.bookmark, enabled=excluded.enabled
            """ : "DO NOTHING"
        return try databasePool.write { db in
            if let registration {
                let identity = registration.identity
                if let id = try Int64.fetchOne(db, sql: """
                    SELECT s.id FROM source_root_identities r JOIN sources s ON s.id=r.source_id
                    WHERE s.agent=? AND r.volume=? AND r.inode=? AND r.birth_seconds=? AND r.birth_nanoseconds=?
                    ORDER BY s.id LIMIT 1
                    """, arguments: [source.agent.rawValue, identity.volume.uuidString, identity.inode,
                                      identity.birthSeconds, identity.birthNanoseconds]) { return .alreadyRegistered(id) }
                if let existing = registration.existing {
                    let id = try Self.validateObservedSource(existing, for: source.agent, db: db)
                    // A resolved bookmark can identify a legacy row, but cannot
                    // override a known, different stored directory identity.
                    if try Int.fetchOne(db, sql: "SELECT 1 FROM source_root_identities WHERE source_id=?",
                                        arguments: [id]) == nil { return .alreadyRegistered(id) }
                }
                if let occupiedPath = registration.occupiedPath {
                    _ = try Self.validateObservedSource(occupiedPath, for: source.agent, db: db)
                    return .pathConflict
                }
            }
            try db.execute(sql: """
                INSERT INTO sources(agent,label,root_path,environment,path_mappings_json,env_rules_json,access_kind,bookmark,enabled)
                VALUES (?,?,?,?,?,?,?,?,?) ON CONFLICT(agent,root_path) \(conflict)
                """, arguments: [source.agent.rawValue, source.label, root,
                                  source.environment, mappings, rules, kind, bookmark, source.enabled])
            if registration != nil, db.changesCount == 0 { return .pathConflict }
            guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM sources WHERE agent=? AND root_path=?",
                                              arguments: [source.agent.rawValue, root]) else {
                throw StoreError.invalidStoredValue
            }
            if let identity = registration?.identity {
                try Self.saveRootIdentity(identity, for: id, db: db)
            }
            return .added(id)
        }
    }

    private static func saveRootIdentity(_ identity: SourceRootIdentity, for id: Int64, db: Database) throws {
        try db.execute(sql: """
            INSERT INTO source_root_identities(source_id,volume,inode,birth_seconds,birth_nanoseconds)
            VALUES(?,?,?,?,?) ON CONFLICT(source_id) DO UPDATE SET volume=excluded.volume, inode=excluded.inode,
                birth_seconds=excluded.birth_seconds, birth_nanoseconds=excluded.birth_nanoseconds
            """, arguments: [id, identity.volume.uuidString, identity.inode, identity.birthSeconds, identity.birthNanoseconds])
    }

    private static func validateObservedSource(_ source: Source, for agent: AgentKind, db: Database) throws -> Int64 {
        guard source.agent == agent, let id = source.id else { throw StoreError.invalidCustomSource }
        let (kind, bookmark): (String, Data?)
        switch source.access {
        case .defaultLocation: (kind, bookmark) = ("default_location", nil)
        case .bookmark(let data): (kind, bookmark) = ("bookmark", data)
        }
        let valid = try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM sources WHERE id=? AND agent=? AND root_path=? AND access_kind=? AND bookmark IS ?)
            """, arguments: [id, agent.rawValue, source.rootURL.standardizedFileURL.path, kind, bookmark])
        guard valid == true else { throw StoreError.invalidCustomSource }
        return id
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
        try databasePool.read { try Self.readCheckpoint(fileID, db: $0) }
    }

    /// Atomically persist ordered records and optional file progress. Dedupe-key conflicts
    /// update the same row within a session; copied history keeps its original owner.
    /// This M0 primitive does not yet calculate rollups or insights.
    public func write(_ records: [NormalizedRecord], fileID: Int64? = nil, checkpoint: Checkpoint? = nil) throws {
        try databasePool.write { db in
            try Self.save(records, db: db)
            if let checkpoint {
                guard let fileID else { throw StoreError.missingFile }
                try Self.save(checkpoint, fileID: fileID, db: db)
            }
        }
    }

    /// Commit parsed records only if the read position is still the expected
    /// one. This check is in the writer transaction to reject concurrent scans.
    public func commitFileBatch(_ records: [NormalizedRecord], for fileID: Int64,
                                from expected: Checkpoint?, to next: Checkpoint) throws {
        try databasePool.write { db in
            guard try Self.readCheckpoint(fileID, db: db) == expected else {
                throw StoreError.staleCheckpoint
            }
            try Self.save(records, db: db)
            try Self.save(next, fileID: fileID, db: db)
        }
    }

    private static func readCheckpoint(_ fileID: Int64, db: Database) throws -> Checkpoint? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM source_files WHERE id=?", arguments: [fileID]),
              let size: Int64 = row["size"] else { return nil }
        return Checkpoint(inode: row["inode"], size: size, offset: row["read_offset"],
                          parserVersion: row["parser_version"], sequence: row["last_seq"],
                          previousTimestamp: row["previous_ts"], device: row["device"],
                          modificationTimeNS: row["mtime_ns"], decoderState: row["decoder_state"],
                          unknownRecords: row["unknown_records"])
    }

    private static func save(_ records: [NormalizedRecord], db: Database) throws {
        for record in records {
            switch record {
            case .session(let session): try save(session, db: db)
            case .event(let event): try save(event, db: db)
            case .tokens(let event): try save(event, db: db)
            case let .removeEmptyPlaceholder(session, fileID, sequence, dedupeKey):
                try db.cachedStatement(sql: """
                    DELETE FROM events
                    WHERE dedupe_key=? AND seq=? AND kind='unknown' AND text=''
                        AND tool_name IS NULL AND meta_json IS NULL AND blob_id IS NULL
                        AND session_id IN (
                            SELECT id FROM sessions WHERE agent=? AND native_id=? AND file_id=?
                                AND source_deleted_at IS NULL
                        )
                    """).execute(arguments: [dedupeKey, sequence, session.agent.rawValue, session.nativeID, fileID])
            }
        }
    }

    /// Full normalized transcript. Use transcriptPage for interactive reads.
    public func events(in session: SessionKey) throws -> [EventRecord] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.* FROM events e JOIN sessions s ON s.id=e.session_id
                WHERE s.agent=? AND s.native_id=? ORDER BY e.seq,e.id
                """, arguments: [session.agent.rawValue, session.nativeID]).map { row in
                try Self.readTranscriptEvent(row, in: session)
            }
        }
    }

    static func readTranscriptEvent(_ row: Row, in session: SessionKey) throws -> EventRecord {
        guard let kind = EventKind(rawValue: row["kind"]) else { throw StoreError.invalidStoredValue }
        return EventRecord(session: session, sequence: row["seq"], timestamp: row["ts"], kind: kind,
                           toolName: row["tool_name"], text: row["text"], metadataJSON: row["meta_json"],
                           dedupeKey: row["dedupe_key"])
    }

    private static func sessionID(_ key: SessionKey, db: Database) throws -> Int64 {
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE agent=? AND native_id=?",
                                          arguments: [key.agent.rawValue, key.nativeID]) else { throw StoreError.missingSession }
        return id
    }

    private static func save(_ value: SessionRecord, db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO sessions(agent,native_id,source_id,file_id,environment,cwd,title,started_at,last_event_at,status,
                git_branch,cli_version,model_primary,parent_native_id)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(agent,native_id) DO UPDATE SET
            source_id=excluded.source_id,file_id=coalesce(excluded.file_id,sessions.file_id),environment=excluded.environment,
            cwd=coalesce(excluded.cwd,sessions.cwd),title=coalesce(excluded.title,sessions.title),
            started_at=min(coalesce(excluded.started_at,sessions.started_at),coalesce(sessions.started_at,excluded.started_at)),
            last_event_at=max(coalesce(excluded.last_event_at,sessions.last_event_at),coalesce(sessions.last_event_at,excluded.last_event_at)),
            status=CASE WHEN excluded.status='unknown' THEN sessions.status ELSE excluded.status END,
            git_branch=coalesce(excluded.git_branch,sessions.git_branch),cli_version=coalesce(excluded.cli_version,sessions.cli_version),
            model_primary=coalesce(excluded.model_primary,sessions.model_primary),
            parent_native_id=coalesce(excluded.parent_native_id,sessions.parent_native_id)
            WHERE NOT ?
            """).execute(arguments: [value.key.agent.rawValue, value.key.nativeID, value.sourceID, value.fileID,
                                      value.environment, value.cwd, value.title, value.startedAt, value.lastEventAt, value.status.rawValue,
                                      value.gitBranch, value.cliVersion, value.model, value.parentNativeID, value.referenceOnly == true])
        // Resolve known children even if the parent is imported after them.
        if value.key.agent == .claudeCode || value.parentNativeID != nil {
            try db.cachedStatement(sql: """
                UPDATE sessions AS child SET parent_session_id=(
                    SELECT parent.id FROM sessions AS parent
                    WHERE parent.agent=child.agent AND parent.native_id=child.parent_native_id
                        AND parent.id<>child.id
                )
                WHERE child.agent=? AND child.parent_native_id IS NOT NULL AND child.parent_session_id IS NULL
                    AND (child.native_id=? OR child.parent_native_id=?)
                """).execute(arguments: [value.key.agent.rawValue, value.key.nativeID, value.key.nativeID])
        }
    }

    private static func save(_ value: EventRecord, db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO events(session_id,seq,ts,kind,tool_name,text,meta_json,dedupe_key) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(dedupe_key) DO UPDATE SET session_id=excluded.session_id,seq=excluded.seq,ts=excluded.ts,
            kind=excluded.kind,tool_name=excluded.tool_name,text=excluded.text,meta_json=excluded.meta_json
            WHERE (events.session_id=excluded.session_id AND NOT ?)
                OR (events.session_id<>excluded.session_id AND ?)
            """).execute(arguments: [try sessionID(value.session, db: db), value.sequence, value.timestamp, value.kind.rawValue,
                              value.toolName, value.text, value.metadataJSON, value.dedupeKey,
                              value.recordedOwnership == .inherited, value.recordedOwnership != nil])
    }

    private static func save(_ value: TokenEvent, db: Database) throws {
        let c = value.counts
        guard [c.inputFresh,c.cacheRead,c.cacheWrite,c.cacheWrite1h,c.output,c.reasoning].allSatisfy({ $0 >= 0 }),
              c.reasoning <= c.output else { throw StoreError.invalidTokenCounts }
        if value.session.agent == .claudeCode {
            // Replay can correct an owner recorded before sessionId was used.
            // Changing ownership alone must not replace compatible usage with
            // an older copy or introduce a second billable response.
            let compatible = """
                token_events.agent=excluded.agent AND token_events.precision=excluded.precision
                AND (token_events.model=excluded.model OR token_events.model IS NULL OR excluded.model IS NULL)
                AND token_events.input_fresh=excluded.input_fresh AND token_events.cache_read=excluded.cache_read
                AND token_events.cache_write=excluded.cache_write AND token_events.cache_write_1h=excluded.cache_write_1h
                AND token_events.reasoning=excluded.reasoning AND excluded.output>=token_events.output
                """
            let canSetOwner = value.recordedOwnership != nil
            try db.cachedStatement(sql: """
                INSERT INTO token_events(session_id,agent,model,ts,input_fresh,cache_read,cache_write,cache_write_1h,
                    output,reasoning,precision,dedupe_key)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(dedupe_key) DO UPDATE SET
                    session_id=CASE WHEN ? THEN excluded.session_id ELSE token_events.session_id END,
                    output=CASE WHEN \(compatible) THEN excluded.output ELSE token_events.output END,
                    model=CASE WHEN \(compatible) THEN coalesce(token_events.model,excluded.model) ELSE token_events.model END
                WHERE (token_events.agent=excluded.agent AND token_events.session_id<>excluded.session_id AND ?)
                    OR (\(compatible))
                """).execute(arguments: [try sessionID(value.session, db: db), value.session.agent.rawValue, value.model,
                                          value.timestamp, c.inputFresh, c.cacheRead, c.cacheWrite, c.cacheWrite1h,
                                          c.output, c.reasoning, value.precision.rawValue, value.dedupeKey,
                                          canSetOwner, canSetOwner])
            return
        }
        try db.cachedStatement(sql: """
            INSERT INTO token_events(session_id,agent,model,ts,input_fresh,cache_read,cache_write,cache_write_1h,output,reasoning,precision,dedupe_key)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(dedupe_key) DO UPDATE SET
            agent=excluded.agent,model=excluded.model,ts=excluded.ts,input_fresh=excluded.input_fresh,
            cache_read=excluded.cache_read,cache_write=excluded.cache_write,cache_write_1h=excluded.cache_write_1h,
            output=excluded.output,reasoning=excluded.reasoning,precision=excluded.precision
            WHERE token_events.session_id=excluded.session_id
            """).execute(arguments: [try sessionID(value.session, db: db), value.session.agent.rawValue, value.model, value.timestamp,
                              c.inputFresh, c.cacheRead, c.cacheWrite, c.cacheWrite1h, c.output, c.reasoning, value.precision.rawValue, value.dedupeKey])
    }

    private static func save(_ checkpoint: Checkpoint, fileID: Int64, db: Database) throws {
        guard checkpoint.size >= 0, checkpoint.offset >= 0, checkpoint.offset <= checkpoint.size,
              checkpoint.parserVersion > 0, checkpoint.sequence >= -1, checkpoint.unknownRecords >= 0,
              (checkpoint.decoderState?.count ?? 0) <= Checkpoint.maximumDecoderStateBytes
        else { throw StoreError.invalidCheckpoint }
        try db.execute(sql: """
            UPDATE source_files SET device=?,inode=?,size=?,mtime_ns=?,read_offset=?,parser_version=?,
                last_seq=?,previous_ts=?,decoder_state=?,unknown_records=?,
                state=CASE WHEN ? < ? THEN 'partial' ELSE 'ok' END,last_error=NULL
            WHERE id=?
            """, arguments: [checkpoint.device, checkpoint.inode, checkpoint.size, checkpoint.modificationTimeNS,
                              checkpoint.offset, checkpoint.parserVersion, checkpoint.sequence,
                              checkpoint.previousTimestamp, checkpoint.decoderState, checkpoint.unknownRecords,
                              checkpoint.offset, checkpoint.size, fileID])
        guard db.changesCount == 1 else { throw StoreError.missingFile }
    }
}
