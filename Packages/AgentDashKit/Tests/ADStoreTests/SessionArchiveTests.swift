import ADCore
import ADStore
import Foundation
import Testing

@Test("FR-STO-1: archive and ingest reject stale checkpoints in either commit order")
func archiveCannotRaceANewerCheckpoint() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("archive-cas-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp))
    let path = "synthetic.jsonl"
    let initial = Checkpoint(inode: 10, size: 2, offset: 2, parserVersion: 1, sequence: 0, previousTimestamp: 1)
    let fileID = try store.upsertFile(.init(sourceID: sourceID, relativePath: path, role: .session), checkpoint: initial)
    let observed = try #require(try store.sourceArchiveCandidate(sourceID: sourceID, relativePath: path))
    var newer = initial
    newer.sequence += 1
    try store.commitFileBatch([], for: fileID, from: initial, to: newer)
    try store.archiveMissingSourceFiles([observed], sourceID: sourceID, at: 3)
    #expect(try store.checkpoint(for: fileID) == newer)

    let confirmed = try #require(try store.sourceArchiveCandidate(sourceID: sourceID, relativePath: path))
    try store.archiveMissingSourceFiles([confirmed], sourceID: sourceID, at: 4)
    #expect(try store.checkpoint(for: fileID)?.sourceFileWasMissing == true)
    #expect(throws: StoreError.staleCheckpoint) {
        try store.commitFileBatch([], for: fileID, from: newer, to: newer)
    }
}
