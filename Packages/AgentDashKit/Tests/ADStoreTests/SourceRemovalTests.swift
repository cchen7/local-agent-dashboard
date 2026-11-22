import ADCore
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("FR-SRC-2: removal forgets authorization, rejects indexing and preserves the library through re-registration")
func removedSourceKeepsHistoryAndRequiresExplicitRegistration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-removal-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let database = directory.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: database)
    let root = directory.appendingPathComponent("not-opened")
    let defaultSource = Source(agent: .claudeCode, label: "Default", rootURL: root)
    try store.installDefaultSources([defaultSource])
    let id = try #require(try store.sources().first?.id)
    var source = defaultSource
    source.label = "Edited source"
    source.environment = "Synthetic"
    source.pathMappings = [.init(from: "/workspace", to: "/synthetic/local")]
    source.access = .bookmark(Data([1]))
    #expect(try store.upsertSource(source) == id)
    let file = SourceFile(sourceID: id, relativePath: "projects/sample.jsonl", role: .session)
    let fileID = try store.upsertFile(file, checkpoint: nil)
    let checkpoint = Checkpoint(inode: 3, size: 14, offset: 14, parserVersion: 1, sequence: 0, previousTimestamp: 0)
    let key = SessionKey(agent: .claudeCode, nativeID: "synthetic-source-removal")
    let event = EventRecord(session: key, sequence: 0, timestamp: 0, kind: .user, text: "retained sample",
                            dedupeKey: "synthetic:removal:prompt")
    try store.commitFileBatch([
        .session(.init(key: key, sourceID: id, fileID: fileID, environment: "Synthetic")),
        .event(event),
        .tokens(.init(session: key, timestamp: 0, counts: .init(inputFresh: 30), dedupeKey: "synthetic:removal:usage")),
    ], for: fileID, from: nil, to: checkpoint)

    try store.removeRegisteredSource(id)
    let reopened = try AgentStore(databaseURL: database)
    try reopened.installDefaultSources([defaultSource])
    _ = try reopened.upsertSource(source)
    #expect(try reopened.sources().isEmpty)
    try reopened.databasePool.read { db throws -> Void in
        let saved = try #require(try Row.fetchOne(db, sql: "SELECT * FROM sources WHERE id=?", arguments: [id]))
        #expect((saved["bookmark"] as Data?) == nil)
        #expect((saved["enabled"] as Bool) == false)
    }
    #expect(throws: StoreError.missingSource) { _ = try reopened.upsertFile(file, checkpoint: nil) }
    #expect(throws: StoreError.missingSource) {
        try reopened.commitFileBatch([], for: fileID, from: checkpoint, to: checkpoint)
    }
    #expect(throws: SourceSettingsEditFailure.missingSource) {
        try reopened.updateSourceBookmark(for: id, agent: .claudeCode, rootURL: root, bookmark: Data([2]))
    }
    let scope = IndexedSearchScope(now: 1, timeZone: .gmt)
    let query = try SearchQuery.parse("retained sample")
    #expect(try reopened.searchIndex(query, scope: scope).groups.map(\.session) == [key])
    #expect(try reopened.transcriptPage(in: key)?.events == [event])
    let window = try UsageWindow.make(.hour, now: 1, timeZone: .gmt)
    #expect(try reopened.usage(window: window).totals.counts.total == 30)
    #expect(try reopened.checkpoint(for: fileID) == checkpoint)

    var requested = defaultSource
    requested.access = .bookmark(Data([3]))
    let identity = SourceRootIdentity(volume: UUID(), inode: 3, birthSeconds: 1, birthNanoseconds: 0)
    #expect(try reopened.registerCustomSource(requested, identity: identity) == .added(id))
    let restored = try #require(try reopened.sources().first)
    #expect(restored.id == id && restored.access == requested.access && restored.enabled)
    #expect(restored.label == source.label && restored.environment == source.environment)
    #expect(restored.pathMappings == source.pathMappings)
    #expect(try reopened.checkpoint(for: fileID) == checkpoint)
    #expect(try reopened.registerCustomSource(requested, identity: identity) == .alreadyRegistered(id))
}
