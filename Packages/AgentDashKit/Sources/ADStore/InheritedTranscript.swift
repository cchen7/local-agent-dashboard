import ADCore
import GRDB

public struct InheritedTranscriptSummary: Equatable, Sendable {
    public let originalTitle: String?
}

public struct InheritedTranscriptCursor: Equatable, Sendable {
    fileprivate let child: SessionKey
    fileprivate let fileID: Int64
    fileprivate let position: InheritedPosition
}

public enum InheritedTranscriptRequest: Equatable, Sendable {
    case first
    case before(InheritedTranscriptCursor)
    case after(InheritedTranscriptCursor)
}

public struct InheritedTranscriptPage: Equatable, Sendable {
    public let events: [EventRecord]
    public let older: InheritedTranscriptCursor?
    public let newer: InheritedTranscriptCursor?
}

public extension AgentStore {
    /// A cheap, text-free observation used while the inherited section is folded.
    func inheritedTranscriptSummary(in child: SessionKey)
    -> some AsyncSequence<InheritedTranscriptSummary?, any Error> & Sendable {
        ValueObservation.tracking { db in
            guard let scope = try InheritedScope(child, db: db),
                  let first = try Int64.fetchOne(db, sql: """
                    SELECT owner_id FROM inherited_transcript_items
                    WHERE child_id=? AND file_id=? ORDER BY owner_id LIMIT 1
                    """, arguments: [scope.childID, scope.fileID]) else {
                return nil as InheritedTranscriptSummary?
            }
            let last = try Int64.fetchOne(db, sql: """
                SELECT owner_id FROM inherited_transcript_items
                WHERE child_id=? AND file_id=? ORDER BY owner_id DESC LIMIT 1
                """, arguments: [scope.childID, scope.fileID])
            let title = first == last ? try String.fetchOne(db, sql: """
                SELECT CASE WHEN trim(coalesce(title,''))<>'' THEN title ELSE native_id END
                FROM sessions WHERE id=?
                """, arguments: [first]) : nil
            return InheritedTranscriptSummary(originalTitle: title)
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    /// Consult only confirmed copies in the current physical transcript's order.
    /// Do not enumerate or seek within the original session's transcript.
    func inheritedTranscriptPages(in child: SessionKey, request: InheritedTranscriptRequest = .first,
                                  limit: Int = 64) throws
    -> some AsyncSequence<InheritedTranscriptPage, any Error> & Sendable {
        guard (1...128).contains(limit) else { throw TranscriptPagingError.invalidLimit }
        return ValueObservation.tracking { db in
            try InheritedScope.page(in: child, request: request, limit: limit, db: db)
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }
}

extension AgentStore {
    static func recordInheritedTranscript(_ event: EventRecord, in location: InheritedTranscriptLocation,
                                          fileID: Int64, db: Database) throws {
        guard event.recordedOwnership == .inherited, event.session.agent == .claudeCode,
              location.child.agent == .claudeCode, event.session != location.child, event.kind != .unknown,
              event.sequence >= 0, (0..<240).contains(location.block) else { return }
        try db.cachedStatement(sql: """
            INSERT INTO inherited_transcript_items(file_id,child_id,event_id,owner_id,copy_seq,block)
            SELECT f.id,c.id,e.id,o.id,?,?
            FROM events e JOIN sessions o ON o.id=e.session_id
                JOIN sessions c ON c.agent='claude_code' AND c.native_id=?
                JOIN source_files f ON f.id=c.file_id AND f.id=? AND f.role='session'
            WHERE o.agent='claude_code' AND o.native_id=? AND c.id<>o.id
                AND e.dedupe_key=? AND e.kind=? AND e.text IS ? AND e.tool_name IS ?
            ON CONFLICT(file_id,event_id) DO NOTHING
            """).execute(arguments: [event.sequence, location.block, location.child.nativeID, fileID,
                                      event.session.nativeID, event.dedupeKey, event.kind.rawValue,
                                      event.text, event.toolName])
    }
}

fileprivate struct InheritedPosition: Equatable, Sendable {
    let sequence: Int64
    let block: Int
    let eventID: Int64

    init(_ row: Row) {
        sequence = row["copy_seq"]
        block = row["block"]
        eventID = row["event_id"]
    }

    var arguments: StatementArguments { [sequence, block, eventID] }
}

private struct InheritedScope {
    let childID: Int64
    let fileID: Int64

    init?(_ child: SessionKey, db: Database) throws {
        guard child.agent == .claudeCode,
              let row = try Row.fetchOne(db, sql: """
                SELECT s.id,f.id AS file_id FROM sessions s JOIN source_files f ON f.id=s.file_id
                WHERE s.agent=? AND s.native_id=? AND f.role='session'
                """, arguments: [child.agent.rawValue, child.nativeID]) else { return nil }
        childID = row["id"]
        fileID = row["file_id"]
    }

    private var arguments: StatementArguments { [childID, fileID] }

    static func page(in child: SessionKey, request: InheritedTranscriptRequest, limit: Int,
                     db: Database) throws -> InheritedTranscriptPage {
        let forward: Bool
        let cursor: InheritedTranscriptCursor?
        switch request {
        case .first: (forward, cursor) = (true, nil)
        case .before(let value): (forward, cursor) = (false, value)
        case .after(let value): (forward, cursor) = (true, value)
        }
        if let cursor, cursor.child != child { throw TranscriptPagingError.foreignCursor }
        let empty = InheritedTranscriptPage(events: [], older: nil, newer: nil)
        guard let scope = try InheritedScope(child, db: db) else { return empty }
        if let cursor {
            guard cursor.fileID == scope.fileID, try scope.exists(cursor.position, operator: "=", db: db) else {
                throw TranscriptPagingError.staleCursor
            }
        }

        let order = forward ? "ASC" : "DESC"
        let bounds = cursor == nil ? "" : "AND (r.copy_seq,r.block,r.event_id) \(forward ? ">" : "<") (?,?,?)"
        var arguments = scope.arguments
        if let cursor { arguments += cursor.position.arguments }
        arguments += [limit]
        let rows = try Row.fetchAll(db, sql: """
            SELECT e.*, r.copy_seq,r.block,r.event_id,s.native_id AS owner_native_id
            FROM inherited_transcript_items r JOIN events e ON e.id=r.event_id AND e.session_id=r.owner_id
            JOIN sessions s ON s.id=r.owner_id
            WHERE r.child_id=? AND r.file_id=? \(bounds)
            ORDER BY r.copy_seq \(order),r.block \(order),r.event_id \(order) LIMIT ?
            """, arguments: arguments)
        let ascending = forward ? rows : Array(rows.reversed())
        guard let first = ascending.first, let last = ascending.last else {
            if cursor != nil { throw TranscriptPagingError.staleCursor }
            return empty
        }
        let start = InheritedPosition(first), end = InheritedPosition(last)
        let older = try scope.exists(start, operator: "<", db: db)
            ? InheritedTranscriptCursor(child: child, fileID: scope.fileID, position: start) : nil
        let newer = try scope.exists(end, operator: ">", db: db)
            ? InheritedTranscriptCursor(child: child, fileID: scope.fileID, position: end) : nil
        return InheritedTranscriptPage(events: try ascending.map { row in
            try AgentStore.readTranscriptEvent(row, in: .init(agent: .claudeCode, nativeID: row["owner_native_id"]))
        }, older: older, newer: newer)
    }

    private func exists(_ position: InheritedPosition, operator comparison: String, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM inherited_transcript_items
                WHERE child_id=? AND file_id=? AND (copy_seq,block,event_id) \(comparison) (?,?,?))
            """, arguments: arguments + position.arguments) == true
    }
}
