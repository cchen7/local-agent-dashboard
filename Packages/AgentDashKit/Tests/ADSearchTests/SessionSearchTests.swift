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

@Test("FR-SR: interleaved writes keep exact session counts, relevance and earliest anchors")
func interleavedSearchUsesAllHitsForEachSession() throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let a = fixture.session("interleaved-a", cwd: "/synthetic/work/a")
    let b = fixture.session("interleaved-b", cwd: "/synthetic/work/b")
    try fixture.store.write([
        .session(a), .session(b),
        fixture.event(a.key, "a-later", 4, "auth"),
        fixture.event(b.key, "b-later", 3, "auth"),
        fixture.event(a.key, "a-earliest", 1, "auth"),
        fixture.event(b.key, "b-earliest", 1, "auth"),
        fixture.event(a.key, "a-best", 2, "auth auth auth"),
    ])
    let exact = try fixture.run("auth OR middleware")
    #expect(exact.sessionCount == 2 && exact.matchCount == 5)
    #expect(exact.hits.map(\.id) == [a.key, b.key])
    #expect(exact.hits.map(\.matchCount) == [3, 2])
    #expect(exact.hits.map(\.firstMatchKey) == ["a-earliest", "b-earliest"])
    #expect(exact.hits.first?.snippet.filter(\.highlighted).count == 3)
}

@Test("FR-SR: navigation keeps query scope, file order, stable ties and bounded pages")
func navigatesMatchesWithinTheSelectedSession() throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let primary = fixture.session("nav-primary", cwd: "/synthetic/work/client")
    let other = fixture.session("nav-other", cwd: "/synthetic/work/client")
    let query = "登录 role:assistant dir:~/work/client -discarded"
    var records: [NormalizedRecord] = [
        .session(primary), .session(other),
        fixture.event(primary.key, "tie-first", 1, "先检查登录", timestamp: 300),
        fixture.event(primary.key, "tie-second", 1, "检查登录配置", timestamp: 200),
        fixture.event(primary.key, "discarded", 2, "discarded 登录"),
        fixture.event(primary.key, "user", 3, "登录", kind: .user),
        fixture.event(other.key, "other-match", 1, "登录"),
    ]
    records += (4...290).map { fixture.event(primary.key, "filler-\($0)", Int64($0), "synthetic filler") }
    records.append(fixture.event(primary.key, "last", 291, "完成登录修复", timestamp: 100))
    try fixture.store.write(records)

    func locate(_ key: String? = nil, session: SessionKey? = nil) throws -> IndexedSearchMatchPosition? {
        try SessionSearch.position(query, in: fixture.store, scope: fixture.scope,
                                   session: session ?? primary.key, around: key)
    }
    let first = try #require(try locate())
    #expect(first.eventKey == "tie-first")
    #expect(first.ordinal == 1 && first.count == 3 && first.previousKey == nil)
    #expect(first.eventKey == (try fixture.run(query)).hits.first { $0.id == primary.key }?.firstMatchKey)
    let middle = try #require(try locate(first.nextKey))
    #expect(middle.eventKey == "tie-second" && middle.ordinal == 2)
    #expect(middle.previousKey == first.eventKey && middle.nextKey == "last")
    let last = try #require(try locate(middle.nextKey))
    #expect(last.eventKey == "last" && last.ordinal == 3 && last.nextKey == nil)
    let page = try #require(try fixture.store.transcriptPage(in: primary.key, request: .around(last.eventKey)))
    #expect(page.events.last?.dedupeKey == "last" && page.events.count == 128)
    #expect(!page.events.contains { $0.dedupeKey == first.eventKey })
    #expect(try locate("other-match") == first)
    let only = try #require(try locate(last.eventKey, session: other.key))
    #expect(only.eventKey == "other-match" && only.ordinal == 1 && only.count == 1)
    #expect(only.previousKey == nil && only.nextKey == nil)
}

@Test("FR-SR: a live rewrite keeps the preferred hit by key and falls back when it stops matching")
func matchNavigationRevalidatesItsAnchor() throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let session = fixture.session("nav-live", cwd: "/synthetic/work")
    let query = "登录"
    func locate(_ key: String) throws -> IndexedSearchMatchPosition? {
        try SessionSearch.position(query, in: fixture.store, scope: fixture.scope, session: session.key, around: key)
    }
    try fixture.store.write([.session(session),
        fixture.event(session.key, "first", 1, "登录"),
        fixture.event(session.key, "current", 2, "登录"),
        fixture.event(session.key, "last", 3, "登录")])
    let old = try #require(try locate("current"))
    #expect(old.ordinal == 2 && old.count == 3)

    try fixture.store.write([fixture.event(session.key, "current", 4, "登录")])
    let moved = try #require(try locate("current"))
    #expect(moved.eventKey == "current" && moved.ordinal == 3 && moved.previousKey == "last")
    try fixture.store.write([fixture.event(session.key, "current", 4, "修复完毕")])
    let reset = try #require(try locate("current"))
    #expect(reset.eventKey == "first" && reset.ordinal == 1 && reset.count == 2 && reset.nextKey == "last")
    try fixture.store.write([fixture.event(session.key, "first", 1, "不匹配"),
                             fixture.event(session.key, "last", 3, "不匹配")])
    #expect(try locate("current") == nil)
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
    try populateMillionSearchEntries(fixture)

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

        let top = try #require(try fixture.run(query).hits.first)
        let first = try #require(try SessionSearch.position(query, in: fixture.store, scope: fixture.scope,
                                                            session: top.id, around: top.firstMatchKey))
        let target = try #require(first.nextKey)
        #expect(first.count == top.matchCount)
        var steps: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let position = try SessionSearch.position(query, in: fixture.store, scope: fixture.scope,
                                                      session: top.id, around: target)
            let elapsed = start.duration(to: .now).components
            steps.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(position?.ordinal == 2 && position?.previousKey == first.eventKey)
        }
        let stepP95 = steps.sorted()[18]
        print("1M synthetic match navigation / \(label): warm P95 \(stepP95) ms")
        #expect(stepP95 < 150)
    }
}

@Test("NFR-4: token-volume order on one million synthetic token events",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_SEARCH_BENCHMARK"] == "1"),
      .timeLimit(.minutes(5)))
func millionTokenEventVolumeOrderLatency() throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    try populateMillionSearchEntries(fixture)
    // 500 calls per session. Fresh input permutes ids modulo the prime 2003, so
    // every session total is distinct and the expected order has no ties.
    try fixture.store.databasePool.write { db in
        try db.execute(sql: """
            WITH RECURSIVE seq(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM seq WHERE n<499)
            INSERT INTO token_events(session_id,agent,ts,input_fresh,cache_read,cache_write,cache_write_1h,output,dedupe_key)
            SELECT s.id,'codex',1795000000000+seq.n,(s.id*7919)%2003,seq.n%5,seq.n%3,seq.n%2,seq.n%7+1,
                   printf('tokens:%lld:%d',s.id,seq.n)
            FROM sessions s CROSS JOIN seq
            """)
        #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events") == 1_000_000)
    }
    for (label, query, sessions) in [("broad OR", "auth OR middleware", 2_000), ("mixed", "登录 verify", 2_000)] {
        let first = try fixture.run(query, order: .tokens)
        #expect(first.sessionCount == sessions)
        let expected = try fixture.store.databasePool.read { db in
            try Int64.fetchAll(db, sql: """
                SELECT session_id FROM token_events GROUP BY session_id
                ORDER BY sum(input_fresh+cache_read+cache_write+cache_write_1h+output) DESC LIMIT 3
                """)
        }
        let leaders = try fixture.store.databasePool.read { db in
            try first.hits.prefix(3).map { hit in
                try #require(try Int64.fetchOne(db, sql: "SELECT id FROM sessions WHERE agent=? AND native_id=?",
                                                arguments: [hit.id.agent.rawValue, hit.id.nativeID]))
            }
        }
        #expect(leaders == expected)
        var samples: [Double] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            let result = try fixture.run(query, order: .tokens)
            let elapsed = start.duration(to: .now).components
            samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            #expect(result.sessionCount == sessions)
        }
        let p95 = samples.sorted()[18]
        print("1M token events / \(label) by token volume: warm P95 \(p95) ms")
        #expect(p95 < 150)
    }
}

/// Export from the exact same workload used by the package latency check.
@Test("NFR-4: export a verified million-message native search fixture",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_NATIVE_SEARCH_EXPORT"] != nil))
func exportNativeSearchFixture() throws {
    let id = try #require(ProcessInfo.processInfo.environment["AGENTDASH_NATIVE_SEARCH_EXPORT"]
        .flatMap(UUID.init(uuidString:)))
    let directory = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("agentdash-search-fixture-\(id.uuidString)", isDirectory: true)
    let fixture = try SearchFixture(directory: directory)
    var complete = false
    defer { if !complete { fixture.remove() } }
    try populateMillionSearchEntries(fixture)
    _ = try fixture.store.databasePool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
    try fixture.store.databasePool.close()
    let index = directory.appendingPathComponent("index.sqlite")
    let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
    let bytes = try #require((attributes[.size] as? NSNumber)?.int64Value)
    try JSONEncoder().encode(["bytes": bytes, "events": 1_000_000, "sessions": 2_000])
        .write(to: directory.appendingPathComponent("proof.json"), options: .withoutOverwriting)
    complete = true
}

private func populateMillionSearchEntries(_ fixture: SearchFixture) throws {
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
}

private struct SearchFixture {
    let directory: URL
    let store: AgentStore
    let scope: IndexedSearchScope
    let sourceID: Int64

    init(timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current, directory requested: URL? = nil) throws {
        directory = requested ?? FileManager.default.temporaryDirectory.appendingPathComponent("indexed-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
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

    func run(_ query: String, order: SessionSearchOrder = .relevance, limit: Int = 50,
             offset: Int = 0) throws -> SessionSearchResults {
        try SessionSearch.run(query, in: store, scope: scope, order: order, limit: limit, offset: offset)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
