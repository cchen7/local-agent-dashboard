import ADCore
import GRDB

/// Metadata for the Sessions page. Transcript text is read separately, one page at a time.
public struct IndexedSession: Identifiable, Equatable, Sendable {
    public let id: SessionKey
    public let title: String?
    public let workspace: String?
    public let branch: String?
    public let environment: String
    public let status: SessionStatus
    public let statusReason: String?
    public let startedAt: Int64?
    public let lastActivity: Int64?
    public let archived: Bool
    public let usage: IndexedSessionUsageSummary?

    init(_ row: Row, usage: IndexedSessionUsageSummary? = nil) throws {
        guard let agent = AgentKind(rawValue: row["agent"]),
              let status = SessionStatus(rawValue: row["status"])
        else { throw StoreError.invalidStoredValue }
        id = .init(agent: agent, nativeID: row["native_id"])
        title = row["title"]
        workspace = row["cwd"]
        branch = row["git_branch"]
        environment = row["environment"]
        self.status = status
        statusReason = row["status_reason"]
        startedAt = row["started_at"]
        lastActivity = row["activity"]
        archived = (row["source_deleted_at"] as Int64?) != nil
        self.usage = usage
    }
}

public extension AgentStore {
    /// Observe session metadata and committed usage in activity order, with stable ties.
    /// One indexed join; list observation does not scan or group the token ledger.
    func indexedSessionUpdates() -> some AsyncSequence<[IndexedSession], any Error> & Sendable {
        ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: """
                SELECT s.agent,s.native_id,s.title,s.cwd,s.git_branch,s.environment,s.status,s.status_reason,s.started_at,
                       coalesce(s.last_event_at,s.started_at) AS activity,s.source_deleted_at,
                       u.session_id AS usage_session_id,u.input_fresh,u.cache_read,u.cache_write,u.cache_write_1h,
                       u.output,u.reasoning,u.cost_micro_usd,u.unpriced_tokens,u.records,u.approximate_records
                FROM sessions s LEFT JOIN session_usage_rollup u ON u.session_id=s.id
                ORDER BY activity DESC,s.id DESC
                """).map { row in
                    let usage = IndexedSessionUsageSummary((row["usage_session_id"] as Int64?) == nil ? nil : row)
                    return try IndexedSession(row, usage: usage)
                }
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }
}
