import ADCore
import GRDB

public extension AgentStore {
    /// Read only the selected session's measurements. Changes to the editor
    /// are resolved independently by the caller.
    func sessionContextUpdates(in session: SessionKey)
    -> some AsyncSequence<IndexedSessionContext?, any Error> & Sendable {
        ValueObservation.tracking { db in
            try Row.fetchOne(db, sql: """
                SELECT context_used,context_window,context_model FROM sessions
                WHERE agent=? AND native_id=?
                """, arguments: [session.agent.rawValue, session.nativeID]).map { row in
                    IndexedSessionContext(input: row["context_used"], capacity: row["context_window"], model: row["context_model"])
                }
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }
}

public struct IndexedSessionContext: Equatable, Sendable {
    public let input: Int64?
    public let capacity: Int64?
    public let model: String?
}
