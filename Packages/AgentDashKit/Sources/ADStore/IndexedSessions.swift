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

    init(_ row: Row) throws {
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
    }
}

public extension AgentStore {
    /// Observe app-owned session metadata ordered by newest activity with stable ties.
    func indexedSessionUpdates() -> some AsyncSequence<[IndexedSession], any Error> & Sendable {
        ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: """
                SELECT agent,native_id,title,cwd,git_branch,environment,status,status_reason,started_at,
                       coalesce(last_event_at,started_at) AS activity,source_deleted_at
                FROM sessions ORDER BY activity DESC,id DESC
                """).map(IndexedSession.init)
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }
}
