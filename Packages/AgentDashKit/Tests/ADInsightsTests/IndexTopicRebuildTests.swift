import ADCore
import ADInsights
import ADStore
import Foundation
import Testing

@Test("FR-STO-1 / SEC-8: rebuild derives genuine searchable topics without indexing split credential fragments",
      .timeLimit(.minutes(1)))
func rebuildProducesMaskedTopicsFromLogicalMessages() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topic-rebuild-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let sourceID = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic",
                                                rootURL: directory.appendingPathComponent("absent")))
    let key = SessionKey(agent: .claudeCode, nativeID: "synthetic-target")
    let other = SessionKey(agent: .claudeCode, nativeID: "synthetic-other")
    let extra = SessionKey(agent: .claudeCode, nativeID: "synthetic-third")
    try store.write([
        .session(.init(key: key, sourceID: sourceID, environment: "Synthetic")),
        .session(.init(key: other, sourceID: sourceID, environment: "Synthetic")),
        .session(.init(key: extra, sourceID: sourceID, environment: "Synthetic")),
        .event(.init(session: key, sequence: 1, timestamp: 1, kind: .assistant,
                     text: "API_TOKEN=", metadataJSON: #"{"claude_message_id":"one"}"#,
                     dedupeKey: "claude:event:synthetic-first:0")),
        .event(.init(session: key, sequence: 2, timestamp: 2, kind: .assistant,
                     text: "hiddenrebuildsuffix\norbital repair", metadataJSON: #"{"claude_message_id":"one"}"#,
                     dedupeKey: "claude:event:synthetic-second:0")),
    ])
    var observations = store.searchIndexChanges().makeAsyncIterator()
    _ = try await observations.next()
    #expect(try LocalIndexMaintenance.rebuild(store).indexedEvents == 2)
    let refreshed: Void? = try await observations.next()
    #expect(refreshed != nil)
    var overview = store.sessionOverviewUpdates(in: key).makeAsyncIterator()
    let result = try #require(try await overview.next() ?? nil)
    #expect(result.topics.contains("orbital"))
    #expect(!result.topics.contains("hiddenrebuildsuffix"))
    #expect(SessionOverviewDisplay(result, scorer: try TopicScorer()).topics.contains("orbital"))
    #expect(try store.events(in: key).count == 2)
}
