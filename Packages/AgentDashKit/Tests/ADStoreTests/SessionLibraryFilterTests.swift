import ADCore
import ADStore
import Foundation
import Testing

@Test("FR-SR: sidebar scope composes with typed search and preserves byte-exact environment selection")
func sidebarFilterScopesSearchAndMetadata() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("library-filter-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: directory))
    let a = SessionKey(agent: .codex, nativeID: "synthetic-composed")
    let b = SessionKey(agent: .codex, nativeID: "synthetic-decomposed")
    let aEnv = "Café API_TOKEN=synthetic-only"
    let bEnv = "Cafe\u{0301} API_TOKEN=synthetic-only"
    let filter = SessionLibraryFilter.environment(aEnv)
    #expect(filter != .environment(bEnv))
    #expect(filter.includes(agent: .codex, environment: aEnv, status: .unknown))
    #expect(!filter.includes(agent: .codex, environment: bEnv, status: .unknown))
    #expect(SessionLibraryFilter.status(.waiting).includes(agent: .codex, environment: "", status: .waiting))
    try store.write([
        .session(.init(key: a, sourceID: sourceID, environment: aEnv, status: .waiting)),
        .session(.init(key: b, sourceID: sourceID, environment: bEnv, status: .running)),
        .event(.init(session: a, sequence: 0, timestamp: 1, kind: .user, text: "登录验证", dedupeKey: "synthetic:sidebar:a")),
        .event(.init(session: b, sequence: 0, timestamp: 1, kind: .user, text: "登录验证", dedupeKey: "synthetic:sidebar:b")),
    ])
    let query = try SearchQuery.parse("agent:codex 登录")
    let scope = IndexedSearchScope(now: 2, timeZone: .gmt, libraryFilter: filter)
    let result = try store.searchIndex(query, scope: scope)
    #expect(result.groups.map(\.session) == [a])
    #expect(try store.searchMatchPosition(query, scope: scope, in: b) == nil)
    #expect(try store.searchMatchPosition(query, scope: scope, in: a)?.eventKey == result.groups.first?.firstMatchKey)
    #expect(try store.searchIndex(SearchQuery.parse("status:running 登录"), scope: scope).groups.isEmpty)
}
