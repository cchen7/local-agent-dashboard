import ADCore
import Foundation
import GRDB

public struct SavedSessionSearch: Equatable, Identifiable, Sendable {
    public let id: Int64
    public let name: String
    public let query: String
    public let order: SessionSearchOrder
    public let libraryFilter: SessionLibraryFilter?

    public static func validName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 256,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        return trimmed
    }
}

public enum SavedSessionSearchFailure: Error, Equatable, Sendable {
    case invalidName, invalidQuery, duplicate, limitReached
}

public extension AgentStore {
    /// Keep local query strings and labels in the owned database.
    func savedSessionSearches() -> some AsyncSequence<[SavedSessionSearch], any Error> & Sendable {
        ValueObservation.tracking { db in
            try Row.fetchAll(db, sql: """
                SELECT id,name,query,sort,sidebar_field,sidebar_value FROM saved_searches ORDER BY id LIMIT 256
                """).map {
                let order: String? = $0["sort"]
                return SavedSessionSearch(id: $0["id"], name: $0["name"], query: $0["query"],
                                          order: order.flatMap(SessionSearchOrder.init(rawValue:)) ?? .relevance,
                                          libraryFilter: Self.decodeLibraryFilter($0))
            }
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    func saveSessionSearch(name: String, query: String, order: SessionSearchOrder = .relevance,
                           libraryFilter: SessionLibraryFilter? = nil) throws {
        guard let label = SavedSessionSearch.validName(name) else { throw SavedSessionSearchFailure.invalidName }
        guard let parsed = try? SearchQuery.parse(query), !parsed.groups.isEmpty || !parsed.filters.isEmpty else {
            throw SavedSessionSearchFailure.invalidQuery
        }
        let filter = Self.encodeLibraryFilter(libraryFilter)
        try databasePool.write { db in
            let duplicate = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM saved_searches WHERE name=? AND query=? AND
                    CASE WHEN sort IN ('recent','tokens') THEN sort ELSE 'relevance' END=?
                    AND sidebar_field IS ? AND sidebar_value IS ?)
                """, arguments: [label, query, order.rawValue, filter.0, filter.1])
            guard duplicate != true else {
                throw SavedSessionSearchFailure.duplicate
            }
            guard (try Int.fetchOne(db, sql: "SELECT count(*) FROM saved_searches") ?? 0) < 256 else {
                throw SavedSessionSearchFailure.limitReached
            }
            try db.execute(sql: "INSERT INTO saved_searches(name,query,sort,sidebar_field,sidebar_value) VALUES(?,?,?,?,?)",
                           arguments: [label, query, order.rawValue, filter.0, filter.1])
        }
    }

    func removeSessionSearch(_ search: SavedSessionSearch) throws {
        let filter = Self.encodeLibraryFilter(search.libraryFilter)
        try databasePool.write { db in
            // Check the contents as well as the row ID, which SQLite can reuse.
            try db.execute(sql: """
                DELETE FROM saved_searches WHERE id=? AND name=? AND query=? AND
                    CASE WHEN sort IN ('recent','tokens') THEN sort ELSE 'relevance' END=?
                    AND sidebar_field IS ? AND sidebar_value IS ?
                """, arguments: [search.id, search.name, search.query, search.order.rawValue, filter.0, filter.1])
        }
    }

    private static func encodeLibraryFilter(_ filter: SessionLibraryFilter?) -> (String?, String?) {
        switch filter {
        case .agent(let agent): ("agent", agent.rawValue)
        case .environment(let name): ("environment", name)
        case .status(let status): ("status", status.rawValue)
        case nil: (nil, nil)
        }
    }

    private static func decodeLibraryFilter(_ row: Row) -> SessionLibraryFilter? {
        guard let field: String = row["sidebar_field"], let value: String = row["sidebar_value"] else { return nil }
        switch field {
        case "agent": return AgentKind(rawValue: value).map(SessionLibraryFilter.agent)
        case "environment": return .environment(value)
        case "status": return SessionStatus(rawValue: value).map(SessionLibraryFilter.status)
        default: return nil
        }
    }
}
