import ADCore
import ADStore
import Foundation
import Testing

@Test("FR-SR: smart groups keep the original query, survive reopening and run against current events")
func smartGroupPersistsAndRunsAsLiveSearch() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("smart-group-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let database = directory.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: database)
    let raw = #"agent:codex "登录 配置" -草稿"#
    let scope = IndexedSearchScope(now: 100, timeZone: .gmt)
    let id = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: directory))
    let target = SessionKey(agent: .codex, nativeID: "synthetic-target")
    let ignored = SessionKey(agent: .codex, nativeID: "synthetic-excluded")
    try store.write([
        .session(.init(key: target, sourceID: id, environment: "Synthetic")),
        .session(.init(key: ignored, sourceID: id, environment: "Synthetic")),
        .event(.init(session: ignored, sequence: 0, timestamp: 1, kind: .user,
                     text: "登录 配置 草稿", dedupeKey: "synthetic:smart-group:excluded")),
    ])

    var values = store.savedSessionSearches().makeAsyncIterator()
    #expect(try await values.next() == [])
    let filter = SessionLibraryFilter.environment("Synthetic")
    try store.saveSessionSearch(name: "  登录  ", query: raw, order: .tokens, libraryFilter: filter)
    let saved = try #require(try await values.next()?.first)
    #expect(saved.name == "登录" && saved.query == raw && saved.order == .tokens && saved.libraryFilter == filter)
    #expect(throws: SavedSessionSearchFailure.duplicate) {
        try store.saveSessionSearch(name: "登录", query: raw, order: .tokens, libraryFilter: filter)
    }
    #expect(throws: SavedSessionSearchFailure.invalidQuery) {
        try store.saveSessionSearch(name: "Invalid", query: "agent:unknown")
    }
    #expect(throws: SavedSessionSearchFailure.invalidName) {
        try store.saveSessionSearch(name: " \n ", query: raw)
    }

    let reopened = try AgentStore(databaseURL: database)
    var reopenedValues = reopened.savedSessionSearches().makeAsyncIterator()
    #expect(try await reopenedValues.next() == [saved])
    let parsed = try SearchQuery.parse(saved.query)
    #expect(try reopened.searchIndex(parsed, scope: scope).matchCount == 0)
    try reopened.write([.event(.init(session: target, sequence: 0, timestamp: 2, kind: .user,
                                    text: "登录 配置", dedupeKey: "synthetic:smart-group:target"))])
    #expect(try reopened.searchIndex(parsed, scope: scope).groups.map(\.session) == [target])
    try reopened.removeSessionSearch(saved)
    #expect(try await reopenedValues.next() == [])
    #expect(try reopened.events(in: target).count == 1)
    #expect(try reopened.searchIndex(parsed, scope: scope).matchCount == 1)
}

@Test("FR-SR: recency and exact cache-inclusive volume order full results before pagination")
func searchSortsAllMatchingSessionsBeforePaging() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("search-order-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: directory))
    let relevant = SessionKey(agent: .codex, nativeID: "synthetic-relevance")
    let newer = SessionKey(agent: .codex, nativeID: "synthetic-newer")
    let volume = SessionKey(agent: .codex, nativeID: "synthetic-volume")
    try store.write([
        .session(.init(key: relevant, sourceID: source, environment: "Synthetic", lastEventAt: 1)),
        .session(.init(key: newer, sourceID: source, environment: "Synthetic", lastEventAt: 3)),
        .session(.init(key: volume, sourceID: source, environment: "Synthetic", lastEventAt: 2)),
        .event(.init(session: relevant, sequence: 0, timestamp: 1, kind: .user, text: "探测",
                     dedupeKey: "synthetic:sort:relevant1")),
        .event(.init(session: relevant, sequence: 1, timestamp: 1, kind: .user, text: "探测",
                     dedupeKey: "synthetic:sort:relevant2")),
        .event(.init(session: newer, sequence: 0, timestamp: 3, kind: .user, text: "探测",
                     dedupeKey: "synthetic:sort:newer")),
        .event(.init(session: volume, sequence: 0, timestamp: 2, kind: .user, text: "探测",
                     dedupeKey: "synthetic:sort:volume")),
        .tokens(.init(session: volume, timestamp: 2, counts: .init(inputFresh: 1, cacheRead: 80, cacheWrite: 20),
                      dedupeKey: "synthetic:sort:cached")),
        .tokens(.init(session: newer, timestamp: 3, counts: .init(inputFresh: 90),
                      dedupeKey: "synthetic:sort:fresh")),
    ])
    let query = try SearchQuery.parse("探测")
    let scope = IndexedSearchScope(now: 3, timeZone: .gmt)
    #expect(try store.searchIndex(query, scope: scope, limit: 1).groups.first?.session == relevant)
    #expect(try store.searchIndex(query, scope: scope, order: .recent, limit: 1).groups.first?.session == newer)
    let byVolume = try store.searchIndex(query, scope: scope, order: .tokens, limit: 1, offset: 0)
    #expect(byVolume.groups.first?.session == volume && byVolume.matchCount == 4 && byVolume.sessionCount == 3)
    #expect(try store.searchIndex(query, scope: scope, order: .tokens, limit: 1, offset: 1).groups.first?.session == newer)

    var changes = store.searchIndexChanges(order: .tokens).makeAsyncIterator()
    _ = try await changes.next()
    try store.write([.tokens(.init(session: relevant, timestamp: 1, counts: .init(inputFresh: 120),
                                    dedupeKey: "synthetic:sort:later"))])
    let wake: Void? = try await changes.next()
    #expect(wake != nil)
    let updated = try store.searchIndex(query, scope: scope, order: .tokens, limit: 1)
    #expect(updated.groups.first?.session == relevant && updated.groups.first?.firstMatchKey == "synthetic:sort:relevant1")
}
