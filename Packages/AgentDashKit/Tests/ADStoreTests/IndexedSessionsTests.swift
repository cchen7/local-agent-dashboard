import ADCore
import ADStore
import Foundation
import Testing

@Test("SPEC §11.2: an observed library publishes committed metadata in activity order", .timeLimit(.minutes(1)))
func indexedLibraryUpdatesAfterWrite() async throws {
    let fixture = try BrowserStoreFixture()
    defer { fixture.remove() }
    var updates = fixture.store.indexedSessionUpdates().makeAsyncIterator()
    #expect(try await updates.next()?.isEmpty == true)

    let early = fixture.session("first", startedAt: 10, lastActivity: 40)
    let tie = fixture.session("second", startedAt: 40)
    let newest = fixture.session("newest", startedAt: 50)
    try fixture.store.write([.session(early), .session(tie), .session(newest)])
    let snapshot = try #require(try await updates.next())
    #expect(snapshot.map(\.id) == [newest.key, tie.key, early.key])
    #expect(snapshot.map(\.lastActivity) == [50, 40, 40])
    #expect(snapshot.first?.workspace == "/synthetic/workspace")
}

@Test("SPEC §11.2 / NFR-9: live pages are scoped, bounded and reject a moved paging anchor", .timeLimit(.minutes(1)))
func observedTranscriptTracksWritesAndCursorValidity() async throws {
    let fixture = try BrowserStoreFixture()
    defer { fixture.remove() }
    let session = fixture.session("synthetic-browser", startedAt: 10)
    let other = fixture.session("synthetic-other", startedAt: 11)
    func event(_ key: SessionKey, sequence: Int64, id: String) -> NormalizedRecord {
        .event(.init(session: key, sequence: sequence, timestamp: 100 + sequence,
                     kind: .assistant, text: id, dedupeKey: id))
    }

    try fixture.store.write([.session(session), .session(other),
                             event(session.key, sequence: 1, id: "first"),
                             event(other.key, sequence: 2, id: "other")])
    var firstUpdates = try fixture.store.transcriptPageUpdates(in: session.key, limit: 1).makeAsyncIterator()
    let first = try #require(try await firstUpdates.next() ?? nil)
    #expect(first.events.map(\.dedupeKey) == ["first"])
    #expect(first.newer == nil)

    try fixture.store.write([event(session.key, sequence: 3, id: "second")])
    let appended = try #require(try await firstUpdates.next() ?? nil)
    #expect(appended.events.map(\.dedupeKey) == ["first"])
    let cursor = try #require(appended.newer)
    var laterUpdates = try fixture.store.transcriptPageUpdates(in: session.key, request: .after(cursor), limit: 1)
        .makeAsyncIterator()
    let later = try #require(try await laterUpdates.next() ?? nil)
    #expect(later.events.map(\.dedupeKey) == ["second"])

    try fixture.store.write([event(session.key, sequence: 4, id: "first")])
    do {
        _ = try await laterUpdates.next()
        Issue.record("A moved cursor must invalidate the observation.")
    } catch {
        #expect(error as? TranscriptPagingError == .staleCursor)
    }
}

@Test("NFR-9: a live directional page emptied by a rewrite restarts at a valid page",
      .timeLimit(.minutes(1)), arguments: [false, true])
func observedTranscriptRecoversWhenOnlyTheVisibleEventMoves(older: Bool) async throws {
    let fixture = try BrowserStoreFixture()
    defer { fixture.remove() }
    let session = fixture.session("synthetic-moving", startedAt: 10)
    func event(_ id: String, _ sequence: Int64) -> NormalizedRecord {
        .event(.init(session: session.key, sequence: sequence, timestamp: 100,
                     kind: .assistant, text: id, dedupeKey: id))
    }

    try fixture.store.write([.session(session), event("anchor", 10), event("moving", older ? 5 : 15)])
    let start = try #require(try fixture.store.transcriptPage(in: session.key,
        request: older ? .last : .first, limit: 1))
    #expect(start.events.map(\.dedupeKey) == ["anchor"])
    let cursor = try #require(older ? start.older : start.newer)
    let request: TranscriptPageRequest = older ? .before(cursor) : .after(cursor)
    var updates = try fixture.store.transcriptPageUpdates(in: session.key, request: request, limit: 1).makeAsyncIterator()
    let initial = try await updates.next()
    #expect((initial ?? nil)?.events.map(\.dedupeKey) == ["moving"])

    try fixture.store.write([event("moving", older ? 15 : 5)])
    // The anchor is still valid for a one-off read, but this live range has emptied.
    #expect(try fixture.store.transcriptPage(in: session.key, request: request, limit: 1)?.events.isEmpty == true)
    await #expect(throws: TranscriptPagingError.staleCursor) { _ = try await updates.next() }
    let restarted = try #require(try fixture.store.transcriptPage(in: session.key, limit: 1))
    #expect(restarted.events.count == 1)
    #expect(restarted.newer != nil)
    #expect(try fixture.store.events(in: session.key).count == 2)
}

private struct BrowserStoreFixture {
    let directory: URL
    let store: AgentStore
    let sourceID: Int64

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic",
                                               rootURL: directory.appendingPathComponent("unused-source")))
    }

    func session(_ id: String, startedAt: Int64, lastActivity: Int64? = nil) -> SessionRecord {
        .init(key: .init(agent: .codex, nativeID: id), sourceID: sourceID, environment: "Synthetic",
              cwd: "/synthetic/workspace", title: id, startedAt: startedAt, lastEventAt: lastActivity)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
