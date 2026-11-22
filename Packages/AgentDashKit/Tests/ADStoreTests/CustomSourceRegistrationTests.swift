import ADCore
import ADStore
import Foundation
import Testing

@Test("FR-SRC-1/2: a custom source persists its opaque bookmark and environment without opening the root")
func customSourcePersistsWithoutReadingTheRoot() throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    // The test root is intentionally absent; registering must not open it.
    let source = box.custom(.codex, label: "Work Codex", environment: "Container")
    let outcome = try box.store.registerCustomSource(source, identity: box.identity)
    guard case .added(let id) = outcome else { Issue.record("Expected a newly registered source"); return }
    let reopened = try AgentStore(databaseURL: box.index)
    var expected = source
    expected.id = id
    #expect(try reopened.sources() == [expected])
    #expect(!FileManager.default.fileExists(atPath: source.rootURL.path))
}

@Test("FR-SRC-2: a duplicate choice preserves the source, checkpoint and sessions")
func duplicateCustomSourceDoesNotReplaceExistingSettings() throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    var existing = box.custom(.codex, label: "Existing", environment: "Existing Environment")
    existing.access = .bookmark(Data([0x42, 0x43]))
    existing.enabled = false
    existing.pathMappings = [.init(from: "/workspace", to: "/synthetic/local")]
    guard case .added(let id) = try box.store.registerCustomSource(existing, identity: box.identity) else {
        Issue.record("Expected original source to register"); return
    }
    existing.id = id
    let file = SourceFile(sourceID: id, relativePath: "sessions/synthetic.jsonl", role: .session)
    let checkpoint = Checkpoint(inode: 11, size: 12, offset: 10, parserVersion: 1, sequence: 0, previousTimestamp: 4)
    let fileID = try box.store.upsertFile(file, checkpoint: checkpoint)
    let session = SessionKey(agent: .codex, nativeID: "synthetic-existing")
    try box.store.write([
        .session(.init(key: session, sourceID: id, fileID: fileID, environment: existing.environment)),
        .event(.init(session: session, sequence: 0, timestamp: 4, kind: .user,
                     text: "existing synthetic session", dedupeKey: "synthetic:existing:0")),
    ])
    var duplicate = box.custom(.codex, label: "Do not replace", environment: "Other")
    duplicate.rootURL = existing.rootURL.appendingPathComponent(".", isDirectory: true)
    #expect(try box.store.registerCustomSource(duplicate, identity: box.identity) == .alreadyRegistered(id))
    #expect(try box.store.sources() == [existing])
    #expect(try box.store.checkpoint(for: fileID) == checkpoint)
    #expect(try box.store.events(in: session).first?.text == "existing synthetic session")

    let otherAgent = box.custom(.claudeCode, label: "Other agent", environment: "Other")
    guard case .added(let otherID) = try box.store.registerCustomSource(otherAgent, identity: box.identity) else {
        Issue.record("Different agents may select the same path"); return
    }
    #expect(otherID != id)
}

@Test("SEC-1/3: reject remote URLs and empty, non-custom registrations")
func customSourceRejectsRemoteAndInvalidMetadata() throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    var source = box.custom(.codex, label: "Synthetic", environment: "Local")
    for value in ["https://example.invalid/synthetic", "file://example.invalid/synthetic"] {
        source.rootURL = try #require(URL(string: value))
        #expect(throws: StoreError.invalidLocation) { try box.store.registerCustomSource(source, identity: box.identity) }
    }
    source.rootURL = box.directory.appendingPathComponent("unused-source")
    source.access = .defaultLocation
    #expect(throws: StoreError.invalidCustomSource) { try box.store.registerCustomSource(source, identity: box.identity) }
    source.access = .bookmark(Data())
    #expect(throws: StoreError.invalidCustomSource) { try box.store.registerCustomSource(source, identity: box.identity) }
    source.access = .bookmark(Data([0x42]))
    source.environment = " \n"
    #expect(throws: StoreError.invalidCustomSource) { try box.store.registerCustomSource(source, identity: box.identity) }
    #expect(try box.store.sources().isEmpty)
}

@Test("FR-SRC-2: concurrent registrations can add the same identity only once")
func customSourceRegistrationIsAtomic() async throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    let source = box.custom(.codex, label: "Synthetic", environment: "Container")
    let results = try await withThrowingTaskGroup(of: CustomSourceRegistration.self) { group in
        for _ in 0..<4 { group.addTask { try box.store.registerCustomSource(source, identity: box.identity) } }
        var values: [CustomSourceRegistration] = []
        for try await value in group { values.append(value) }
        return values
    }
    let sources = try box.store.sources()
    #expect(sources.count == 1)
    let id = try #require(sources.first?.id)
    #expect(results.filter { $0 == .added(id) }.count == 1)
    #expect(results.filter { $0 == .alreadyRegistered(id) }.count == 3)
}

@Test("FR-SRC-2: Data-volume and case aliases reuse the original source across a store reopen")
func customSourceSharesDirectoryIdentityAcrossAPFSAliases() throws {
    // /private/tmp is on the startup Data volume with both mount spellings.
    // Some system-provided temporary paths have no direct Data spelling.
    let box = try RegistrationFixture(temporaryRoot: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    defer { box.remove() }
    let folder = box.directory.appendingPathComponent("SourceAliasTest", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    let firstURL = folder
    let aliasPath = "/System/Volumes/Data" + folder.path
    let dataAlias = URL(fileURLWithPath: aliasPath, isDirectory: true)
    let upper = firstURL.deletingLastPathComponent().appendingPathComponent("SOURCEALIASTEST", isDirectory: true)
    let identity = try SourceFileReader.directoryIdentity(root: firstURL)
    #expect(try SourceFileReader.directoryIdentity(root: dataAlias) == identity)

    var original = box.custom(.codex, label: "Original", environment: "Synthetic")
    original.rootURL = firstURL
    guard case let .added(id) = try box.store.registerCustomSource(original, identity: identity) else {
        Issue.record("Expected a newly registered source"); return
    }
    original.id = id
    let index = try AgentStore(databaseURL: box.index)
    let registered = try index.sources()
    #expect(registered.count == 1)
    let saved = try #require(registered.first)
    #expect(saved.id == id)
    #expect(try SourceFileReader.directoryIdentity(root: saved.rootURL) == identity)
    #expect(saved.label == original.label && saved.access == original.access)
    var duplicate = original
    duplicate.rootURL = dataAlias
    duplicate.label = "Discarded"
    duplicate.access = .bookmark(Data([0x23]))
    #expect(try index.registerCustomSource(duplicate, identity: identity) == .alreadyRegistered(id))
    #expect(try index.sources() == registered)

    // On case-sensitive APFS, the alternate spelling may identify a different
    // directory; do not fold case in storage or in lookup.
    if let caseIdentity = try? SourceFileReader.directoryIdentity(root: upper) {
        #expect(caseIdentity == identity)
        duplicate.rootURL = upper
        #expect(try index.registerCustomSource(duplicate, identity: caseIdentity) == .alreadyRegistered(id))
        #expect(try index.sources() == registered)
    } else {
        try FileManager.default.createDirectory(at: upper, withIntermediateDirectories: false)
        let distinct = try SourceFileReader.directoryIdentity(root: upper)
        #expect(distinct != identity)
        duplicate.rootURL = upper
        guard case .added = try index.registerCustomSource(duplicate, identity: distinct) else {
            Issue.record("Distinct case-sensitive directories must stay distinct"); return
        }
    }
}

@Test("FR-SRC-2: an observed older source row is not replaced by an alias")
func customSourcePreservesObservedLegacyRegistration() throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    var original = box.custom(.codex, label: "Original", environment: "Synthetic")
    original.id = try box.store.upsertSource(original)
    let id = try #require(original.id)
    var alias = original
    alias.rootURL = original.rootURL.deletingLastPathComponent().appendingPathComponent("alias")
    alias.access = .bookmark(Data([0x44]))
    #expect(try box.store.registerCustomSource(alias, identity: box.identity, existing: original) == .alreadyRegistered(id))
    #expect(try box.store.sources() == [original])
}

@Test("FR-SRC-2: replacing the permission discards the old directory identity")
func customSourceDoesNotClaimAnOldIdentityAfterRegrant() throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    let original = box.custom(.codex, label: "Original", environment: "Synthetic")
    guard case let .added(id) = try box.store.registerCustomSource(original, identity: box.identity) else {
        Issue.record("Expected a newly registered source"); return
    }
    var regranted = original
    regranted.access = .bookmark(Data([0x17]))
    #expect(try box.store.upsertSource(regranted) == id)
    var moved = original
    moved.rootURL = box.directory.appendingPathComponent("previous-directory")
    guard case let .added(newID) = try box.store.registerCustomSource(moved, identity: box.identity) else {
        Issue.record("The old identity should not match the updated bookmark"); return
    }
    #expect(newID != id)
    #expect(try box.store.sources().first?.access == regranted.access)
}

private struct RegistrationFixture: Sendable {
    let directory: URL
    let index: URL
    let store: AgentStore
    let identity = SourceRootIdentity(volume: UUID(), inode: 42, birthSeconds: 100, birthNanoseconds: 0)

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) throws {
        directory = temporaryRoot.appendingPathComponent("custom-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        index = directory.appendingPathComponent("index.sqlite")
        store = try AgentStore(databaseURL: index)
    }

    func custom(_ agent: AgentKind, label: String, environment: String) -> Source {
        .init(agent: agent, label: label, rootURL: directory.appendingPathComponent("unused-source"),
              environment: environment, access: .bookmark(Data([0x77, 0x66])))
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test("FR-SRC-2: a reused root path and its Data alias cannot replace the moved source", arguments: [false, true])
func customSourceDistinguishesReusedAPFSPath(useDataAliasFirst: Bool) throws {
    let box = try RegistrationFixture(temporaryRoot: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    defer { box.remove() }
    let atStart = box.directory.appendingPathComponent("Original", isDirectory: true)
    let moved = box.directory.appendingPathComponent("Moved", isDirectory: true)
    let dataAlias = URL(fileURLWithPath: "/System/Volumes/Data" + atStart.path, isDirectory: true)
    let files = FileManager.default
    try files.createDirectory(at: atStart, withIntermediateDirectories: false)
    let oldIdentity = try SourceFileReader.directoryIdentity(root: atStart)
    var source = box.custom(.codex, label: "Original", environment: "Synthetic")
    source.rootURL = useDataAliasFirst ? dataAlias : atStart
    guard case .added(let id) = try box.store.registerCustomSource(source, identity: oldIdentity) else {
        Issue.record("Expected original source to register"); return
    }
    source.id = id
    let file = SourceFile(sourceID: id, relativePath: "sessions/archived.jsonl", role: .session)
    let checkpoint = Checkpoint(inode: 11, size: 12, offset: 10, parserVersion: 1, sequence: 0, previousTimestamp: 4)
    let fileID = try box.store.upsertFile(file, checkpoint: checkpoint)
    let session = SessionKey(agent: .codex, nativeID: "synthetic-archived")
    try box.store.write([
        .session(.init(key: session, sourceID: id, fileID: fileID, environment: source.environment)),
        .event(.init(session: session, sequence: 0, timestamp: 4, kind: .user,
                     text: "archived synthetic history", dedupeKey: "synthetic:archived:0")),
    ])
    let registeredBeforeMove = try box.store.sources()
    try files.moveItem(at: atStart, to: moved)
    try files.createDirectory(at: atStart, withIntermediateDirectories: false)
    #expect(try SourceFileReader.directoryIdentity(root: moved) == oldIdentity)
    let replacement = try SourceFileReader.directoryIdentity(root: atStart)
    #expect(replacement != oldIdentity)
    #expect(try SourceFileReader.directoryIdentity(root: dataAlias) == replacement)

    let store = try AgentStore(databaseURL: box.index)
    var choice = box.custom(.codex, label: "Replacement", environment: "Other")
    choice.rootURL = source.rootURL
    #expect(try store.registerCustomSource(choice, identity: replacement) == .pathConflict)
    choice.rootURL = useDataAliasFirst ? atStart : dataAlias
    let registered = try store.sources()
    let occupiedPath = try #require(registered.first {
        (try? SourceFileReader.directoryIdentity(root: $0.rootURL)) == replacement
    })
    #expect(try store.registerCustomSource(choice, identity: replacement, occupiedPath: occupiedPath) == .pathConflict)
    // A live match against the saved path cannot override a known identity.
    #expect(try store.registerCustomSource(choice, identity: replacement, existing: occupiedPath,
                                           occupiedPath: occupiedPath) == .pathConflict)
    choice.rootURL = moved
    #expect(try store.registerCustomSource(choice, identity: oldIdentity) == .alreadyRegistered(id))
    #expect(try store.sources() == registeredBeforeMove)
    #expect(try store.checkpoint(for: fileID) == checkpoint)
    #expect(try store.events(in: session).first?.text == "archived synthetic history")
}

@Test("FR-SRC-2: renewing accepts a renamed APFS source and rejects the replacement at its old path")
func renewAccessFollowsTheOriginalDirectory() throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    let old = box.directory.appendingPathComponent("Original", isDirectory: true)
    let moved = box.directory.appendingPathComponent("Moved", isDirectory: true)
    let files = FileManager.default
    try files.createDirectory(at: old, withIntermediateDirectories: false)
    let original = try SourceFileReader.directoryIdentity(root: old)
    var source = box.custom(.codex, label: "Original", environment: "Work")
    source.rootURL = old
    source.enabled = false
    source.pathMappings = [.init(from: "/workspace", to: "/synthetic/project")]
    guard case .added(let id) = try box.store.registerCustomSource(source, identity: original) else {
        Issue.record("Expected a new source"); return
    }
    let before = try #require(try box.store.sources().first)
    let checkpoint = Checkpoint(inode: 11, size: 20, offset: 15, parserVersion: 3, sequence: 2, previousTimestamp: 4)
    let fileID = try box.store.upsertFile(.init(sourceID: id, relativePath: "sessions/synthetic.jsonl", role: .session),
                                         checkpoint: checkpoint)
    let session = SessionKey(agent: .codex, nativeID: "synthetic-history")
    let event = EventRecord(session: session, sequence: 2, timestamp: 4, kind: .assistant,
                            text: "Synthetic reply", dedupeKey: "synthetic:old:2")
    try box.store.write([.session(.init(key: session, sourceID: id, fileID: fileID, environment: "Work")), .event(event)])
    try files.moveItem(at: old, to: moved)
    try files.createDirectory(at: old, withIntermediateDirectories: false)
    let replacement = try SourceFileReader.directoryIdentity(root: old)
    let relocated = try SourceFileReader.directoryIdentity(root: moved)
    #expect(relocated == original && replacement != original)
    let newBookmark = Data([0x34, 0x57])
    #expect(try box.store.renewSourceAccess(before, selectedRoot: old, identity: replacement,
                                            bookmark: newBookmark, legacyBookmarkIdentity: replacement,
                                            savedPathIdentity: replacement) == .wrongDirectory)
    #expect(try box.store.sources() == [before])
    #expect(try box.store.checkpoint(for: fileID) == checkpoint)
    #expect(try box.store.renewSourceAccess(before, selectedRoot: moved, identity: relocated,
                                            bookmark: newBookmark) == .renewed)

    let reopened = try AgentStore(databaseURL: box.index)
    let renewed = try #require(try reopened.sources().first)
    #expect(renewed.rootURL.standardizedFileURL.path == moved.standardizedFileURL.path)
    var expected = before
    expected.rootURL = renewed.rootURL
    expected.access = .bookmark(newBookmark)
    #expect(try reopened.sources() == [expected])
    #expect(try reopened.checkpoint(for: fileID) == checkpoint)
    #expect(try reopened.events(in: session) == [event])
    #expect(try reopened.registerCustomSource(source, identity: original) == .alreadyRegistered(id))
    #expect(throws: StoreError.invalidCustomSource) {
        try reopened.renewSourceAccess(before, selectedRoot: moved, identity: relocated, bookmark: Data([0x11]))
    }
    #expect(try reopened.sources() == [expected])
}

@Test("FR-SRC-2: legacy custom permissions require an independent live bookmark match")
func renewAccessRequiresLegacyBookmarkEvidence() throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    let source = box.custom(.codex, label: "Legacy", environment: "Synthetic")
    let id = try box.store.upsertSource(source)
    let pending = try #require(try box.store.sources().first)
    let moved = box.directory.appendingPathComponent("moved")
    let bookmark = Data([0x12, 0x34])
    #expect(try box.store.renewSourceAccess(pending, selectedRoot: source.rootURL, identity: box.identity,
                                            bookmark: bookmark, savedPathIdentity: box.identity) == .wrongDirectory)
    #expect(try box.store.sources() == [pending])
    #expect(try box.store.renewSourceAccess(pending, selectedRoot: moved, identity: box.identity,
                                            bookmark: bookmark, legacyBookmarkIdentity: box.identity) == .renewed)
    #expect(try box.store.registerCustomSource(source, identity: box.identity) == .alreadyRegistered(id))
}

@Test("FR-SRC-2 / §11.3: re-granting through a Data-volume alias preserves default discovery and project membership")
func renewDefaultSourceThroughAliasKeepsProject() async throws {
    let fixture = try RegistrationFixture(temporaryRoot: URL(fileURLWithPath: "/private/tmp", isDirectory: true))
    defer { fixture.remove() }
    let home = fixture.directory
    let root = home.appendingPathComponent(".codex", isDirectory: true)
    let peer = home.appendingPathComponent(".claude", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: peer, withIntermediateDirectories: false)
    let alias = URL(fileURLWithPath: "/System/Volumes/Data" + root.path, isDirectory: true)
    let savedIdentity = try SourceFileReader.directoryIdentity(root: root)
    let selectedIdentity = try SourceFileReader.directoryIdentity(root: alias)
    try #require(savedIdentity == selectedIdentity)
    let store = fixture.store
    let codex = try store.upsertSource(.init(agent: .codex, label: "Codex", rootURL: root))
    let claude = try store.upsertSource(.init(agent: .claudeCode, label: "Claude", rootURL: peer))
    try store.write([
        .session(.init(key: .init(agent: .codex, nativeID: "one"), sourceID: codex, environment: "Local", cwd: "/synthetic/repo")),
        .session(.init(key: .init(agent: .claudeCode, nativeID: "two"), sourceID: claude, environment: "Local", cwd: "/synthetic/repo"))
    ])
    var projects = store.indexedProjectUpdates(hostHome: home.standardizedFileURL.path).makeAsyncIterator()
    let before = try #require(try await projects.next())
    try #require(before.count == 1 && before.first?.sessions.count == 2)
    let pending = try #require(try store.sources().first { $0.id == codex })
    let bookmark = Data([0x10, 0x20])
    #expect(try store.renewSourceAccess(pending, selectedRoot: alias, identity: selectedIdentity,
                                       bookmark: bookmark, savedPathIdentity: savedIdentity) == .renewed)
    let after = try #require(try store.sources().first { $0.id == codex })
    #expect(after.rootURL == pending.rootURL && after.access == .bookmark(bookmark))
    // An unchanged catalog is not re-emitted by the live query.
    var refreshed = store.indexedProjectUpdates(hostHome: home.standardizedFileURL.path).makeAsyncIterator()
    #expect(try await refreshed.next() == before)
}

@Test("FR-SRC-2: a default source can receive its first bookmark only at its configured path")
func renewDefaultSourceUsesConfiguredPathForInitialGrant() throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    var source = box.custom(.codex, label: "Default", environment: "Synthetic")
    source.access = .defaultLocation
    let id = try box.store.upsertSource(source)
    let pending = try #require(try box.store.sources().first)
    let bookmark = Data([0x56])
    #expect(try box.store.renewSourceAccess(pending, selectedRoot: box.directory, identity: box.identity,
                                            bookmark: bookmark) == .wrongDirectory)
    #expect(try box.store.sources() == [pending])
    #expect(try box.store.renewSourceAccess(pending, selectedRoot: pending.rootURL, identity: box.identity,
                                            bookmark: bookmark) == .renewed)
    #expect(try box.store.sources().first?.id == id)
    #expect(try box.store.sources().first?.access == .bookmark(bookmark))
}
