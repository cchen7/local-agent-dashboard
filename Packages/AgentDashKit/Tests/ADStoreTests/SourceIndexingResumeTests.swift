import ADCore
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("FR-SRC-2, DEV-109: only sources left indexing resume after a relaunch")
func sourcesResumeOnlyAfterAnExplicitStartThatWasNotStopped() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let database = directory.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: database)
    try store.installDefaultSources([
        Source(agent: .claudeCode, label: "Claude", rootURL: directory.appendingPathComponent("not-opened-claude")),
        Source(agent: .codex, label: "Codex", rootURL: directory.appendingPathComponent("not-opened-codex")),
        Source(agent: .copilot, label: "Copilot", rootURL: directory.appendingPathComponent("not-opened-copilot")),
    ])
    let ids = try store.sources().compactMap(\.id)
    try #require(ids.count == 3)

    // Nothing is recorded for an existing library, so an upgrade resumes nothing.
    #expect(try store.sourceIDsResumingIndexing().isEmpty)

    try store.setResumesIndexing(true, sourceID: ids[0])
    try store.setResumesIndexing(true, sourceID: ids[1])
    try store.setResumesIndexing(true, sourceID: ids[2])
    try store.setResumesIndexing(false, sourceID: ids[1])
    try store.setResumesIndexing(true, sourceID: ids[2])
    #expect(try AgentStore(databaseURL: database).sourceIDsResumingIndexing() == [ids[0], ids[2]])

    // Removal forgets the intent, so a later registration of the path starts stopped.
    try store.removeRegisteredSource(ids[2])
    #expect(try store.sourceIDsResumingIndexing() == [ids[0]])
    try store.databasePool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "SELECT resume_indexing FROM sources WHERE id=?", arguments: [ids[2]]) == 0)
    }
    // A disabled source does not resume even with the flag set.
    try store.databasePool.write { db in
        try db.execute(sql: "UPDATE sources SET enabled=0 WHERE id=?", arguments: [ids[0]])
    }
    #expect(try store.sourceIDsResumingIndexing().isEmpty)
    try store.databasePool.write { db in
        try db.execute(sql: "UPDATE sources SET enabled=1 WHERE id=?", arguments: [ids[0]])
    }
    // Recording intent for a removed or unknown source changes nothing.
    try store.setResumesIndexing(true, sourceID: ids[2])
    try store.setResumesIndexing(true, sourceID: 9_999)
    #expect(try store.sourceIDsResumingIndexing() == [ids[0]])
}
