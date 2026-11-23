import ADCore
import ADPrivacy
import ADStore
import Foundation
import Testing

@Test("SEC-7: an applied rule removes matching search and usage, preserves uncertain paths, and rewinds only affected files")
func exclusionPolicyPurgesConfirmedMatches() throws {
    let fixture = try ExclusionFixture()
    defer { fixture.remove() }
    let denied = try fixture.seed("denied", cwd: "/work/private/repo", count: 7)
    let mapped = try fixture.seed("mapped", cwd: "/mnt/private/repo", count: 5)
    let allowed = try fixture.seed("allowed", cwd: "/work/private-neighbor", count: 3)
    let ambiguous = try fixture.seed("ambiguous", cwd: "../private", count: 2)
    #expect(try fixture.total() == 17)
    let before = try fixture.store.checkpoint(for: allowed.file)
    #expect(throws: PathExclusions.Failure.invalidRule(index: 1)) {
        _ = try fixture.store.replaceSessionExclusions(["/work/private/**", "../mistyped"], hostHome: nil)
    }
    #expect(try fixture.store.sessionExclusionPatterns().isEmpty)
    #expect(try fixture.total() == 17)

    let update = try fixture.store.replaceSessionExclusions(["/work/private/**"], hostHome: nil)
    #expect(update.removedSessions == 2 && update.invalidatedFiles == 2)
    #expect(try fixture.store.events(in: denied.key).isEmpty)
    #expect(try fixture.store.events(in: mapped.key).isEmpty)
    #expect(try fixture.store.searchIndex(SearchQuery.parse("synthetic"), scope: fixture.scope).sessionCount == 2)
    #expect(try fixture.total() == 5)
    #expect(try fixture.store.checkpoint(for: denied.file)?.parserVersion == 0)
    #expect(try fixture.store.checkpoint(for: mapped.file)?.decoderState == nil)
    #expect(try fixture.store.checkpoint(for: allowed.file) == before)

    // The same excluded key cannot resurrect from a copied transcript without a path.
    try fixture.store.write([.session(.init(key: denied.key, sourceID: fixture.source, environment: "Synthetic")),
        .event(.init(session: denied.key, sequence: 4, timestamp: fixture.stamp, kind: .user,
                     text: "synthetic inherited content", dedupeKey: "synthetic-denied-inherited"))])
    #expect(try fixture.store.events(in: denied.key).isEmpty)
    // Invalid new metadata does not delete an older session or allow its next event in.
    try fixture.store.write([.session(.init(key: ambiguous.key, sourceID: fixture.source, environment: "Synthetic", cwd: "//ambiguous"))])
    try fixture.store.write([.event(.init(session: ambiguous.key, sequence: 2, timestamp: fixture.stamp, kind: .assistant,
                                        text: "unproven new content", dedupeKey: "synthetic-ambiguous-tail"))])
    #expect(try fixture.store.events(in: ambiguous.key).count == 1)
    #expect(try fixture.total() == 5)

    let cleared = try fixture.store.replaceSessionExclusions([], hostHome: nil)
    #expect(cleared.removedSessions == 0 && cleared.invalidatedFiles == 2)
    #expect(try fixture.store.events(in: denied.key).isEmpty)
    #expect(try fixture.store.checkpoint(for: allowed.file) == before)
}

@Test("SEC-7 / ADP-2: a batch cannot commit against a superseded path policy")
func staleExclusionVersionRejectsFileBatch() throws {
    let fixture = try ExclusionFixture()
    defer { fixture.remove() }
    let file = try fixture.store.upsertFile(.init(sourceID: fixture.source, relativePath: "pending.jsonl", role: .session), checkpoint: nil)
    let position = try fixture.store.fileImportPosition(for: file)
    let key = SessionKey(agent: .codex, nativeID: "pending")
    _ = try fixture.store.replaceSessionExclusions(["/work/private/**"], hostHome: nil)
    #expect(throws: StoreError.exclusionPolicyChanged) {
        try fixture.store.commitFileBatch([
            .session(.init(key: key, sourceID: fixture.source, fileID: file, environment: "Synthetic", cwd: "/work/private")),
            .event(.init(session: key, sequence: 0, timestamp: fixture.stamp, kind: .user,
                         text: "synthetic withheld", dedupeKey: "synthetic-withheld")),
        ], for: file, from: position.checkpoint, to: fixture.checkpoint, exclusionRevision: position.exclusionRevision)
    }
    #expect(try fixture.store.checkpoint(for: file) == nil && fixture.total() == 0)
}

private struct ExclusionFixture {
    let dir: URL
    let store: AgentStore
    let source: Int64
    let stamp: Int64 = 1_770_000_000_000
    var scope: IndexedSearchScope { .init(now: stamp + 1, timeZone: .gmt) }
    var checkpoint: Checkpoint {
        .init(inode: 2, size: 20, offset: 20, parserVersion: 1, sequence: 0, previousTimestamp: stamp,
              decoderState: Data("{}".utf8))
    }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("exclusions-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        store = try AgentStore(databaseURL: dir.appendingPathComponent("index.sqlite"))
        source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: dir,
                                               pathMappings: [.init(from: "/mnt", to: "/work")]))
    }

    func seed(_ id: String, cwd: String, count: Int64) throws -> (key: SessionKey, file: Int64) {
        let key = SessionKey(agent: .codex, nativeID: id)
        let file = try store.upsertFile(.init(sourceID: source, relativePath: id + ".jsonl", role: .session), checkpoint: nil)
        try store.commitFileBatch([
            .session(.init(key: key, sourceID: source, fileID: file, environment: "Synthetic", cwd: cwd)),
            .event(.init(session: key, sequence: 0, timestamp: stamp, kind: .user, text: "synthetic body", dedupeKey: id + ":event")),
            .tokens(.init(session: key, timestamp: stamp, counts: .init(output: count), dedupeKey: id + ":tokens")),
        ], for: file, from: nil, to: checkpoint)
        return (key, file)
    }

    func total() throws -> Int64 {
        let window = try UsageWindow.make(.hour, now: stamp + 60_000, timeZone: .gmt)
        return try store.usage(window: window).totals.counts.total
    }

    func remove() { try? FileManager.default.removeItem(at: dir) }
}

@Test("SEC-7: trusted workspace metadata can admit preceding batch events, but an inherited reference cannot",
      arguments: [false, true])
func exclusionRequiresAuthoritativeWorkspace(referenceOnly: Bool) throws {
    let fixture = try ExclusionFixture()
    defer { fixture.remove() }
    _ = try fixture.store.replaceSessionExclusions(["/work/private/**"], hostHome: nil)
    let key = SessionKey(agent: .codex, nativeID: "synthetic-early")
    try fixture.store.write([
        .event(.init(session: key, sequence: 0, timestamp: fixture.stamp, kind: .assistant,
                     text: "synthetic earlier event", dedupeKey: "synthetic-early:event")),
        .tokens(.init(session: key, timestamp: fixture.stamp, counts: .init(output: 3), dedupeKey: "synthetic-early:tokens")),
        .session(.init(key: key, sourceID: fixture.source, environment: "Synthetic", cwd: "/work/known",
                       referenceOnly: referenceOnly)),
    ])
    #expect(try fixture.store.events(in: key).count == (referenceOnly ? 0 : 1))
    #expect(try fixture.total() == (referenceOnly ? 0 : 3))
}

@Test("SEC-7: changing a source's path mapping enforces active exclusions on its existing sessions")
func mappedWorkspaceChangeAppliesExclusionImmediately() throws {
    let fixture = try ExclusionFixture()
    defer { fixture.remove() }
    let remapped = try fixture.seed("remapped", cwd: "/remote/private/repository", count: 11)
    let unaffected = try fixture.seed("ordinary", cwd: "/work/ordinary", count: 2)
    let initial = try fixture.store.replaceSessionExclusions(["/work/private/**"], hostHome: nil)
    #expect(initial.removedSessions == 0)
    let source = try #require(try fixture.store.sources().first)
    let expected = SourceSettings(source)
    var updated = expected
    updated.pathMappings.append(.init(from: "/remote", to: "/work"))
    try fixture.store.updateSourceSettings(for: fixture.source, from: expected, to: updated, hostHome: nil)
    #expect(try fixture.store.events(in: remapped.key).isEmpty)
    #expect(try fixture.store.events(in: unaffected.key).count == 1)
    #expect(try fixture.total() == 2)
    #expect(try fixture.store.checkpoint(for: remapped.file)?.parserVersion == 0)
    #expect(try fixture.store.checkpoint(for: unaffected.file)?.parserVersion == 1)
}

@Test("SEC-7: mapped exclusions normalize recorded separators and dot components",
      arguments: [false, true])
func mappedWorkspaceUsesNormalizedPath(importBeforeRule: Bool) throws {
    let fixture = try ExclusionFixture()
    defer { fixture.remove() }
    if !importBeforeRule {
        _ = try fixture.store.replaceSessionExclusions(["/work/private/**"], hostHome: nil)
    }
    let hidden = try fixture.seed("mapped-dirty-path", cwd: "/mnt//./private/repo/", count: 11)
    let ordinary = try fixture.seed("mapped-safe-path", cwd: "/mnt//./public/repo/", count: 3)
    if importBeforeRule {
        #expect(try fixture.total() == 14)
        let update = try fixture.store.replaceSessionExclusions(["/work/private/**"], hostHome: nil)
        #expect(update.removedSessions == 1)
    }
    #expect(try fixture.store.events(in: hidden.key).isEmpty)
    #expect(try fixture.store.events(in: ordinary.key).count == 1)
    #expect(try fixture.store.searchIndex(SearchQuery.parse("synthetic"), scope: fixture.scope).sessionCount == 1)
    #expect(try fixture.total() == 3)
}

@Test("SEC-7: a byte-only change of the mapped path applies existing exclusions")
func unicodeMappingChangePurgesSearchAndUsage() throws {
    let fixture = try ExclusionFixture()
    defer { fixture.remove() }
    let source = try #require(try fixture.store.sources().first)
    let original = SourceSettings(source)
    var before = original
    before.pathMappings = [.init(from: "/mnt", to: "/work/cafe\u{301}")]
    try fixture.store.updateSourceSettings(for: fixture.source, from: original, to: before, hostHome: nil)
    _ = try fixture.store.replaceSessionExclusions(["/work/caf\u{e9}/**"], hostHome: nil)
    let existing = try fixture.seed("byte-exact-mapping", cwd: "/mnt/project", count: 9)
    #expect(try fixture.total() == 9)
    var after = before
    after.pathMappings = [.init(from: "/mnt", to: "/work/caf\u{e9}")]
    try fixture.store.updateSourceSettings(for: fixture.source, from: before, to: after, hostHome: nil)
    #expect(try fixture.store.events(in: existing.key).isEmpty)
    #expect(try fixture.store.searchIndex(SearchQuery.parse("synthetic"), scope: fixture.scope).sessionCount == 0)
    #expect(try fixture.total() == 0)
}

@Test("SEC-7: only trustworthy workspace evidence can release an exclusion after remapping its source")
func remappingReevaluatesExcludedWorkspace() throws {
    let fixture = try ExclusionFixture()
    defer { fixture.remove() }
    _ = try fixture.store.replaceSessionExclusions(["/work/private/**"], hostHome: nil)
    let hidden = try fixture.seed("previously-excluded", cwd: "/mnt/private/repo", count: 11)
    let source = try #require(try fixture.store.sources().first)
    let before = SourceSettings(source)
    var after = before
    after.pathMappings = [.init(from: "/mnt", to: "/safe")]
    try fixture.store.updateSourceSettings(for: fixture.source, from: before, to: after, hostHome: nil)
    let copied: NormalizedRecord = .event(.init(session: hidden.key, sequence: 4, timestamp: fixture.stamp,
        kind: .assistant, text: "synthetic copy", dedupeKey: "previously-excluded:copy"))
    try fixture.store.write([.session(.init(key: hidden.key, sourceID: fixture.source, environment: "Synthetic",
        cwd: "/mnt/private/repo", referenceOnly: true)), copied])
    #expect(try fixture.store.events(in: hidden.key).isEmpty)
    try fixture.store.write([.session(.init(key: hidden.key, sourceID: fixture.source, environment: "Synthetic",
        cwd: "/mnt/../ambiguous")), copied])
    #expect(try fixture.store.events(in: hidden.key).isEmpty)
    let other = try fixture.store.upsertSource(.init(agent: .codex, label: "Other synthetic source",
        rootURL: fixture.dir.appendingPathComponent("other")))
    try fixture.store.write([.session(.init(key: hidden.key, sourceID: other, environment: "Synthetic",
        cwd: "/safe/unrelated")), copied])
    #expect(try fixture.store.events(in: hidden.key).isEmpty)
    let position = try fixture.store.fileImportPosition(for: hidden.file)
    _ = try fixture.store.commitFileBatch([
        .session(.init(key: hidden.key, sourceID: fixture.source, fileID: hidden.file, environment: "Synthetic", cwd: "/mnt/private/repo")),
        .event(.init(session: hidden.key, sequence: 0, timestamp: fixture.stamp, kind: .user,
                     text: "synthetic original", dedupeKey: "previously-excluded:event")),
        .tokens(.init(session: hidden.key, timestamp: fixture.stamp, counts: .init(output: 11), dedupeKey: "previously-excluded:tokens")),
    ], for: hidden.file, from: position.checkpoint, to: fixture.checkpoint, exclusionRevision: position.exclusionRevision)
    #expect(try fixture.store.events(in: hidden.key).count == 1)
    #expect(try fixture.total() == 11)
}
