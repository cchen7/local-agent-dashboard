import ADCore
import ADPricing
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("FR-STO-1: project clear uses mapped membership and preserves other source data and shared file users",
      .timeLimit(.minutes(1)))
func projectClearTargetsOnlyConfirmedMappedMembers() async throws {
    let box = try ClearFixture()
    defer { box.remove() }
    let target = try box.seed("target", at: box.first, cwd: "/workspace/project", tokens: 7)
    let shared = try box.seed("shared", at: box.first, cwd: "/workspace/other", tokens: 3, existingFile: target.fileID)
    let other = try box.seed("other", at: box.second, cwd: "/workspace/project", tokens: 11)
    try await box.store.databasePool.write { db in
        try db.execute(sql: "UPDATE sessions SET parent_session_id=(SELECT id FROM sessions WHERE native_id='target') WHERE native_id='other'")
    }
    let before = try box.store.checkpoint(for: other.fileID)
    let eventsBefore = try box.store.events(in: other.key)
    let original = try Data(contentsOf: box.rawFile)
    var choices = box.store.indexClearChoices(hostHome: nil).makeAsyncIterator()
    let current = try #require(try await choices.next())
    let mapped = try #require(current.first { $0.location == "/mapped/first/project" })
    let plan = try box.store.prepareIndexClear(mapped.id, hostHome: nil)
    #expect(plan.sessionCount == 1 && plan.fileCount == 1)
    #expect(plan.label?.contains("/mapped/first/project") == true)
    let result = try box.store.clearIndex(plan, hostHome: nil)
    #expect(result.removedSessions == 1 && result.resetFiles == 1)
    #expect(try box.store.events(in: target.key).isEmpty)
    #expect(try box.store.events(in: shared.key).count == 1)
    #expect(try box.store.events(in: other.key) == eventsBefore)
    #expect(try box.store.checkpoint(for: target.fileID) == nil)
    #expect(try box.store.checkpoint(for: other.fileID) == before)
    #expect(try box.store.searchIndex(SearchQuery.parse("synthetic"), scope: box.scope).sessionCount == 2)
    let usage = try box.totals()
    #expect(usage.counts.total == 14 && usage.costMicroUSD == 28)
    #expect(try Data(contentsOf: box.rawFile) == original)
}

@Test("FR-STO-1: newly added membership aborts a previously confirmed source clear")
func staleIndexClearPlanDoesNotDeleteNewMembers() throws {
    let box = try ClearFixture()
    defer { box.remove() }
    let first = try box.seed("initial", at: box.first, cwd: "/workspace/project", tokens: 2)
    let plan = try box.store.prepareIndexClear(.source(box.first), hostHome: nil)
    let second = try box.seed("new", at: box.first, cwd: "/workspace/project", tokens: 3, existingFile: first.fileID)
    #expect(throws: IndexClearError.selectionChanged) { try box.store.clearIndex(plan, hostHome: nil) }
    #expect(try box.store.events(in: first.key).count == 1)
    #expect(try box.store.events(in: second.key).count == 1)
    #expect(try box.store.checkpoint(for: first.fileID)?.offset == 20)
    #expect(try box.totals().counts.total == 5)
}

@Test("FR-STO-1: removing a source's retained index leaves other sources and agent-wide quota data intact",
      .timeLimit(.minutes(1)))
func removedSourceRemainsAvailableForScopedClear() async throws {
    let box = try ClearFixture()
    defer { box.remove() }
    _ = try box.seed("retired", at: box.first, cwd: "/workspace/project", tokens: 7)
    let kept = try box.seed("keep", at: box.second, cwd: "/workspace/project", tokens: 11)
    try box.store.write([.rateLimit(.init(agent: .codex, limitID: "synthetic", window: .primary,
                                        timestamp: box.stamp, windowMinutes: 300, usedPercent: 25))])
    try box.store.removeRegisteredSource(box.first)
    var watch = box.store.indexClearChoices(hostHome: nil).makeAsyncIterator()
    let available = try #require(try await watch.next())
    #expect(available.contains { $0.id == .source(box.first) && $0.removedSource })
    let selected = try box.store.prepareIndexClear(.source(box.first), hostHome: nil)
    #expect(selected.sessionCount == 1)
    let result = try box.store.clearIndex(selected, hostHome: nil)
    #expect(result.removedSessions == 1 && result.resetFiles == 1)
    #expect(try box.store.events(in: kept.key).count == 1)
    #expect(try box.store.sources().map(\.id) == [box.second])
    #expect(try await box.store.databasePool.read { db in
        try Int.fetchOne(db, sql: "SELECT count(*) FROM rate_limit_snapshots") == 1
    })
    let usage = try box.totals()
    #expect(usage.counts.total == 11 && usage.costMicroUSD == 22)
}

@Test("FR-STO-1: clear everything drops legacy usage and derived rows while preserving settings and grants")
func clearAllIncludesLegacyIndexData() throws {
    let box = try ClearFixture()
    defer { box.remove() }
    _ = try box.seed("only", at: box.first, cwd: "/workspace/project", tokens: 7)
    let grants = try box.store.sources()
    try box.store.setDisplaySecretMaskingEnabled(false)
    _ = try box.store.saveSessionSearch(name: "Synthetic saved query", query: "ordinary")
    try box.store.write([.rateLimit(.init(agent: .codex, limitID: "synthetic", window: .primary,
                                        timestamp: box.stamp, windowMinutes: 300, usedPercent: 25))])
    try box.store.databasePool.write { db in
        try db.execute(sql: "INSERT INTO token_minute VALUES(-2,'codex',0,'legacy-synthetic','call',9,0,0,0,0,0,3,0,1)")
    }
    let plan = try box.store.prepareIndexClear(.everything, hostHome: nil)
    let result = try box.store.clearIndex(plan, hostHome: nil)
    #expect(result.removedSessions == 1 && result.resetFiles == 1)
    #expect(try box.store.sources() == grants)
    #expect(try !box.store.displaySecretMaskingEnabled())
    try box.store.databasePool.read { db throws -> Void in
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM saved_searches") == 1)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM rate_limit_snapshots") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_minute") == 0)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_usage_scope") == 0)
    }
    #expect(try box.store.searchIndex(SearchQuery.parse("synthetic"), scope: box.scope).matchCount == 0)
    #expect(try box.totals().counts.total == 0)
}

private struct ClearFixture {
    let folder: URL
    let rawFile: URL
    let store: AgentStore
    let first: Int64
    let second: Int64
    let stamp: Int64 = 1_770_000_000_000
    var scope: IndexedSearchScope { .init(now: stamp + 60_000, timeZone: .gmt) }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("index-clear-\(UUID())")
        let firstRoot = folder.appendingPathComponent("first")
        let secondRoot = folder.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: firstRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: true)
        rawFile = firstRoot.appendingPathComponent("target.jsonl")
        try Data("{\"type\":\"synthetic original\"}\n".utf8).write(to: rawFile)
        store = try AgentStore(databaseURL: folder.appendingPathComponent("index.sqlite"))
        first = try store.upsertSource(.init(agent: .codex, label: "Synthetic first", rootURL: firstRoot, environment: "A",
                                             pathMappings: [.init(from: "/workspace", to: "/mapped/first")]))
        second = try store.upsertSource(.init(agent: .codex, label: "Synthetic second", rootURL: secondRoot, environment: "B",
                                              pathMappings: [.init(from: "/workspace", to: "/mapped/second")]))
        let table = try PriceTable.decode(Data(#"{"schemaVersion":1,"currency":"USD","unit":"per_million_tokens","updatedAt":"2026-01-01","models":[{"id":"synthetic-model","vendor":"fixture","displayName":"Synthetic","prices":[{"effectiveFrom":"2020-01-01","input":1,"output":2,"source":"https://example.invalid/","checkedAt":"2020-01-01"}]}]}"#.utf8))
        _ = try store.activatePricing(TokenQuoteEngine.make(table: table))
    }

    func seed(_ nativeID: String, at sourceID: Int64, cwd: String, tokens: Int64,
              existingFile: Int64? = nil) throws -> (key: SessionKey, fileID: Int64) {
        let key = SessionKey(agent: .codex, nativeID: nativeID)
        let fileID = try existingFile ?? store.upsertFile(.init(sourceID: sourceID, relativePath: nativeID + ".jsonl", role: .session),
                                                         checkpoint: nil)
        let checkpoint = Checkpoint(inode: 2, size: 20, offset: 20, parserVersion: 1, sequence: 0, previousTimestamp: stamp)
        let records: [NormalizedRecord] = [
            .session(.init(key: key, sourceID: sourceID, fileID: fileID, environment: "Synthetic", cwd: cwd)),
            .event(.init(session: key, sequence: 0, timestamp: stamp, kind: .user, text: "synthetic transcript", dedupeKey: nativeID + ":message")),
            .tokens(.init(session: key, timestamp: stamp, model: "synthetic-model", counts: .init(output: tokens), dedupeKey: nativeID + ":usage")),
        ]
        if existingFile == nil { try store.commitFileBatch(records, for: fileID, from: nil, to: checkpoint) }
        else { try store.write(records) }
        return (key, fileID)
    }

    func totals() throws -> UsageTotals {
        let window = try UsageWindow.make(.hour, now: stamp + 60_000, timeZone: .gmt)
        return try store.usage(window: window).totals
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

@Test("FR-STO-1: project clear rejects a preview when Path Mapping moves the original member", .timeLimit(.minutes(1)))
func movedWorkspaceCannotBeClearedUsingOldProjectPreview() async throws {
    let box = try ClearFixture()
    defer { box.remove() }
    let former = try box.seed("former", at: box.first, cwd: "/workspace/project", tokens: 5)
    var choices = box.store.indexClearChoices(hostHome: nil).makeAsyncIterator()
    let list = try #require(try await choices.next())
    let project = try #require(list.first { $0.location == "/mapped/first/project" })
    let plan = try box.store.prepareIndexClear(project.id, hostHome: nil)
    let current = try #require(try box.store.sources().first { $0.id == box.first })
    let settings = SourceSettings(current)
    var updated = settings
    updated.pathMappings = [.init(from: "/workspace", to: "/mapped/moved")]
    try box.store.updateSourceSettings(for: box.first, from: settings, to: updated, hostHome: nil)
    #expect(throws: IndexClearError.selectionChanged) { try box.store.clearIndex(plan, hostHome: nil) }
    #expect(try box.store.events(in: former.key).count == 1)
    #expect(try box.totals().counts.total == 5)
}
