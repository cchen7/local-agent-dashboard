import ADCore
import GRDB

public enum TranscriptPagingError: Error, Equatable, Sendable {
    case invalidLimit, foreignCursor, staleCursor
}

/// An opaque position in one session's file order. A cursor avoids scanning and
/// discarding the earlier rows and is not an event identifier for navigation.
public struct TranscriptCursor: Equatable, Sendable {
    fileprivate let session: SessionKey
    fileprivate let position: TranscriptPosition
}

public enum TranscriptPageRequest: Equatable, Sendable {
    case first, last
    case before(TranscriptCursor), after(TranscriptCursor)
    /// An exact normalized event dedupe key, for example from search results.
    case around(String)
}

public struct TranscriptPage: Equatable, Sendable {
    /// Always ascending in file order, including for backward reads. A folded
    /// result travels with its call instead of occupying a second position.
    public let events: [EventRecord]
    public let toolResults: [String: EventRecord]
    public let older: TranscriptCursor?
    public let newer: TranscriptCursor?

    /// Translate a search hit on output to its visible call row.
    public func rowKey(forEvent key: String) -> String {
        toolResults.first { $0.value.dedupeKey == key }?.key ?? key
    }
}

public extension AgentStore {
    /// Return at most 256 rows and one matching result per tool row. An unknown session or match
    /// returns nil; a known empty range returns an empty page. Callers should
    /// restart navigation when a rewrite changes the file order.
    func transcriptPage(in session: SessionKey, request: TranscriptPageRequest = .first,
                        limit: Int = 128) throws -> TranscriptPage? {
        try Self.validate(request, in: session, limit: limit)
        return try databasePool.read { db in
            try Self.fetchPage(in: session, request: request, limit: limit, db: db)
        }
    }

    /// Observe the requested page as the index changes, retaining only the latest
    /// snapshot. A directional page that no longer has rows invalidates navigation,
    /// even when the anchor still exists; restart at the first page in that case.
    func transcriptPageUpdates(in session: SessionKey, request: TranscriptPageRequest = .first,
                               limit: Int = 128) throws -> some AsyncSequence<TranscriptPage?, any Error> & Sendable {
        try Self.validate(request, in: session, limit: limit)
        return ValueObservation.tracking { db in
            let page = try Self.fetchPage(in: session, request: request, limit: limit, db: db)
            switch request {
            case .before, .after:
                guard page?.events.isEmpty == false else { throw TranscriptPagingError.staleCursor }
            default: break
            }
            return page
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    private static func validate(_ request: TranscriptPageRequest, in session: SessionKey, limit: Int) throws {
        guard (1...256).contains(limit) else { throw TranscriptPagingError.invalidLimit }
        switch request {
        case .before(let cursor), .after(let cursor):
            guard cursor.session == session else { throw TranscriptPagingError.foreignCursor }
        default: break
        }
    }

    private static func fetchPage(in session: SessionKey, request: TranscriptPageRequest, limit: Int,
                                  db: Database) throws -> TranscriptPage? {
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE agent=? AND native_id=?",
                                         arguments: [session.agent.rawValue, session.nativeID])
        else { return nil }
        let paging = TranscriptPaging(db: db, sessionID: id)
        let rows: [Row]
        switch request {
        case .first: rows = try paging.rows(.later, limit: limit)
        case .last: rows = Array(try paging.rows(.earlier, limit: limit).reversed())
        case .after(let cursor):
            try paging.requirePivot(cursor.position)
            rows = try paging.rows(.later, pivot: cursor.position, limit: limit)
        case .before(let cursor):
            try paging.requirePivot(cursor.position)
            rows = Array(try paging.rows(.earlier, pivot: cursor.position, limit: limit).reversed())
        case .around(let key):
            guard let anchor = try paging.anchor(key) else { return nil }
            rows = try paging.window(around: anchor, limit: limit)
        }
        guard let first = rows.first, let last = rows.last else {
            return .init(events: [], toolResults: [:], older: nil, newer: nil)
        }
        let firstPosition = TranscriptPosition(first)
        let lastPosition = TranscriptPosition(last)
        let older = try paging.exists(.earlier, pivot: firstPosition)
            ? TranscriptCursor(session: session, position: firstPosition) : nil
        let newer = try paging.exists(.later, pivot: lastPosition)
            ? TranscriptCursor(session: session, position: lastPosition) : nil
        let pairs = try paging.toolResults(for: rows, session: session)
        return .init(events: try rows.map { try Self.readTranscriptEvent($0, in: session) },
                     toolResults: pairs, older: older, newer: newer)
    }
}

fileprivate struct TranscriptPosition: Equatable, Sendable {
    let sequence: Int64
    let rowID: Int64

    init(_ row: Row) { sequence = row["seq"]; rowID = row["id"] }
}

private struct TranscriptPaging {
    enum Direction {
        case earlier, later
        var comparison: String { self == .earlier ? "<" : ">" }
        var order: String { self == .earlier ? "e.seq DESC,e.id DESC" : "e.seq,e.id" }
    }

    let db: Database
    let sessionID: Int64

    // A pair must be the only two records for this explicit ID in the
    // session, of opposite kind, in file order. Each lookup uses the partial
    // index; stop counting at three even if an ID was repeated many times.
    private func partner(_ direction: Direction) -> String {
        let kind = direction == .earlier ? EventKind.toolCall : EventKind.toolResult
        return """
            SELECT peer.id FROM events peer
            WHERE peer.session_id=e.session_id AND peer.transcript_tool_id=e.transcript_tool_id
                AND peer.kind='\(kind.rawValue)' AND (peer.seq,peer.id)\(direction.comparison)(e.seq,e.id)
                AND (SELECT count(*) FROM (
                    SELECT 1 FROM events group_member WHERE group_member.session_id=e.session_id
                        AND group_member.transcript_tool_id=e.transcript_tool_id LIMIT 3
                ))=2
            LIMIT 1
            """
    }

    private var previousCall: String {
        "CASE WHEN e.kind='tool_result' AND e.transcript_tool_id IS NOT NULL THEN (\(partner(.earlier))) END"
    }

    private var selectRow: String {
        """
        SELECT e.*,CASE WHEN e.kind='tool_call' AND e.transcript_tool_id IS NOT NULL THEN
            (\(partner(.later))) END AS paired_result_id FROM events e
        """
    }

    func anchor(_ key: String) throws -> Row? {
        guard let id = try Int64.fetchOne(db, sql: """
            SELECT coalesce(\(previousCall),e.id) FROM events e WHERE e.dedupe_key=? AND e.session_id=?
            """, arguments: [key, sessionID]) else { return nil }
        return try Row.fetchOne(db, sql: "\(selectRow) WHERE e.id=? AND e.session_id=?", arguments: [id, sessionID])
    }

    func toolResults(for rows: [Row], session: SessionKey) throws -> [String: EventRecord] {
        var calls: [Int64: String] = [:]
        for row in rows {
            if let resultID: Int64 = row["paired_result_id"] { calls[resultID] = row["dedupe_key"] }
        }
        guard !calls.isEmpty else { return [:] }
        let ids = Array(calls.keys)
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let results = try Row.fetchAll(db, sql: """
            SELECT * FROM events WHERE session_id=? AND id IN (\(placeholders))
            """, arguments: StatementArguments([sessionID] + ids))
        var pairs: [String: EventRecord] = [:]
        for row in results {
            if let key = calls[row["id"]] { pairs[key] = try AgentStore.readTranscriptEvent(row, in: session) }
        }
        return pairs
    }

    func requirePivot(_ position: TranscriptPosition) throws {
        guard try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM events e WHERE e.id=? AND e.session_id=? AND e.seq=? AND (\(previousCall)) IS NULL)
            """, arguments: [position.rowID, sessionID, position.sequence]) == true else {
            throw TranscriptPagingError.staleCursor
        }
    }

    func rows(_ direction: Direction, pivot: TranscriptPosition? = nil, limit: Int) throws -> [Row] {
        guard limit > 0 else { return [] }
        if let pivot {
            return try Row.fetchAll(db, sql: """
                \(selectRow) WHERE e.session_id=? AND (e.seq,e.id)\(direction.comparison)(?,?)
                    AND (\(previousCall)) IS NULL ORDER BY \(direction.order) LIMIT ?
                """, arguments: [sessionID, pivot.sequence, pivot.rowID, limit])
        }
        return try Row.fetchAll(db, sql: """
            \(selectRow) WHERE e.session_id=? AND (\(previousCall)) IS NULL ORDER BY \(direction.order) LIMIT ?
            """, arguments: [sessionID, limit])
    }

    func exists(_ direction: Direction, pivot: TranscriptPosition) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM events e WHERE e.session_id=? AND (e.seq,e.id)\(direction.comparison)(?,?)
                AND (\(previousCall)) IS NULL)
            """, arguments: [sessionID, pivot.sequence, pivot.rowID]) == true
    }

    func window(around row: Row, limit: Int) throws -> [Row] {
        let pivot = TranscriptPosition(row)
        var older = try rows(.earlier, pivot: pivot, limit: (limit - 1) / 2)
        let newer = try rows(.later, pivot: pivot, limit: limit - 1 - older.count)
        // Fill remaining capacity at either end of the session.
        if older.count + newer.count < limit - 1 {
            older = try rows(.earlier, pivot: pivot, limit: limit - 1 - newer.count)
        }
        return Array(older.reversed()) + [row] + newer
    }
}
