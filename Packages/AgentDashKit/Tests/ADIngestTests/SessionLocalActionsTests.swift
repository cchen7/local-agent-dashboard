import ADAdapters
import ADCore
import ADIngest
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("SEC-5 / §11.2: build copy-only text from the mapped workspace, with a fixed environment comment")
func resumeTextUsesCurrentWorkspaceMapping() throws {
    let fixture = try SessionActionFixture()
    defer { fixture.remove() }
    try fixture.writeRecord(for: fixture.key)
    _ = try fixture.index()
    var source = fixture.source
    source.pathMappings = [.init(from: "/container", to: "~/Work")]
    source.environment = "Test\nnot-a-shell-line"
    try fixture.store.upsertSource(source)
    var actions = try #require(try fixture.store.indexedSessionActions(fixture.key))
    let expected = #"""
        # Use the same environment and agent configuration as this session.
        cd '/synthetic/Work/Team'\''s $notes' && codex resume \#(fixture.key.nativeID)
        """#
    #expect(SessionLocalActions.resumeCommand(actions, hostHome: "/synthetic") == expected)
    #expect(SessionLocalActions.resumeCommand(actions, hostHome: nil) == nil)
    #expect(actions.workspace == "/container/Team's $notes")

    // A stopped source is still registered. Removal ends both actions.
    source.enabled = false
    try fixture.store.upsertSource(source)
    actions = try #require(try fixture.store.indexedSessionActions(fixture.key))
    #expect(SessionLocalActions.resumeCommand(actions, hostHome: "/synthetic") == expected)
    try fixture.store.removeRegisteredSource(try #require(source.id))
    #expect(try fixture.store.indexedSessionActions(fixture.key) == nil)
}

@Test("SEC-3 / §11.2: original record is available only for the observed regular file")
func finderRecordDoesNotFollowReplacementOrSymlink() throws {
    let fixture = try SessionActionFixture()
    defer { fixture.remove() }
    try fixture.writeRecord(for: fixture.key)
    _ = try fixture.index()
    let first = try #require(try fixture.store.indexedSessionActions(fixture.key)?.record)
    #expect(try SessionLocalActions.withVerifiedRecordURL(first, authorizedRoot: fixture.root) { $0.path }
            == fixture.file.path)
    let backup = fixture.file.appendingPathExtension("old")
    try FileManager.default.moveItem(at: fixture.file, to: backup)
    #expect(throws: (any Error).self) {
        try SessionLocalActions.withVerifiedRecordURL(first, authorizedRoot: fixture.root) { $0 }
    }
    try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: backup)
    #expect(throws: (any Error).self) {
        try SessionLocalActions.withVerifiedRecordURL(first, authorizedRoot: fixture.root) { $0 }
    }
    try FileManager.default.removeItem(at: fixture.file)
    let next = SessionKey(agent: .codex, nativeID: "00000000-0000-0000-0000-000000000057")
    try fixture.writeRecord(for: next)
    #expect(throws: SessionLocalActionFailure.unavailable) {
        try SessionLocalActions.withVerifiedRecordURL(first, authorizedRoot: fixture.root) { $0 }
    }
    _ = try fixture.index()
    // The old session survived in the library after ingest reused its path.
    let old = try #require(try fixture.store.indexedSessionActions(fixture.key))
    #expect(!old.canResume && old.record == nil)
    #expect(try fixture.store.indexedSessionActions(next)?.record != nil)

    try FileManager.default.removeItem(at: fixture.file)
    let sourceID = try #require(fixture.source.id)
    let observed = try fixture.store.sourceArchiveCandidate(sourceID: sourceID, relativePath: fixture.relativePath)
    let candidate = try #require(observed)
    try fixture.store.archiveMissingSourceFiles([candidate], sourceID: sourceID, at: 1_770_000_000_000)
    let archive = try #require(try fixture.store.indexedSessionActions(next))
    #expect(!archive.canResume && archive.record == nil)
}

@Test("SEC-3: a replaced registered root cannot reveal a record even if the file inode still matches")
func finderRecordRequiresTheRegisteredDirectory() throws {
    let fixture = try SessionActionFixture(registered: true)
    defer { fixture.remove() }
    try fixture.writeRecord(for: fixture.key)
    _ = try fixture.index()
    let record = try #require(try fixture.store.indexedSessionActions(fixture.key)?.record)
    #expect(record.rootIdentity != nil)
    #expect(try SessionLocalActions.withVerifiedRecordURL(record, authorizedRoot: fixture.root) { $0.path }
            == fixture.file.path)

    let moved = fixture.directory.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: fixture.root, to: moved)
    try FileManager.default.createDirectory(at: fixture.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.linkItem(at: moved.appendingPathComponent(fixture.relativePath), to: fixture.file)
    let disk = try SourceFileReader(root: fixture.root, relativePath: fixture.relativePath).snapshot()
    #expect(disk.inode == record.inode && disk.device == record.device)
    #expect(throws: SessionLocalActionFailure.unavailable) {
        try SessionLocalActions.withVerifiedRecordURL(record, authorizedRoot: fixture.root) { $0 }
    }
}

@Test("§11.2: prompt history does not pretend to be a resumable transcript")
func promptHistoryHasNoSessionRecordAction() throws {
    let fixture = try SessionActionFixture()
    defer { fixture.remove() }
    let sourceID = try #require(fixture.source.id)
    let history = try fixture.store.upsertFile(.init(sourceID: sourceID, relativePath: "history.jsonl", role: .promptHistory),
                                              checkpoint: nil)
    let checkpoint = Checkpoint(inode: 42, size: 1, offset: 1, parserVersion: 1, sequence: 0,
                                previousTimestamp: nil, device: 7)
    try fixture.store.commitFileBatch([.session(.init(key: fixture.key, sourceID: sourceID, fileID: history,
                                                     environment: "Local", cwd: "/synthetic"))],
                                      for: history, from: nil, to: checkpoint)
    let actions = try #require(try fixture.store.indexedSessionActions(fixture.key))
    #expect(!actions.canResume && actions.record == nil)
}

@Test("§11.2: upgrading preserves the checkpoint until the next scan confirms the record's identity")
func upgradeReplaysToConfirmSessionFileOwnership() throws {
    let fixture = try SessionActionFixture()
    defer { fixture.remove() }
    try fixture.writeRecord(for: fixture.key)
    let previous = try fixture.index()
    var config = Configuration()
    config.prepareDatabase { $0.add(tokenizer: AgentDashTokenizer.self) }
    let legacy = try DatabaseQueue(path: fixture.database.path, configuration: config)
    try legacy.write { db in
        try db.execute(sql: """
            ALTER TABLE sessions DROP COLUMN record_device;
            ALTER TABLE sessions DROP COLUMN record_inode;
            ALTER TABLE source_files DROP COLUMN confirm_session_identity;
            DELETE FROM grdb_migrations WHERE identifier='session_record_identity';
            """)
    }

    let upgraded = try AgentStore(databaseURL: fixture.database)
    #expect(try upgraded.checkpoint(for: previous.fileID) == previous.checkpoint)
    #expect(try upgraded.indexedSessionActions(fixture.key)?.record == nil)
    let replayed = try fixture.index(using: upgraded)
    #expect(replayed.completeLines == 2)
    #expect(try upgraded.indexedSessionActions(fixture.key)?.record != nil)
    #expect(try upgraded.events(in: fixture.key).count == 1)
    let appendedOnly = try fixture.index(using: upgraded)
    #expect(appendedOnly.completeLines == 0)
}

private struct SessionActionFixture {
    let directory: URL
    let root: URL
    let database: URL
    let file: URL
    let relativePath = "sessions/2026/01/01/rollout-synthetic.jsonl"
    let key = SessionKey(agent: .codex, nativeID: "00000000-0000-0000-0000-000000000056")
    let store: AgentStore
    let source: Source

    init(registered: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-actions-\(UUID())")
        root = directory.appendingPathComponent("source")
        database = directory.appendingPathComponent("index.sqlite")
        file = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: database)
        var descriptor = Source(agent: .codex, label: "Synthetic", rootURL: root)
        if registered {
            descriptor.access = .bookmark(Data([1]))
            let identity = try SourceFileReader.registrationIdentity(root: root)
            guard case .added(let id) = try store.registerCustomSource(descriptor, identity: identity) else {
                throw SessionLocalActionFailure.unavailable
            }
            descriptor.id = id
        } else {
            descriptor.id = try store.upsertSource(descriptor)
        }
        source = descriptor
    }

    func writeRecord(for key: SessionKey) throws {
        let lines: [[String: Any]] = [
            ["timestamp": "2026-01-01T00:00:00Z", "type": "session_meta",
             "payload": ["id": key.nativeID, "cwd": "/container/Team's $notes"]],
            ["timestamp": "2026-01-01T00:00:01Z", "type": "event_msg",
             "payload": ["type": "user_message", "message": "Synthetic prompt"]]
        ]
        let data = try lines.reduce(into: Data()) { bytes, line in
            try bytes.append(JSONSerialization.data(withJSONObject: line))
            bytes.append(0x0A)
        }
        try data.write(to: file)
    }

    func index(using target: AgentStore? = nil) throws -> JSONLImportResult {
        let adapter = CodexAdapter()
        let input = try #require(try adapter.discover(in: source, authorizedRoot: root).first { $0.relativePath == relativePath })
        return try JSONLFileImporter.importFile(input, from: source, authorizedRoot: root, store: target ?? store, adapter: adapter)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
