import ADCore
import ADStore
import Foundation
import Testing

@Test("FR-SRC-1/2: editing source metadata preserves a newer bookmark, file checkpoint and session")
func sourceSettingsPreservePermissionsAndIndex() throws {
    let box = try SourceSettingsFixture()
    defer { box.remove() }
    let source = try box.register()
    let id = try #require(source.id)
    let initial = SourceSettings(source)
    let checkpoint = Checkpoint(inode: 11, size: 12, offset: 10, parserVersion: 1, sequence: 0, previousTimestamp: 4)
    let fileID = try box.store.upsertFile(.init(sourceID: id, relativePath: "sessions/synthetic.jsonl", role: .session),
                                         checkpoint: checkpoint)
    let session = SessionKey(agent: .codex, nativeID: "existing")
    try box.store.write([
        .session(.init(key: session, sourceID: id, fileID: fileID, environment: source.environment)),
        .event(.init(session: session, sequence: 0, timestamp: 4, kind: .user, text: "existing synthetic prompt",
                     dedupeKey: "settings:existing")),
    ])
    let bookmark = Data([0x71])
    try box.store.updateSourceBookmark(for: id, agent: source.agent, rootURL: source.rootURL, bookmark: bookmark)

    var edited = initial
    edited.label = "  Work  "
    edited.environment = "VM"
    edited.pathMappings = [.init(from: "/workspace", to: "~/work")]
    edited.environmentRules = [.init(field: "model_provider", equals: "sample", environment: "  VM profile  ")]
    try box.store.updateSourceSettings(for: id, from: initial, to: edited, hostHome: "/synthetic/home")
    let reopened = try AgentStore(databaseURL: box.index)
    let saved = try #require(try reopened.sources().first)
    #expect(saved.id == id && saved.rootURL == source.rootURL && saved.agent == source.agent)
    #expect(saved.access == .bookmark(bookmark) && saved.enabled == source.enabled)
    #expect(saved.label == "Work" && saved.environment == "VM")
    #expect(saved.environmentRules == [.init(field: "model_provider", equals: "sample", environment: "VM profile")])
    #expect(try PathMapper.map("/workspace/app", using: saved.pathMappings, hostHome: "/synthetic/home") == "/synthetic/home/work/app")
    #expect(try reopened.checkpoint(for: fileID) == checkpoint)
    #expect(try reopened.events(in: session).first?.text == "existing synthetic prompt")
}

@Test("FR-SRC-2: re-granting with an older picker snapshot preserves saved settings and checks source identity")
func sourceRegrantPreservesNewerSettings() throws {
    let box = try SourceSettingsFixture()
    defer { box.remove() }
    let source = try box.register()
    let id = try #require(source.id)
    let initial = SourceSettings(source)
    var edited = initial
    edited.label = "New settings"
    edited.pathMappings = [.init(from: "/recorded", to: "/synthetic/local")]
    try box.store.updateSourceSettings(for: id, from: initial, to: edited, hostHome: nil)

    let bookmark = Data([0x52])
    #expect(throws: SourceSettingsEditFailure.missingSource) {
        try box.store.updateSourceBookmark(for: id, agent: .claudeCode, rootURL: source.rootURL, bookmark: bookmark)
    }
    #expect(throws: SourceSettingsEditFailure.missingSource) {
        try box.store.updateSourceBookmark(for: id, agent: source.agent,
                                           rootURL: source.rootURL.appendingPathComponent("other"), bookmark: bookmark)
    }
    let beforeRegrant = try #require(try box.store.sources().first)
    #expect(beforeRegrant.access == source.access)
    try box.store.updateSourceBookmark(for: id, agent: source.agent, rootURL: source.rootURL, bookmark: bookmark)
    let saved = try #require(try box.store.sources().first)
    #expect(SourceSettings(saved) == edited)
    #expect(saved.access == .bookmark(bookmark) && saved.enabled == source.enabled)
}

@Test("FR-SRC-1: stale edits do not overwrite newer byte-distinct path mappings")
func sourceSettingsRejectStaleMetadata() throws {
    let box = try SourceSettingsFixture()
    defer { box.remove() }
    let source = try box.register(mappings: [.init(from: "/workspace", to: "/synthetic/é")])
    let id = try #require(source.id)
    let initial = SourceSettings(source)
    var latest = initial
    latest.pathMappings[0].to = "/synthetic/e\u{0301}"
    try box.store.updateSourceSettings(for: id, from: initial, to: latest, hostHome: nil)
    var stale = initial
    stale.label = "Stale edit"
    #expect(throws: SourceSettingsEditFailure.staleEditor) {
        try box.store.updateSourceSettings(for: id, from: initial, to: stale, hostHome: nil)
    }
    let current = try #require(try box.store.sources().first)
    #expect(SourceSettings(current) == latest)
}

@Test("FR-SRC-1: invalid mappings and contradictory profile rules never change a source")
func sourceSettingsValidatesBeforeWriting() throws {
    let box = try SourceSettingsFixture()
    defer { box.remove() }
    let source = try box.register()
    let id = try #require(source.id)
    let initial = SourceSettings(source)
    var invalid = initial
    invalid.label = "Do not save"
    invalid.pathMappings = [.init(from: "/workspace", to: "~/work")]
    #expect(throws: SourceSettingsValidation.invalidMapping(.hostHomeRequired(ruleIndex: 0))) {
        try box.store.updateSourceSettings(for: id, from: initial, to: invalid, hostHome: nil)
    }
    invalid.pathMappings = [.init(from: "/workspace", to: "/one"), .init(from: "/workspace/", to: "/two")]
    #expect(throws: SourceSettingsValidation.invalidMapping(.ambiguousRules(firstIndex: 0, secondIndex: 1))) {
        try box.store.updateSourceSettings(for: id, from: initial, to: invalid, hostHome: "/synthetic")
    }
    invalid.pathMappings = []
    invalid.environmentRules = [.init(field: "originator", equals: "synthetic", environment: "One"),
                                .init(field: "originator", equals: "synthetic", environment: "Two")]
    #expect(throws: SourceSettingsValidation.conflictingRule(1)) {
        try box.store.updateSourceSettings(for: id, from: initial, to: invalid, hostHome: "/synthetic")
    }
    invalid.environmentRules[0].environment = "Café"
    invalid.environmentRules[1].environment = "Cafe\u{0301}"
    #expect(throws: SourceSettingsValidation.conflictingRule(1)) {
        try box.store.updateSourceSettings(for: id, from: initial, to: invalid, hostHome: "/synthetic")
    }
    invalid.environmentRules = [.init(field: "originator", equals: "synthetic\0suffix", environment: "Profile")]
    #expect(throws: SourceSettingsValidation.invalidRule(0)) {
        try box.store.updateSourceSettings(for: id, from: initial, to: invalid, hostHome: "/synthetic")
    }
    #expect(try box.store.sources() == [source])
}

@Test("FR-SRC-1: unrelated edits do not normalize labels or rules already stored")
func sourceSettingsPreserveUneditedMetadataBytes() throws {
    let box = try SourceSettingsFixture()
    defer { box.remove() }
    let old = EnvironmentRule(field: "originator", equals: "sample-cli", environment: "  Existing Rule  ")
    let legacy = EnvironmentRule(field: "legacy", equals: "synthetic", environment: "Legacy")
    var source = try box.register(rules: [legacy, old])
    source.label = "  Existing Name  "
    source.environment = "  Existing Environment  "
    _ = try box.store.upsertSource(source)
    let id = try #require(source.id)
    let initial = SourceSettings(source)
    var edited = initial
    edited.pathMappings = [.init(from: "/workspace", to: "/synthetic/work")]
    edited.environmentRules.append(.init(field: "model_provider", equals: "sample-provider", environment: "  New  "))
    try box.store.updateSourceSettings(for: id, from: initial, to: edited, hostHome: nil)
    let saved = try #require(try box.store.sources().first)
    #expect(saved.label == source.label && saved.environment == source.environment)
    #expect(saved.environmentRules == [legacy, old, .init(field: "model_provider", equals: "sample-provider", environment: "New")])
}

@Test("FR-SRC-1: unrelated edits preserve legacy environment rules; only Codex rules can be changed")
func sourceSettingsPreserveUnchangedLegacyRules() throws {
    let box = try SourceSettingsFixture()
    defer { box.remove() }
    let source = try box.register(agent: .claudeCode,
        rules: [.init(field: "legacy", equals: "synthetic", environment: "Old")])
    let id = try #require(source.id)
    let initial = SourceSettings(source)
    var changed = initial
    changed.label = "New label"
    try box.store.updateSourceSettings(for: id, from: initial, to: changed, hostHome: nil)
    var invalid = changed
    invalid.environmentRules = []
    #expect(throws: SourceSettingsValidation.unsupportedEnvironmentRules) {
        try box.store.updateSourceSettings(for: id, from: changed, to: invalid, hostHome: nil)
    }
    #expect(try box.store.sources().first?.environmentRules == source.environmentRules)
}

private struct SourceSettingsFixture {
    let directory: URL
    let store: AgentStore
    var index: URL { directory.appendingPathComponent("index.sqlite") }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    }

    func register(agent: AgentKind = .codex, mappings: [PathMapping] = [], rules: [EnvironmentRule] = []) throws -> Source {
        var source = Source(agent: agent, label: "Existing source", rootURL: directory.appendingPathComponent("unused-source"),
                            environment: "Existing", pathMappings: mappings, environmentRules: rules,
                            access: .bookmark(Data([0x42])), enabled: false)
        source.id = try store.upsertSource(source)
        return source
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
