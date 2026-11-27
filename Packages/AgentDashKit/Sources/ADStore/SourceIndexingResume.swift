import GRDB

public extension AgentStore {
    /// DEV-109: record whether a registered source resumes indexing at the
    /// next launch. A removed or unknown source is left unchanged.
    func setResumesIndexing(_ resumes: Bool, sourceID: Int64) throws {
        try databasePool.write { db in
            // Skip a no-op so a launch resume does not wake `sources` observers.
            try db.execute(sql: "UPDATE sources SET resume_indexing=? WHERE id=? AND removed=0 AND resume_indexing IS NOT ?",
                           arguments: [resumes, sourceID, resumes])
        }
    }

    /// Enabled, registered sources the user left indexing, in source order.
    func sourceIDsResumingIndexing() throws -> [Int64] {
        try databasePool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT id FROM sources WHERE resume_indexing=1 AND enabled=1 AND removed=0 ORDER BY id
                """)
        }
    }
}
