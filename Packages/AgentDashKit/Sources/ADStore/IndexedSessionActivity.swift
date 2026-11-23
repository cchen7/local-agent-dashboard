import ADCore
import GRDB

/// Derived with the same revision and clock as the running status. This contains
/// references only; commands, paths and other tool arguments are not duplicated.
public struct PersistedRunningActivity: Sendable {
    public enum Action: String, Sendable {
        case pendingTool, toolFinished, turnFinished, recentActivity
    }

    public let action: Action
    public let callEventID: Int64?
    public let startedAt: Int64?
    public let lastEventAt: Int64?

    public init(action: Action, callEventID: Int64? = nil, startedAt: Int64? = nil, lastEventAt: Int64?) {
        self.action = action
        self.callEventID = callEventID
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
    }
}

/// One running session's evidence from the app index. The optional fields may
/// contain sensitive values; project them through the presentation masker.
public struct IndexedSessionActivity: Equatable, Sendable {
    public let action: PersistedRunningActivity.Action
    public let startedAt: Int64?
    public let lastEventAt: Int64?
    public let toolName: String?
    public let toolInput: String?
    public let toolMetadata: String?
}

public extension AgentStore {
    func sessionActivityUpdates(in session: SessionKey)
    -> some AsyncSequence<IndexedSessionActivity?, any Error> & Sendable {
        ValueObservation.tracking { db in try Self.readSessionActivity(session, db: db) }
            .removeDuplicates()
            .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    private static func readSessionActivity(_ session: SessionKey, db: Database) throws -> IndexedSessionActivity? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.activity_action,s.activity_started_at,s.activity_last_event_at,
                   CASE WHEN length(CAST(e.tool_name AS BLOB))<=512 THEN e.tool_name END AS tool_name,
                   CASE WHEN length(CAST(e.text AS BLOB))<2045 THEN e.text END AS tool_input,
                   CASE WHEN length(CAST(e.meta_json AS BLOB))<=8192 THEN e.meta_json END AS tool_metadata
            FROM sessions s LEFT JOIN events e ON e.id=s.activity_call_event_id AND e.session_id=s.id AND e.kind='tool_call'
            WHERE s.agent=? AND s.native_id=? AND s.status='running' AND s.status_dirty=0 AND s.source_deleted_at IS NULL
                  AND s.activity_action IS NOT NULL AND (s.activity_call_event_id IS NULL OR e.id IS NOT NULL)
            """, arguments: [session.agent.rawValue, session.nativeID]) else { return nil }
        guard let action = PersistedRunningActivity.Action(rawValue: row["activity_action"]) else {
            throw StoreError.invalidStoredValue
        }
        let startedAt: Int64? = row["activity_started_at"]
        let lastEventAt: Int64? = row["activity_last_event_at"]
        let toolName: String? = row["tool_name"]
        let toolInput: String? = row["tool_input"]
        let toolMetadata: String? = row["tool_metadata"]
        return .init(action: action, startedAt: startedAt, lastEventAt: lastEventAt, toolName: toolName,
                     toolInput: toolInput, toolMetadata: toolMetadata)
    }
}
