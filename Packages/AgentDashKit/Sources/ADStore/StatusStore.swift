import ADCore
import GRDB

/// File-order status inputs deliberately exclude the transcript and tool output text.
public struct StatusEventMetadata: Sendable {
    public let sequence: Int64
    public let timestamp: Int64?
    public let kind: EventKind
    public let metadataJSON: String?
}

public struct StatusWorkItem: Sendable {
    public let id: Int64
    public let agent: AgentKind
    public let revision: Int64
    public let archived: Bool
    public let events: [StatusEventMetadata]
}

public struct PersistedStatusUpdate: Sendable {
    public let id: Int64
    public let revision: Int64
    public let status: SessionStatus
    public let reason: String
    public let nextAt: Int64?

    public init(id: Int64, revision: Int64, status: SessionStatus, reason: String, nextAt: Int64?) {
        self.id = id; self.revision = revision; self.status = status; self.reason = reason; self.nextAt = nextAt
    }
}

public extension AgentStore {
    struct StatusSchedule: Equatable, Sendable {
        public let hasDirtySessions: Bool
        public let nextDeadline: Int64?
    }

    func statusScheduleUpdates() -> some AsyncSequence<StatusSchedule, any Error> & Sendable {
        ValueObservation.tracking { db in
            StatusSchedule(
                hasDirtySessions: try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE status_dirty=1)") == true,
                nextDeadline: try Int64.fetchOne(db, sql: "SELECT min(status_next_at) FROM sessions WHERE status_next_at IS NOT NULL"))
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    /// Record which saved preferences the derived index reflects. Invalidate
    /// both the deadlines and the revision of any in-flight evaluation.
    func activateStatusPolicy(_ policy: String) throws {
        try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('status_policy',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE value<>excluded.value
                """, arguments: [policy])
            if db.changesCount > 0 {
                try db.execute(sql: """
                    UPDATE sessions SET status_revision=status_revision+1,status_dirty=1,status_next_at=NULL
                    """)
            }
        }
    }

    func hasPendingStatusWork(at now: Int64, policy: String? = nil) throws -> Bool {
        try databasePool.read { db in
            guard try Self.isActiveStatusPolicy(policy, in: db) else { return false }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sessions WHERE status_dirty=1 OR status_next_at<=?)",
                                     arguments: [now]) == true
        }
    }

    func statusWork(at now: Int64, afterID: Int64 = 0, limit: Int = 8) throws -> [StatusWorkItem] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT id,agent,status_revision,source_deleted_at IS NOT NULL AS archived FROM sessions
                WHERE id>? AND (status_dirty=1 OR status_next_at<=?) ORDER BY id LIMIT ?
                """, arguments: [afterID, now, max(1, min(16, limit))]).map { session in
                    let id: Int64 = session["id"]
                    let archived: Bool = session["archived"]
                    guard let agent = AgentKind(rawValue: session["agent"]) else { throw StoreError.invalidStoredValue }
                    let signals: [StatusEventMetadata] = archived ? [] : try Row.fetchAll(db, sql: """
                        SELECT seq,ts,kind,CASE WHEN length(CAST(meta_json AS BLOB))<=2048 THEN meta_json END AS meta_json
                        FROM events WHERE session_id=? AND kind NOT IN ('unknown','prompt_history','thinking')
                        ORDER BY seq DESC,id DESC LIMIT 8192
                        """, arguments: [id]).map { event in
                            guard let kind = EventKind(rawValue: event["kind"]) else { throw StoreError.invalidStoredValue }
                            let time: Int64 = event["ts"]
                            return StatusEventMetadata(sequence: event["seq"], timestamp: time == 0 ? nil : time,
                                                       kind: kind, metadataJSON: event["meta_json"])
                        }
                    return StatusWorkItem(id: id, agent: agent, revision: session["status_revision"],
                                          archived: archived, events: Array(signals.reversed()))
                }
        }
    }

    /// Do not persist a computation if another parser batch changed the same session.
    /// Returns only status/reason changes, not timer updates, for search invalidation.
    func applyStatuses(_ updates: [PersistedStatusUpdate], policy: String? = nil) throws -> Int {
        guard !updates.isEmpty else { return 0 }
        return try databasePool.write { db in
            guard try Self.isActiveStatusPolicy(policy, in: db) else { return 0 }
            var changed = 0
            for update in updates {
                guard let row = try Row.fetchOne(db, sql: "SELECT status,status_reason FROM sessions WHERE id=? AND status_revision=?",
                                                 arguments: [update.id, update.revision]) else { continue }
                let oldStatus: String = row["status"]
                let oldReason: String? = row["status_reason"]
                try db.execute(sql: """
                    UPDATE sessions SET status=?,status_reason=?,status_dirty=0,status_next_at=? WHERE id=?
                    """, arguments: [update.status.rawValue, update.reason, update.nextAt, update.id])
                if oldStatus != update.status.rawValue || oldReason != update.reason { changed += 1 }
            }
            return changed
        }
    }

    private static func isActiveStatusPolicy(_ policy: String?, in db: Database) throws -> Bool {
        guard let policy else { return true }
        return try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key='status_policy'") == policy
    }
}
