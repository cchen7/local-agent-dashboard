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
    let outcome = try box.store.registerCustomSource(source)
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
    #expect(try box.store.registerCustomSource(duplicate) == .alreadyRegistered(id))
    #expect(try box.store.sources() == [existing])
    #expect(try box.store.checkpoint(for: fileID) == checkpoint)
    #expect(try box.store.events(in: session).first?.text == "existing synthetic session")

    let otherAgent = box.custom(.claudeCode, label: "Other agent", environment: "Other")
    guard case .added(let otherID) = try box.store.registerCustomSource(otherAgent) else {
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
        #expect(throws: StoreError.invalidLocation) { try box.store.registerCustomSource(source) }
    }
    source.rootURL = box.directory.appendingPathComponent("unused-source")
    source.access = .defaultLocation
    #expect(throws: StoreError.invalidCustomSource) { try box.store.registerCustomSource(source) }
    source.access = .bookmark(Data())
    #expect(throws: StoreError.invalidCustomSource) { try box.store.registerCustomSource(source) }
    source.access = .bookmark(Data([0x42]))
    source.environment = " \n"
    #expect(throws: StoreError.invalidCustomSource) { try box.store.registerCustomSource(source) }
    #expect(try box.store.sources().isEmpty)
}

@Test("FR-SRC-2: concurrent registrations can add the same identity only once")
func customSourceRegistrationIsAtomic() async throws {
    let box = try RegistrationFixture()
    defer { box.remove() }
    let source = box.custom(.codex, label: "Synthetic", environment: "Container")
    let results = try await withThrowingTaskGroup(of: CustomSourceRegistration.self) { group in
        for _ in 0..<4 { group.addTask { try box.store.registerCustomSource(source) } }
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

private struct RegistrationFixture: Sendable {
    let directory: URL
    let index: URL
    let store: AgentStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("custom-source-\(UUID().uuidString)")
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
