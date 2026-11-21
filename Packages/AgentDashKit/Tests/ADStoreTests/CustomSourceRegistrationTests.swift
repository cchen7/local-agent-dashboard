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
    existing.id = try box.store.upsertSource(existing)
    let id = try #require(existing.id)
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
