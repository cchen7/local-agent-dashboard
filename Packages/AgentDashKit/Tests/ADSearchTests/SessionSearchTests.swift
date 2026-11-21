import ADCore
import ADSearch
@testable import ADStore
import Foundation
import GRDB
import Testing

@Test("FR-SR: Chinese, identifier aliases, OR, exclusion and exact quoted phrase share the index")
func mixedSearchGroupsAndAnchors() throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let primary = fixture.session("primary", cwd: "/synthetic/work/client")
    let sibling = fixture.session("secondary", cwd: "/synthetic/work/client-legacy")
    try fixture.store.write([
        .session(primary), .session(sibling),
        fixture.event(primary.key, "later", 3, "继续修复登录问题，fix verifyAndRotate middleware"),
        fixture.event(primary.key, "first", 1, "修复登录问题 and verifyAndRotate: refresh token"),
        fixture.event(primary.key, "excluded", 2, "修复登录问题 and verifyAndRotate discarded"),
        fixture.event(sibling.key, "or-result", 1, "redis auth alternative"),
        fixture.event(sibling.key, "not-a-phrase", 2, "refresh updated token"),
    ])
    let result = try fixture.run("登录 verify -discarded OR redis")
    #expect(result.matchCount == 3)
    #expect(result.sessionCount == 2)
    let chinese = try #require(result.hits.first { $0.id == primary.key })
    #expect(chinese.matchCount == 2)
    #expect(chinese.firstMatchKey == "first")
    #expect(chinese.snippet.contains { $0.highlighted && $0.text == "登录" })
    let page = try #require(try fixture.store.transcriptPage(in: chinese.id, request: .around(chinese.firstMatchKey)))
    #expect(page.events.contains { $0.dedupeKey == "first" })
    let wrong = try fixture.store.transcriptPage(in: sibling.key, request: .around(chinese.firstMatchKey))
    #expect(wrong == nil)
    #expect(try fixture.run(#""refresh token""#).matchCount == 1)
    #expect(try fixture.run(#""redis auth""#).hits.map(\.id) == [sibling.key])
    #expect(try fixture.run("dir:~/work/client -discarded").matchCount == 2)
    let restricted = try fixture.run(#""redis auth" OR refresh"#, limit: 1)
    let second = try fixture.run(#""redis auth" OR refresh"#, limit: 1, offset: 1)
    #expect(restricted.sessionCount == 2 && second.matchCount == restricted.matchCount)
    #expect(restricted.hits.count == 1 && second.hits.count == 1)
    #expect(restricted.hits.first?.id != second.hits.first?.id)
}

@Test("FR-SR: the same query sees new sessions and event-only rewrites", .timeLimit(.minutes(1)))
func unchangedQueryPicksUpEventOnlyCommits() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let session = fixture.session("live", cwd: "/synthetic/work")
    let query = "登录"
    var changes = fixture.store.searchIndexChanges().makeAsyncIterator()
    try #require(try await changes.next() != nil)
    #expect(try fixture.run(query).matchCount == 0)

    try fixture.store.write([.session(session), fixture.event(session.key, "live-event", 1, "修复登录问题")])
    try #require(try await changes.next() != nil)
    #expect(try fixture.run(query).hits.map(\.id) == [session.key])

    // Rewrite the indexed text without changing any row in the session list.
    try fixture.store.write([fixture.event(session.key, "live-event", 1, "已完成修复")])
    try #require(try await changes.next() != nil)
    #expect(try fixture.run(query).matchCount == 0)
}

@Test("FR-SR: a Shanghai date, file and role filters work together without exposing prompt history by default")
func queriesUseStructuredFilters() throws {
    let shanghai = try #require(TimeZone(identifier: "Asia/Shanghai"))
    let fixture = try SearchFixture(timeZone: shanghai)
    defer { fixture.remove() }
    let session = fixture.session("calendar", cwd: "/synthetic/work/%client")
    // 2026-11-01 00:00 Shanghai, kept as UTC milliseconds in the index.
    let midnight: Int64 = 1_793_462_400_000
    try fixture.store.write([
        .session(session),
        fixture.event(session.key, "previous-day", 0, "login", timestamp: midnight - 1, kind: .user),
        fixture.event(session.key, "midnight", 1, "login", timestamp: midnight, kind: .user),
        fixture.event(session.key, "history", 2, "login", timestamp: midnight + 1, kind: .promptHistory),
        fixture.event(session.key, "tool", 3, "login", timestamp: midnight + 2, kind: .toolCall, tool: "Bash"),
    ])
    try fixture.store.databasePool.write { db in
        try db.execute(sql: """
            INSERT INTO projects(id,key,display_name) VALUES(1,'synthetic-project','Payments');
            UPDATE sessions SET project_id=1,model_primary='test-opus';
            INSERT INTO file_touches(session_id,path,op,count,last_ts)
            SELECT id,'src/auth.ts','edit',1,0 FROM sessions
            """)
    }
    #expect(try fixture.run("login").matchCount == 3)
    #expect(try fixture.run("login role:user after:2026-11-01 before:2026-11-02").matchCount == 2)
    let structured = try fixture.run("dir:~/work/%client project:Pay env:test model:opus file:auth.ts agent:codex tool:bash")
    #expect(structured.hits.first?.firstMatchKey == "tool")
    #expect(try fixture.run("dir:~/work/client").matchCount == 0)
    #expect(try fixture.run("before:2026-11-01").hits.first?.firstMatchKey == "previous-day")
}

@Test("SEC-8: snippet trimming and highlighting cannot reveal a matched credential suffix")
func masksCompleteSearchCandidate() throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let session = fixture.session("privacy", cwd: "/synthetic/work")
    let suffix = "SYNTHETICEND"
    let secret = "sk-proj-" + String(repeating: "demostring-", count: 10) + suffix
    let body = String(repeating: "padding ", count: 40) + secret + " ordinary login message"
    try fixture.store.write([.session(session), fixture.event(session.key, "credential", 1, body)])
    let value = try fixture.run("login OR \(suffix)")
    let hit = try #require(value.hits.first)
    let snippet = hit.snippet.map(\.text).joined()
    #expect(snippet.contains("••••••"))
    #expect(!snippet.contains(suffix))
    #expect(hit.snippet.contains { $0.highlighted && $0.text == "login" })
    let tailOnly = try fixture.run(suffix)
    #expect(tailOnly.matchCount == 1)
    #expect(!tailOnly.hits.flatMap(\.snippet).map(\.text).joined().contains(suffix))
    #expect(try fixture.store.events(in: session.key).first?.text == body)
}

@Test("NFR-4: search and safe snippets on one million synthetic index entries",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_SEARCH_BENCHMARK"] == "1"),
      .timeLimit(.minutes(3)))
func millionEntrySearchLatency() throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let sessions = (1...2_000).map { fixture.session("bench-\($0)", cwd: "/synthetic/work/bench-\($0)") }
    try fixture.store.write(sessions.map(NormalizedRecord.session))
    try fixture.store.databasePool.write { db in
        try db.execute(sql: """
            WITH RECURSIVE seq(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM seq WHERE n<499)
            INSERT INTO events(session_id,seq,ts,kind,text,dedupe_key)
            SELECT s.id,seq.n,1795000000000+seq.n,'assistant',
                   CASE WHEN seq.n%50=0 THEN '修复登录问题 verifyAndRotate auth.ts'
                        WHEN seq.n%10=0 THEN 'updated middleware cache'
                        ELSE 'Synthetic source update finished' END,
                   printf('%lld:%d',s.id,seq.n)
            FROM sessions s CROSS JOIN seq
            """)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM events") == 1_000_000)
    }

    for (label, query, expected) in [
        ("mixed", "登录 verify", 20_000),
        ("broad OR", "auth OR middleware", 100_000),
        ("directory", "dir:~/work/bench-42", 500),
    ] {
        #expect(try fixture.run(query).matchCount == expected)
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let result = try fixture.run(query)
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(result.matchCount == expected)
        }
        let p95 = samples.sorted()[18]
        print("1M synthetic search / \(label): warm P95 \(p95) ms")
        #expect(p95 < 150)
    }
}

private struct SearchFixture {
    let directory: URL
    let store: AgentStore
    let scope: IndexedSearchScope
    let sourceID: Int64

    init(timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("indexed-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic",
                                               rootURL: directory.appendingPathComponent("unused-source")))
        scope = .init(now: 1_795_000_000_000, timeZone: timeZone, hostHome: "/synthetic")
    }

    func session(_ id: String, cwd: String) -> SessionRecord {
        .init(key: .init(agent: .codex, nativeID: id), sourceID: sourceID,
              environment: "Test", cwd: cwd, title: id, startedAt: scope.now - 200)
    }

    func event(_ key: SessionKey, _ id: String, _ sequence: Int64, _ text: String,
               timestamp: Int64? = nil, kind: EventKind = .assistant, tool: String? = nil) -> NormalizedRecord {
        .event(.init(session: key, sequence: sequence, timestamp: timestamp ?? scope.now, kind: kind,
                     toolName: tool, text: text, dedupeKey: id))
    }

    func run(_ query: String, limit: Int = 50, offset: Int = 0) throws -> SessionSearchResults {
        try SessionSearch.run(query, in: store, scope: scope, limit: limit, offset: offset)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
