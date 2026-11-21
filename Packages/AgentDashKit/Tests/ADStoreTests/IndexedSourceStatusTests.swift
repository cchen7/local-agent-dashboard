import ADCore
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("FR-SRC-2 / ADP-1: source diagnostics keep files, archived sessions, prompt history, and errors distinct",
      .timeLimit(.minutes(1)))
func sourceStatusIsScopedAndUsesRecordedScanTime() async throws {
    let box = try SourceStatusFixture()
    defer { box.remove() }
    let source = try box.source(.claudeCode, "synthetic-claude")
    let other = try box.source(.codex, "synthetic-codex")
    let history = try box.file(source, "history.jsonl", role: .promptHistory,
                               checkpoint: box.checkpoint(offset: 10, unknown: 2))
    let complete = try box.file(source, "projects/a.jsonl", checkpoint: box.checkpoint(offset: 10, unknown: 4))
    let partial = try box.file(source, "projects/b.jsonl", checkpoint: box.checkpoint(offset: 5, unknown: 1))
    let failed = try box.file(source, "projects/c.jsonl")
    let gone = try box.file(source, "projects/d.jsonl", checkpoint: box.checkpoint(offset: 10, unknown: 0))
    _ = try box.file(other, "sessions/other.jsonl", checkpoint: box.checkpoint(offset: 10, unknown: 9))
    try box.store.write([
        box.session(source, complete, "a"),
        box.session(source, partial, "b"),
        box.session(source, history, "history-only"),
        box.session(source, gone, "archived"),
    ])
    try await box.store.databasePool.write { db in
        try db.execute(sql: "UPDATE sources SET last_scan_at=777,last_error='private synthetic detail' WHERE id=?",
                       arguments: [source])
        try db.execute(sql: "UPDATE source_files SET state='error' WHERE id=?", arguments: [failed])
        try db.execute(sql: "UPDATE source_files SET state='gone' WHERE id=?", arguments: [gone])
        try db.execute(sql: "UPDATE sessions SET source_deleted_at=800 WHERE native_id='archived'")
    }
    var updates = box.store.indexedSourceStatusUpdates().makeAsyncIterator()
    let snapshot = try #require(try await updates.next())
    let a = try #require(snapshot.first { $0.id == source })
    let b = try #require(snapshot.first { $0.id == other })
    #expect(a.trackedFiles == 5 && a.indexedFiles == 4)
    #expect(a.partialFiles == 1 && a.failedFiles == 1 && a.goneFiles == 1)
    #expect(a.sessions == 3 && a.archivedSessions == 1)
    #expect(a.unknownRecords == 7)
    #expect(a.lastScanAt == 777 && a.hasRecordedSourceError)
    #expect(b.trackedFiles == 1 && b.indexedFiles == 1 && b.sessions == 0)
    #expect(b.unknownRecords == 9 && b.lastScanAt == nil && !b.hasRecordedSourceError)
}

@Test("ADP-2: a registered file is not indexed until its batch and checkpoint commit",
      .timeLimit(.minutes(1)))
func sourceStatusObservesAtomicBatchAndReplay() async throws {
    let box = try SourceStatusFixture()
    defer { box.remove() }
    let id = try box.source(.claudeCode, "synthetic-claude")
    let fileID = try box.file(id, "projects/synthetic.jsonl")
    var updates = box.store.indexedSourceStatusUpdates().makeAsyncIterator()
    let initial = try #require(try await updates.next()?.first)
    #expect(initial.trackedFiles == 1 && initial.indexedFiles == 0)
    #expect(initial.sessions == 0 && initial.lastScanAt == nil)

    let partial = box.checkpoint(offset: 5, unknown: 2)
    try box.store.commitFileBatch([box.session(id, fileID, "synthetic")], for: fileID, from: nil, to: partial)
    let ingested = try #require(try await updates.next()?.first)
    #expect(ingested.indexedFiles == 1 && ingested.partialFiles == 1)
    #expect(ingested.sessions == 1 && ingested.unknownRecords == 2 && ingested.lastScanAt == nil)

    let replayed = box.checkpoint(offset: 10, unknown: 1)
    try box.store.commitFileBatch([], for: fileID, from: partial, to: replayed)
    let completed = try #require(try await updates.next()?.first)
    #expect(completed.indexedFiles == 1 && completed.partialFiles == 0)
    #expect(completed.sessions == 1 && completed.unknownRecords == 1)
}

private struct SourceStatusFixture {
    let directory: URL
    let store: AgentStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    }

    func source(_ agent: AgentKind, _ label: String) throws -> Int64 {
        // No real root exists; diagnostics should report index records, not probe it.
        try store.upsertSource(.init(agent: agent, label: label, rootURL: directory.appendingPathComponent(label)))
    }

    func checkpoint(offset: Int64, unknown: Int64) -> Checkpoint {
        .init(inode: 11, size: 10, offset: offset, parserVersion: 1, sequence: 0,
              previousTimestamp: 12, modificationTimeNS: 1_000_000_000, unknownRecords: unknown)
    }

    func file(_ source: Int64, _ path: String, role: SourceFile.Role = .session,
              checkpoint: Checkpoint? = nil) throws -> Int64 {
        try store.upsertFile(.init(sourceID: source, relativePath: path, role: role), checkpoint: checkpoint)
    }

    func session(_ source: Int64, _ file: Int64, _ native: String) -> NormalizedRecord {
        .session(.init(key: .init(agent: .claudeCode, nativeID: native), sourceID: source, fileID: file, environment: "Synthetic"))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
