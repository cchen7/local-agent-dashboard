import ADCore
import ADInsights
import ADStore
import Foundation
import Testing

@Test("§10.2 / SEC-8: ordinary writes refresh safe complete-message topics without a rebuild",
      .timeLimit(.minutes(1)))
func liveTopicsFollowNormalIngestAndPrivacy() async throws {
    let box = try LiveTopicFixture()
    defer { box.remove() }
    let key = box.key("session")
    try box.store.write([
        .session(box.session(key)),
        box.text(key, "one", "API_TOKEN=", seq: 1),
        box.text(key, "two", "syntheticsecretpart\norbital inspection", seq: 2),
        box.text(key, "prompt", "信号追踪", seq: 3, kind: .user),
    ])
    let pipeline = try TopicIndexPipeline(store: box.store)
    let worker = Task { try await pipeline.run() }
    defer { worker.cancel() }

    var values = box.store.sessionOverviewUpdates(in: key).makeAsyncIterator()
    var indexed: IndexedSessionOverview?
    while let value = try await values.next() {
        if let value, value.topics.contains("orbital") { indexed = value; break }
    }
    let snapshot = try #require(indexed)
    #expect(!snapshot.topics.contains("syntheticsecretpart"))
    #expect(SessionOverviewDisplay(snapshot).topics.contains("orbital"))
    _ = try box.store.setIndexSecretRedactionEnabled(true)
    try box.store.write([box.text(key, "two", "syntheticsecretpart\nharmonic inspection", seq: 2)])
    // Both writes invalidate the original sample, with no change to its IDs.
    var refreshed: IndexedSessionOverview?
    while let value = try await values.next() {
        if let value, value.topics.contains("harmonic") { refreshed = value; break }
    }
    let updated = try #require(refreshed)
    #expect(!updated.topics.contains("orbital"))
    #expect(!updated.topics.contains("syntheticsecretpart"))
}

@Test("§10.2 / §11.3: project topics use only their current scoped evidence and remain searchable",
      .timeLimit(.minutes(1)))
func liveProjectTopicsDoNotMixWorkspaces() async throws {
    let box = try LiveTopicFixture()
    defer { box.remove() }
    let a = box.key("a")
    let b = box.key("b")
    let c = box.key("c")
    try box.store.write([
        .session(box.session(a)), .session(box.session(b)),
        .session(box.session(c, cwd: "/synthetic/isolated")),
        box.text(a, "a", "harmonic", seq: 1, kind: .user),
        box.text(b, "b", "orbital", seq: 1, kind: .user),
        box.text(c, "c", "outsideterm", seq: 1, kind: .user),
    ])
    let pipeline = try TopicIndexPipeline(store: box.store)
    _ = try await pipeline.refresh()
    var projects = box.store.indexedProjectUpdates().makeAsyncIterator()
    let catalog = try #require(try await projects.next())
    let project = try #require(catalog.first { $0.path == "/synthetic/shared" })
    var topics = box.store.indexedProjectTopicUpdates(project.pinTarget).makeAsyncIterator()
    let values = try #require(try await topics.next())
    #expect(Set(values) == ["harmonic", "orbital"])
    for term in values {
        let result = try box.store.searchIndex(SearchQuery.parse(SearchQuery.quotedLiteral(term)),
                                              scope: .init(now: 10, timeZone: .gmt))
        #expect(result.groups.contains { $0.session == a || $0.session == b })
    }
}

@Test("§10.2: a topic computation cannot commit against a queued newer sample")
func topicRevisionRejectsAStaleComputation() throws {
    let box = try LiveTopicFixture()
    defer { box.remove() }
    let key = box.key("revision")
    try box.store.write([.session(box.session(key)), box.text(key, "item", "orbital", seq: 1, kind: .user)])
    let scoring = IndexTopicScoring(counts: { _ in ["orbital": 2] }, top: { _, _, _ in [] })
    let stale = try #require(try box.store.prepareTopicUpdates(scoring: scoring, afterID: 0).first)
    try box.store.write([box.text(key, "item", "harmonic", seq: 1, kind: .user)])
    #expect(try box.store.applyTopicUpdates([stale]) == 0)
    #expect(!((try box.store.prepareTopicUpdates(scoring: scoring, afterID: 0)).isEmpty))
}

@Test("SEC-8: complete JSON secrets do not become searchable topic labels")
func liveTopicCorpusMasksStructuredValues() async throws {
    let box = try LiveTopicFixture()
    defer { box.remove() }
    let key = box.key("structured")
    try box.store.write([
        .session(box.session(key)),
        box.text(key, "json", #"{"API_TOKEN":"aaastructuredsecret","operation":"orbital"}"#, seq: 1, kind: .user),
    ])
    let pipeline = try TopicIndexPipeline(store: box.store)
    _ = try await pipeline.refresh()
    var overview = box.store.sessionOverviewUpdates(in: key).makeAsyncIterator()
    let result = try #require(try await overview.next() ?? nil)
    #expect(result.topics.contains("orbital"))
    #expect(!result.topics.contains("aaastructuredsecret"))
}

private struct LiveTopicFixture {
    let directory: URL
    let store: AgentStore
    let source: Int64

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("topic-live-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        source = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic", rootURL: directory))
    }

    func key(_ id: String) -> SessionKey { .init(agent: .claudeCode, nativeID: "synthetic-" + id) }

    func session(_ key: SessionKey, cwd: String = "/synthetic/shared") -> SessionRecord {
        .init(key: key, sourceID: source, environment: "Synthetic", cwd: cwd)
    }

    func text(_ key: SessionKey, _ id: String, _ text: String, seq: Int64,
              kind: EventKind = .assistant) -> NormalizedRecord {
        .event(.init(session: key, sequence: seq, timestamp: seq, kind: kind, text: text,
                     metadataJSON: kind == .assistant ? #"{"claude_message_id":"synthetic-fragments"}"# : nil,
                     dedupeKey: "claude:event:synthetic-\(id):0"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
