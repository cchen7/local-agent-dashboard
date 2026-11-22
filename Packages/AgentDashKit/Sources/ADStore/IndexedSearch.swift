import ADCore
import Foundation
import GRDB

/// FR-SR: inputs resolved by the caller, independent of stored event timestamps (UTC ms).
public struct IndexedSearchScope: Equatable, Sendable {
    public let now: Int64
    public let timeZone: TimeZone
    public let hostHome: String?
    public let libraryFilter: SessionLibraryFilter?

    public init(now: Int64, timeZone: TimeZone, hostHome: String? = nil, libraryFilter: SessionLibraryFilter? = nil) {
        self.now = now
        self.timeZone = timeZone
        self.hostHome = hostHome
        self.libraryFilter = libraryFilter
    }
}

public enum IndexedSearchFailure: Error, Equatable, Sendable {
    case invalidFilter, invalidLimit, unavailable
}

public enum SessionSearchOrder: String, CaseIterable, Sendable {
    case relevance, recent, tokens
}

/// Internal index result. Project the complete text before showing any excerpt.
public struct IndexedSearchGroup: Sendable {
    public let session: SessionKey
    public let matchCount: Int
    public let firstMatchKey: String
    public let bestText: String?
    public let bestTool: String?
}

public struct IndexedSearchSnapshot: Sendable {
    public let groups: [IndexedSearchGroup]
    public let sessionCount: Int
    public let matchCount: Int
}

/// A single session's active search match and adjacent keys in transcript order.
public struct IndexedSearchMatchPosition: Equatable, Sendable {
    public let eventKey: String
    public let ordinal: Int
    public let count: Int
    public let previousKey: String?
    public let nextKey: String?
}

public extension AgentStore {
    /// Signal once on subscription and again when a search input is committed.
    /// FTS is maintained by event triggers; search also reads session metadata,
    /// project names and file touches. The observer doesn't run the query.
    func searchIndexChanges(order: SessionSearchOrder = .relevance) -> some AsyncSequence<Void, any Error> & Sendable {
        var regions: [any DatabaseRegionConvertible] = [
            Table("events"), Table("sessions"), Table("projects"), Table("file_touches"), Table("app_meta"),
        ]
        if order == .tokens { regions.append(Table("token_events")) }
        return ValueObservation.tracking(regions: regions, fetch: { _ in () })
            .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    /// Use the search box's literal query and eligibility rules. Restrict the
    /// FTS posting scan to the selected session's row ID range.
    internal static func overviewSearchableTopics(_ terms: [String], in sessionID: Int64, db: Database) throws -> [String] {
        guard !terms.isEmpty,
              let bounds = try Row.fetchOne(db, sql: "SELECT min(id),max(id) FROM events WHERE session_id=?",
                                            arguments: [sessionID]),
              let first = bounds[0] as Int64?, let last = bounds[1] as Int64? else { return [] }
        return try terms.filter { term in
            guard let query = try? SearchQuery.parse(SearchQuery.quotedLiteral(term)) else { return false }
            var statement = try SearchStatement(query, scope: .init(now: 0, timeZone: .gmt))
            guard statement.usesFTS else { return false }
            statement.restrictFTS(to: sessionID, eventIDs: first...last)
            return try Bool.fetchOne(db, sql: "SELECT EXISTS(\(statement.sql))",
                                     arguments: .init(statement.arguments)) == true
        }
    }

    /// Find and group normalized index records in one read snapshot. The database
    /// returns full display candidates for the selected groups only.
    func searchIndex(_ query: SearchQuery, scope: IndexedSearchScope,
                     order: SessionSearchOrder = .relevance, limit: Int = 50, offset: Int = 0) throws -> IndexedSearchSnapshot {
        guard (1...100).contains(limit), offset >= 0 else { throw IndexedSearchFailure.invalidLimit }
        guard !query.groups.isEmpty || !query.filters.isEmpty else {
            return .init(groups: [], sessionCount: 0, matchCount: 0)
        }
        let compiled = try SearchStatement(query, scope: scope)
        do {
            return try databasePool.read { db in
                // This pragma is reader-local. Let SQLite avoid copying hot
                // pages for FTS lookups, with a fixed mapping size.
                if compiled.usesFTS { _ = try? Int.fetchOne(db, sql: "PRAGMA mmap_size=67108864") }
                return try Self.search(compiled, now: scope.now, order: order, limit: limit, offset: offset, db: db)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Do not surface SQLite errors containing raw query arguments.
            throw IndexedSearchFailure.unavailable
        }
    }

    /// Resolve a preferred match in a single committed snapshot. If it is no
    /// longer a hit (or belongs to another session), start at the first one.
    func searchMatchPosition(_ query: SearchQuery, scope: IndexedSearchScope,
                             in session: SessionKey, around preferred: String? = nil) throws -> IndexedSearchMatchPosition? {
        guard !query.groups.isEmpty || !query.filters.isEmpty else { return nil }
        let queryStatement = try SearchStatement(query, scope: scope)
        do {
            return try databasePool.read { db in
                guard let sessionID = try Int64.fetchOne(db, sql: """
                    SELECT id FROM sessions WHERE agent=? AND native_id=?
                    """, arguments: [session.agent.rawValue, session.nativeID]) else { return nil }
                var statement = queryStatement
                statement.restrict(to: sessionID)
                return try Self.matchPosition(statement, sessionID: sessionID, preferred: preferred, db: db)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IndexedSearchFailure.unavailable
        }
    }

    private static func matchPosition(_ statement: SearchStatement, sessionID: Int64, preferred: String?,
                                      db: Database) throws -> IndexedSearchMatchPosition? {
        let anchor = try preferred.flatMap { key in
            try Row.fetchOne(db, sql: "SELECT id,seq FROM events WHERE dedupe_key=? AND session_id=?",
                             arguments: [key, sessionID]).map(MatchOrder.init)
        }
        let rows = try Row.fetchCursor(db, sql: statement.selecting("e.id,e.seq"),
                                       arguments: .init(statement.arguments))
        var first: MatchOrder?
        var second: MatchOrder?
        var previous: MatchOrder?
        var next: MatchOrder?
        var count = 0
        var earlier = 0
        var foundAnchor = false
        // Stream only positions. Sorting or materializing an entire large
        // transcript would be unnecessary just to find two adjacent hits.
        try rows.forEach { row in
            if count.isMultiple(of: 1024) { try Task.checkCancellation() }
            count += 1
            let hit = MatchOrder(row)
            if first.map({ hit < $0 }) ?? true {
                second = first
                first = hit
            } else if second.map({ hit < $0 }) ?? true {
                second = hit
            }
            if let anchor {
                if hit == anchor {
                    foundAnchor = true
                } else if hit < anchor {
                    earlier += 1
                    if previous.map({ $0 < hit }) ?? true { previous = hit }
                } else if next.map({ hit < $0 }) ?? true {
                    next = hit
                }
            }
        }
        try Task.checkCancellation()
        guard let current = foundAnchor ? anchor : first else { return nil }
        func key(_ order: MatchOrder?) throws -> String? {
            guard let order else { return nil }
            return try String.fetchOne(db, sql: "SELECT dedupe_key FROM events WHERE id=?", arguments: [order.id])
        }
        guard let eventKey = try key(current) else { throw StoreError.invalidStoredValue }
        return try .init(eventKey: eventKey, ordinal: foundAnchor ? earlier + 1 : 1, count: count,
                         previousKey: key(foundAnchor ? previous : nil), nextKey: key(foundAnchor ? next : second))
    }

    private static func search(_ statement: SearchStatement, now: Int64, order: SessionSearchOrder,
                               limit: Int, offset: Int, db: Database) throws -> IndexedSearchSnapshot {
        let cursor = try Row.fetchCursor(db, sql: statement.sql, arguments: .init(statement.arguments))
        var matches: [Int64: MatchTally] = [:]
        var count = 0
        try cursor.forEach { row in
            if count.isMultiple(of: 1024) { try Task.checkCancellation() }
            count += 1
            let sessionID: Int64 = row[1]
            let hit = EventRank(id: row[0], sequence: row[2], score: row[4])
            let time: Int64 = row[3]
            matches[sessionID, default: .init(count: 0, first: hit, best: hit, lastEvent: time)]
                .append(hit, timestamp: time)
        }
        guard !matches.isEmpty else { return .init(groups: [], sessionCount: 0, matchCount: 0) }
        try Task.checkCancellation()
        let volumes = order == .tokens ? try searchVolumes(for: matches.keys, db: db) : [:]
        let ranked = try Row.fetchAll(db, sql: """
            SELECT id,agent,native_id,coalesce(last_event_at,started_at) AS activity FROM sessions
            """).compactMap { row -> RankedSession? in
                let id: Int64 = row["id"]
                guard let tally = matches[id] else { return nil }
                guard let agent = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
                let activity = (row["activity"] as Int64?) ?? tally.lastEvent
                let ageDays = max(0, Double(now) - Double(activity)) / 86_400_000
                let score = tally.best.score + 0.1 * log1p(Double(tally.count)) + 0.3 * exp(-ageDays / 14)
                return .init(id: id, session: .init(agent: agent, nativeID: row["native_id"]),
                             tally: tally, activity: activity, score: score, volume: volumes[id] ?? 0)
            }.sorted {
                if order == .tokens && $0.volume != $1.volume { return $0.volume > $1.volume }
                if order != .relevance && $0.activity != $1.activity { return $0.activity > $1.activity }
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.activity != $1.activity { return $0.activity > $1.activity }
                return $0.id > $1.id
            }
        let groups = try ranked.dropFirst(offset).prefix(limit).map { session -> IndexedSearchGroup in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT first.dedupe_key, best.text, best.tool_name
                FROM events first JOIN events best ON best.id=? WHERE first.id=?
                """, arguments: [session.tally.best.id, session.tally.first.id])
            else { throw StoreError.invalidStoredValue }
            return .init(session: session.session, matchCount: session.tally.count,
                         firstMatchKey: row["dedupe_key"], bestText: row["text"], bestTool: row["tool_name"])
        }
        return .init(groups: groups, sessionCount: ranked.count, matchCount: count)
    }

    private static func searchVolumes(for keys: Dictionary<Int64, MatchTally>.Keys, db: Database) throws -> [Int64: Int64] {
        var volumes: [Int64: Int64] = [:]
        let ids = Array(keys)
        // Limit the calculation to matching sessions; the existing session
        // token index supports this lookup. Work before paginating results.
        for start in stride(from: 0, to: ids.count, by: 256) {
            try Task.checkCancellation()
            let batch = ids[start..<min(start + 256, ids.count)]
            let marks = Array(repeating: "?", count: batch.count).joined(separator: ",")
            let rows = try Row.fetchCursor(db, sql: """
                SELECT session_id,sum(input_fresh+cache_read+cache_write+cache_write_1h+output) AS tokens
                FROM token_events WHERE session_id IN (\(marks)) GROUP BY session_id
                """, arguments: .init(batch))
            while let row = try rows.next() { volumes[row["session_id"] as Int64] = row["tokens"] }
        }
        return volumes
    }
}

private struct MatchOrder: Comparable {
    let id: Int64
    let seq: Int64

    init(_ row: Row) { id = row[0]; seq = row[1] }

    static func < (lhs: Self, rhs: Self) -> Bool { (lhs.seq, lhs.id) < (rhs.seq, rhs.id) }
}

private struct EventRank {
    let id: Int64
    let sequence: Int64
    let score: Double

    func precedes(_ other: Self) -> Bool { (sequence, id) < (other.sequence, other.id) }
}

private struct MatchTally {
    var count: Int
    var first: EventRank
    var best: EventRank
    var lastEvent: Int64

    mutating func append(_ hit: EventRank, timestamp: Int64) {
        count += 1
        if hit.precedes(first) { first = hit }
        if hit.score > best.score || (hit.score == best.score && hit.precedes(best)) { best = hit }
        lastEvent = max(lastEvent, timestamp)
    }
}

private struct RankedSession {
    let id: Int64
    let session: SessionKey
    let tally: MatchTally
    let activity: Int64
    let score: Double
    let volume: Int64
}

private struct SearchStatement {
    private var predicates: [String] = []
    private(set) var arguments: [DatabaseValue] = []
    private var fts = false
    private var session = false
    private var project = false

    var usesFTS: Bool { fts }

    var sql: String {
        let rank = fts ? "-events_fts.rank" : "0.0"
        return selecting("e.id,e.session_id,e.seq,e.ts,\(rank) AS score")
    }

    func selecting(_ columns: String) -> String {
        let projects = project ? "LEFT JOIN projects p ON p.id=s.project_id" : ""
        let base: String
        if fts {
            let sessions = session ? "JOIN sessions s ON s.id=e.session_id" : ""
            base = "events_fts JOIN events e ON e.id=events_fts.rowid \(sessions) \(projects)"
        } else if session {
            // Find qualifying sessions first, then use events_session_seq.
            base = "sessions s \(projects) CROSS JOIN events e ON e.session_id=s.id"
        } else {
            base = "events e"
        }
        return "SELECT \(columns) FROM \(base)"
            + (predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND "))
    }

    mutating func restrict(to sessionID: Int64) {
        add("e.session_id=?", sessionID.databaseValue)
    }

    init(_ query: SearchQuery, scope: IndexedSearchScope) throws {
        if query.groups.first?.positive.isEmpty == true, query.groups.count == 1 {
            let negative = query.groups[0].negative.map(Self.literal).joined(separator: " OR ")
            if !negative.isEmpty {
                add("e.id NOT IN (SELECT rowid FROM events_fts WHERE events_fts MATCH ?)", negative.databaseValue)
            }
        } else if !query.groups.isEmpty {
            fts = true
            let expression = query.groups.map { group -> String in
                let positive = group.positive.map(Self.literal).joined(separator: " AND ")
                let negative = group.negative.map(Self.literal).joined(separator: " OR ")
                return negative.isEmpty ? "(\(positive))" : "((\(positive)) NOT (\(negative)))"
            }.joined(separator: " OR ")
            add("events_fts MATCH ?", expression.databaseValue)
        }
        if !query.filters.contains(where: { $0.field == .role && $0.value == "user" }) {
            predicates.append("e.kind <> 'prompt_history'")
        }
        for filter in query.filters { try add(filter, scope: scope) }
        if let filter = scope.libraryFilter {
            session = true
            switch filter {
            case .agent(let kind): add("s.agent=?", kind.rawValue.databaseValue)
            case .environment(let name): add("s.environment=? COLLATE BINARY", name.databaseValue)
            case .status(let status): add("s.status=?", status.rawValue.databaseValue)
            }
        }
    }

    private static func literal(_ term: SearchQuery.Term) -> String {
        // Quoting each operand leaves FTS operators entirely under our control.
        "\"" + term.text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    mutating func restrictFTS(to sessionID: Int64, eventIDs: ClosedRange<Int64>) {
        add("e.session_id=? AND events_fts.rowid BETWEEN ? AND ?", sessionID.databaseValue,
            eventIDs.lowerBound.databaseValue, eventIDs.upperBound.databaseValue)
    }

    private mutating func add(_ predicate: String, _ values: DatabaseValue...) {
        predicates.append(predicate)
        arguments.append(contentsOf: values)
    }

    private mutating func add(_ filter: SearchQuery.Filter, scope: IndexedSearchScope) throws {
        let value = filter.value
        let binding = value.databaseValue
        switch filter.field {
        case .agent:
            session = true
            let names: [String: AgentKind] = ["claude": .claudeCode, "codex": .codex, "copilot": .copilot, "grok": .grokBuild]
            guard let agent = names[value] else { throw IndexedSearchFailure.invalidFilter }
            add("s.agent=?", agent.rawValue.databaseValue)
        case .project:
            session = true
            project = true
            add("substr(p.display_name,1,length(?)) = ? COLLATE NOCASE", binding, binding)
        case .dir:
            session = true
            let path: String
            if value.hasPrefix("~/") {
                guard let home = scope.hostHome, home.hasPrefix("/") else { throw IndexedSearchFailure.invalidFilter }
                path = (home.hasSuffix("/") ? home : home + "/") + value.dropFirst(2)
            } else if value.hasPrefix("/") {
                path = value
            } else {
                throw IndexedSearchFailure.invalidFilter
            }
            let root = String(path.reversed().drop(while: { $0 == "/" }).reversed())
            let prefix = root + "/"
            add("(s.cwd=? OR substr(s.cwd,1,length(?))=?)",
                (root.isEmpty ? "/" : root).databaseValue, prefix.databaseValue, prefix.databaseValue)
        case .env:
            session = true
            add("s.environment=? COLLATE NOCASE", binding)
        case .status:
            session = true
            add("s.status=?", binding)
        case .role:
            switch value {
            case "user": predicates.append("e.kind IN ('user','prompt_history')")
            case "assistant": predicates.append("e.kind='assistant'")
            case "tool": predicates.append("e.kind IN ('tool_call','tool_result')")
            default: throw IndexedSearchFailure.invalidFilter
            }
        case .tool:
            add("e.tool_name=? COLLATE NOCASE", binding)
        case .file:
            add("EXISTS(SELECT 1 FROM file_touches f WHERE f.session_id=e.session_id AND instr(f.path,?)>0)", binding)
        case .model:
            session = true
            add("instr(lower(s.model_primary),lower(?))>0", binding)
        case .after, .before:
            let timestamp = try Self.midnight(value, timeZone: scope.timeZone)
            add(filter.field == .after ? "e.ts>=?" : "e.ts<?", timestamp.databaseValue)
        case .recent:
            let unit: Int64
            switch value.last {
            case "d": unit = 86_400_000
            case "h": unit = 3_600_000
            default: throw IndexedSearchFailure.invalidFilter
            }
            guard let amount = Int64(value.dropLast()), amount > 0 else { throw IndexedSearchFailure.invalidFilter }
            let (duration, overflow) = amount.multipliedReportingOverflow(by: unit)
            guard !overflow else { throw IndexedSearchFailure.invalidFilter }
            let (start, underflow) = scope.now.subtractingReportingOverflow(duration)
            add("e.ts BETWEEN ? AND ?", (underflow ? Int64.min : start).databaseValue, scope.now.databaseValue)
        }
    }

    private static func midnight(_ value: String, timeZone: TimeZone) throws -> Int64 {
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw IndexedSearchFailure.invalidFilter }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fields = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: fields),
              let time = Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded())
        else { throw IndexedSearchFailure.invalidFilter }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == fields.year, resolved.month == fields.month, resolved.day == fields.day
        else { throw IndexedSearchFailure.invalidFilter }
        return time
    }
}
