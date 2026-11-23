import GRDB

public extension AgentStore {
    func indexThinkingBlocksEnabled() throws -> Bool {
        try databasePool.read { try ThinkingPrivacy.enabled($0) }
    }

    /// Enable on the next explicitly started scan. Disabling immediately
    /// removes the feature's live index rows, even for archived sessions.
    @discardableResult
    func setIndexThinkingBlocksEnabled(_ enabled: Bool) throws -> Bool {
        try databasePool.write { db in
            guard try ThinkingPrivacy.enabled(db) != enabled else { return false }
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('privacy_index_plaintext_thinking',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [enabled ? "1" : "0"])
            if enabled {
                try db.execute(sql: """
                    UPDATE source_files SET parser_version=0,decoder_state=NULL
                    WHERE role IN ('session','subagent') AND state<>'gone'
                        AND source_id IN (SELECT id FROM sources WHERE agent='claude_code' AND removed=0)
                    """)
            } else {
                try db.execute(sql: "DELETE FROM events WHERE kind='thinking'")
            }
            return true
        }
    }
}

enum ThinkingPrivacy {
    static func enabled(_ db: Database) throws -> Bool {
        switch try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key='privacy_index_plaintext_thinking'") {
        case nil, "0": false
        case "1": true
        default: throw StoreError.invalidStoredValue
        }
    }
}
