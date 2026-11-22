import GRDB

public extension AgentStore {
    /// An existing library should not be interrupted by first-run setup.
    func needsSourceOnboarding() throws -> Bool {
        try databasePool.read { db in
            if try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key='source_onboarding'") == "complete" {
                return false
            }
            return try Bool.fetchOne(db, sql: "SELECT NOT EXISTS(SELECT 1 FROM sessions)") == true
        }
    }

    /// Keep the decision entirely in the app-owned index.
    func completeSourceOnboarding() throws {
        try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('source_onboarding','complete')
                ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value<>excluded.value
                """)
        }
    }
}
