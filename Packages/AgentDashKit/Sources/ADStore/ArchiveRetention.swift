import ADCore
import CryptoKit
import Foundation
import GRDB

public enum ArchiveRetention: Int, CaseIterable, Sendable {
    case forever = 0, oneYear = 365, halfYear = 180, quarterYear = 90
}

public extension AgentStore {
    func archiveRetention() throws -> ArchiveRetention {
        try databasePool.read { try ArchiveRetentionStore.policy($0) }
    }

    /// Save the policy and apply any due expiry in the same index transaction.
    @discardableResult
    func setArchiveRetention(_ policy: ArchiveRetention, now: Int64, hostHome: String?) throws -> Int {
        try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('archive_retention_days',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [String(policy.rawValue)])
            return try ArchiveRetentionStore.expire(policy, now: now, hostHome: hostHome, db: db)
        }
    }

    @discardableResult
    func expireArchivedSessions(now: Int64, hostHome: String?) throws -> Int {
        try databasePool.write { db in
            try ArchiveRetentionStore.expire(ArchiveRetentionStore.policy(db), now: now, hostHome: hostHome, db: db)
        }
    }
}

enum ArchiveRetentionStore {
    static func policy(_ db: Database) throws -> ArchiveRetention {
        guard let raw = try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key='archive_retention_days'")
        else { return .forever }
        guard let days = Int(raw), let policy = ArchiveRetention(rawValue: days) else { throw StoreError.invalidStoredValue }
        return policy
    }

    static func expire(_ policy: ArchiveRetention, now: Int64, hostHome: String?, db: Database) throws -> Int {
        guard policy != .forever else { return 0 }
        let threshold = now.subtractingReportingOverflow(Int64(policy.rawValue) * 86_400_000)
        guard !threshold.overflow else { return 0 }
        let rows = try Row.fetchAll(db, sql: """
            SELECT id,agent,native_id,source_id,cwd FROM sessions WHERE source_deleted_at<=? ORDER BY id
            """, arguments: [threshold.partialValue])
        guard !rows.isEmpty else { return 0 }
        try Task.checkCancellation()
        let expired = Set(rows.map { $0["id"] as Int64 })
        var projects: [Int64: (key: Data, name: String, context: String)] = [:]
        for project in try AgentStore.projectCatalog(db, hostHome: hostHome) {
            let key = project.id.retentionKey
            let context = [project.path, project.location].compactMap { $0 }.joined(separator: " · ")
            for id in project.activityScope.sessionIDs where expired.contains(id) {
                projects[id] = (key, project.name, context)
            }
        }
        try db.execute(sql: """
            CREATE TEMP TABLE expiry_sessions(id INTEGER PRIMARY KEY,scope_id INTEGER NOT NULL);
            CREATE TEMP TABLE expiry_refs(kind TEXT NOT NULL,id INTEGER NOT NULL,PRIMARY KEY(kind,id)) WITHOUT ROWID;
            """)
        let stage = try db.cachedStatement(sql: "INSERT INTO temp.expiry_sessions VALUES(?,?)")
        let keyInsert = try db.cachedStatement(sql: "INSERT INTO expired_archive_sessions VALUES(?,?)")
        for row in rows {
            try Task.checkCancellation()
            let id: Int64 = row["id"]
            let mapping = projects[id]
            let source: Int64 = row["source_id"]
            let cwd: String = (row["cwd"] as String?) ?? ""
            try db.execute(sql: """
                INSERT INTO retained_archive_scopes(source_id,project_key,label,location,workspace) VALUES(?,?,?,?,?)
                ON CONFLICT(source_id,project_key,workspace) DO NOTHING
                """, arguments: [source, mapping?.key ?? Data(), mapping?.name, mapping?.context, cwd])
            guard let scope = try Int64.fetchOne(db, sql: """
                SELECT id FROM retained_archive_scopes WHERE source_id=? AND project_key=? AND workspace=?
                """, arguments: [source, mapping?.key ?? Data(), cwd]),
                let agent = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
            let key = SessionKey(agent: agent, nativeID: row["native_id"])
            try stage.execute(arguments: [id, scope])
            try keyInsert.execute(arguments: [digest(key), scope])
        }
        let tokenInsert = try db.cachedStatement(sql: "INSERT INTO expired_archive_tokens VALUES(?,?)")
        do {
            let curs = try Row.fetchCursor(db, sql: """
                SELECT t.dedupe_key,s.scope_id FROM temp.expiry_sessions s JOIN token_events t ON t.session_id=s.id
                """)
            while let row = try curs.next() {
                try Task.checkCancellation()
                let key: String = row["dedupe_key"]
                let scope: Int64 = row["scope_id"]
                try tokenInsert.execute(arguments: [tokenDigest(key), scope])
            }
        }
        try db.execute(sql: """
            CREATE TEMP TABLE expiry_usage AS
            SELECT s.scope_id,t.ts,t.agent,coalesce(t.project_id,0) AS project_id,
                coalesce(t.model,'') AS model,t.precision,
                sum(t.input_fresh) AS input_fresh,sum(t.cache_read) AS cache_read,sum(t.cache_write) AS cache_write,
                sum(t.cache_write_1h) AS cache_write_1h,sum(t.output) AS output,sum(t.reasoning) AS reasoning,
                sum(t.cost_micro_usd) AS cost_micro_usd,
                sum(CASE WHEN t.price_status='unpriced' THEN t.input_fresh+t.cache_read+t.cache_write+t.cache_write_1h+t.output ELSE 0 END) AS unpriced_tokens,
                count(*) AS records,
                sum(CASE WHEN t.cache_read>0 THEN coalesce(t.cache_savings_micro_usd,0) ELSE 0 END) AS savings_micro_usd,
                sum(CASE WHEN t.cache_read>0 AND t.cache_savings_micro_usd IS NOT NULL THEN t.cache_read ELSE 0 END) AS measured_cache_read
            FROM temp.expiry_sessions s JOIN token_events t ON t.session_id=s.id GROUP BY 1,2,3,4,5,6;
            INSERT OR IGNORE INTO temp.expiry_refs SELECT 'blob',blob_id FROM events
                WHERE blob_id IS NOT NULL AND session_id IN (SELECT id FROM temp.expiry_sessions);
            INSERT OR IGNORE INTO temp.expiry_refs SELECT 'basis',rate_basis_id FROM token_events
                WHERE rate_basis_id IS NOT NULL AND session_id IN (SELECT id FROM temp.expiry_sessions);
            UPDATE sessions SET parent_session_id=NULL WHERE parent_session_id IN (SELECT id FROM temp.expiry_sessions);
            UPDATE sessions SET resumed_from_session_id=NULL WHERE resumed_from_session_id IN (SELECT id FROM temp.expiry_sessions);
            UPDATE source_files SET decoder_state=NULL,parser_version=0 WHERE id IN (
                SELECT file_id FROM sessions WHERE id IN (SELECT id FROM temp.expiry_sessions));
            DELETE FROM sessions WHERE id IN (SELECT id FROM temp.expiry_sessions);
            """)
        guard db.changesCount == rows.count else { throw StoreError.invalidStoredValue }
        // Subtract the raw rows before adding their detached contribution so
        // a large valid total is never temporarily doubled in the writer.
        try db.execute(sql: """
            INSERT INTO retained_archive_usage(scope_id,ts,agent,project_id,model,precision,input_fresh,cache_read,cache_write,
                cache_write_1h,output,reasoning,cost_micro_usd,unpriced_tokens,records,savings_micro_usd,measured_cache_read)
            SELECT * FROM temp.expiry_usage;
            DELETE FROM blobs WHERE id IN (SELECT id FROM temp.expiry_refs WHERE kind='blob')
                AND NOT EXISTS(SELECT 1 FROM events WHERE blob_id=blobs.id);
            DELETE FROM token_rate_bases WHERE id IN (SELECT id FROM temp.expiry_refs WHERE kind='basis')
                AND NOT EXISTS(SELECT 1 FROM token_events WHERE rate_basis_id=token_rate_bases.id);
            DROP TABLE temp.expiry_usage;
            DROP TABLE temp.expiry_refs;
            DROP TABLE temp.expiry_sessions;
            """)
        try UsageChartChanges.publish(db)
        return rows.count
    }

    /// Session exclusions copy these digests from expired archives, so both use this one.
    static func digest(_ key: SessionKey) -> Data {
        Data(SHA256.hash(data: Data((key.agent.rawValue + "\u{0}" + key.nativeID).utf8)))
    }

    private static func tokenDigest(_ key: String) -> Data { Data(SHA256.hash(data: Data(key.utf8))) }

    /// A retained aggregate replaces an expired session. Do not re-admit its
    /// raw rows or bill a repeated global token key under a different owner.
    static func screen(_ records: [NormalizedRecord], db: Database) throws -> [NormalizedRecord] {
        guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM expired_archive_sessions)") == true else { return records }
        let sessionCheck = try db.cachedStatement(sql: "SELECT 1 FROM expired_archive_sessions WHERE digest=?")
        let tokenCheck = try db.cachedStatement(sql: "SELECT 1 FROM expired_archive_tokens WHERE digest=?")
        var known: [Data: Bool] = [:]
        return try records.filter { record in
            let key: SessionKey
            switch record {
            case .session(let value): key = value.key
            case .event(let value): key = value.session
            case .tokens(let value):
                key = value.session
                if try Int.fetchOne(tokenCheck, arguments: [tokenDigest(value.dedupeKey)]) != nil { return false }
            case .copilotUsageSnapshot(let value): key = value.session
            case .removeEmptyPlaceholder(let value, _, _, _), .removeCopilotUsagePlaceholder(let value, _, _, _, _): key = value
            case .rateLimit: return true
            }
            let hash = digest(key)
            if let blocked = known[hash] { return !blocked }
            let blocked = try Int.fetchOne(sessionCheck, arguments: [hash]) != nil
            known[hash] = blocked
            return !blocked
        }
    }
}
