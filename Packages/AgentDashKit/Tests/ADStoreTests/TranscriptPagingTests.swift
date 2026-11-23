import ADCore
@testable import ADStore
import Foundation
import Testing

private func withTranscriptStore(_ body: (AgentStore, Int64) throws -> Void) throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-transcript-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp))
    try body(store, source)
}

private func transcriptEvent(_ key: SessionKey, sequence: Int64, name: String, text: String = "synthetic") -> NormalizedRecord {
    .event(.init(session: key, sequence: sequence, timestamp: 123, kind: .assistant, text: text,
                 dedupeKey: "\(key.nativeID):\(name)"))
}

@Test("NFR-9: forward and backward pages preserve file order across tied and negative sequences")
func transcriptPagingKeepsTiedOrder() throws {
    try withTranscriptStore { store, sourceID in
        let key = SessionKey(agent: .codex, nativeID: "synthetic-ties")
        try store.write([.session(.init(key: key, sourceID: sourceID, environment: "Test")),
                         transcriptEvent(key, sequence: 0, name: "b"),
                         transcriptEvent(key, sequence: -1, name: "a"),
                         transcriptEvent(key, sequence: 0, name: "c"),
                         transcriptEvent(key, sequence: 1, name: "d"),
                         transcriptEvent(key, sequence: 2, name: "e")])
        let first = try #require(try store.transcriptPage(in: key, request: .first, limit: 2))
        #expect(first.events.map(\.dedupeKey) == ["synthetic-ties:a", "synthetic-ties:b"])
        #expect(first.older == nil)
        let nextCursor = try #require(first.newer)
        let second = try #require(try store.transcriptPage(in: key, request: .after(nextCursor), limit: 2))
        #expect(second.events.map(\.dedupeKey) == ["synthetic-ties:c", "synthetic-ties:d"])
        let previousCursor = try #require(second.older)
        let lookBack = try #require(try store.transcriptPage(in: key, request: .before(previousCursor), limit: 2))
        #expect(lookBack == first)
        let finalCursor = try #require(second.newer)
        let final = try #require(try store.transcriptPage(in: key, request: .after(finalCursor), limit: 2))
        #expect(final.events.map(\.dedupeKey) == ["synthetic-ties:e"] && final.newer == nil)
        let last = try #require(try store.transcriptPage(in: key, request: .last, limit: 2))
        #expect(last.events.map(\.dedupeKey) == ["synthetic-ties:d", "synthetic-ties:e"])
        #expect(first.events + second.events + final.events == (try store.events(in: key)))
    }
}

@Test("NFR-9: match anchors stay in their session and fill a page even near either end")
func transcriptPagingAnchorsAreScoped() throws {
    try withTranscriptStore { store, sourceID in
        let key = SessionKey(agent: .codex, nativeID: "synthetic-anchor")
        let other = SessionKey(agent: .codex, nativeID: "synthetic-other-session")
        let empty = SessionKey(agent: .codex, nativeID: "synthetic-empty")
        let missing = SessionKey(agent: .codex, nativeID: "synthetic-missing")
        var records = [key, other, empty].map { NormalizedRecord.session(.init(key: $0, sourceID: sourceID, environment: "Test")) }
        records += (0..<7).map { transcriptEvent(key, sequence: Int64($0), name: "message-\($0)") }
        records.append(transcriptEvent(other, sequence: 0, name: "foreign"))
        try store.write(records)
        let nearStart = try #require(try store.transcriptPage(in: key, request: .around("synthetic-anchor:message-0"), limit: 4))
        let nearEnd = try #require(try store.transcriptPage(in: key, request: .around("synthetic-anchor:message-6"), limit: 4))
        #expect(nearStart.events.map(\.sequence) == [0, 1, 2, 3])
        #expect(nearEnd.events.map(\.sequence) == [3, 4, 5, 6])
        #expect(nearStart.older == nil && nearEnd.newer == nil)
        let one = try #require(try store.transcriptPage(in: key, request: .around("synthetic-anchor:message-3"), limit: 1))
        #expect(one.events.map(\.sequence) == [3] && one.older != nil && one.newer != nil)
        #expect(try store.transcriptPage(in: key, request: .around("synthetic-other-session:foreign")) == nil)
        #expect(try store.transcriptPage(in: key, request: .around("synthetic-anchor:stale")) == nil)
        #expect(try store.transcriptPage(in: missing, request: .first) == nil)
        let emptyPage = try #require(try store.transcriptPage(in: empty, request: .first))
        #expect(emptyPage.events.isEmpty && emptyPage.older == nil && emptyPage.newer == nil)
        let foreign = try #require(nearStart.newer)
        #expect(throws: TranscriptPagingError.foreignCursor) {
            try store.transcriptPage(in: other, request: .after(foreign))
        }
        #expect(throws: TranscriptPagingError.invalidLimit) {
            try store.transcriptPage(in: key, request: .first, limit: 0)
        }
        #expect(throws: TranscriptPagingError.invalidLimit) {
            try store.transcriptPage(in: key, request: .first, limit: 257)
        }
    }
}

@Test("NFR-9: opening and seeking a synthetic 50,000-message transcript reads bounded pages",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_TRANSCRIPT_BENCHMARK"] == "1"))
func transcriptPagingFiftyThousandMessages() throws {
    try withTranscriptStore { store, sourceID in
        let key = SessionKey(agent: .codex, nativeID: "synthetic-long")
        try store.write([.session(.init(key: key, sourceID: sourceID, environment: "Test"))])
        let text = String(repeating: "Synthetic 中文 transcript detail. ", count: 32)
        for offset in stride(from: 0, to: 50_000, by: 500) {
            let events = (offset..<(offset + 500)).map { index in
                transcriptEvent(key, sequence: index < 25_000 ? 0 : Int64(index), name: "message-\(index)", text: text)
            }
            try store.write(events)
        }
        let clock = ContinuousClock()
        var opening: [Duration] = []
        var seeks: [Duration] = []
        for _ in 0..<40 {
            let started = clock.now
            let page = try #require(try store.transcriptPage(in: key, request: .first))
            opening.append(started.duration(to: clock.now))
            #expect(page.events.count == 128 && page.events.first?.dedupeKey == "synthetic-long:message-0")
            let seekStarted = clock.now
            let deep = try #require(try store.transcriptPage(in: key, request: .around("synthetic-long:message-24900")))
            seeks.append(seekStarted.duration(to: clock.now))
            #expect(deep.events.count == 128 && deep.events[63].dedupeKey == "synthetic-long:message-24900")
        }
        let openP95 = opening.sorted()[37]
        let seekP95 = seeks.sorted()[37]
        print("50k bounded transcript, warm read P95: open \(openP95), seek \(seekP95)")
        #expect(openP95 < .milliseconds(100))
        #expect(seekP95 < .milliseconds(100))
    }
}

@Test("§11.2 / NFR-9: a far-away tool result folds at its call and remains a search anchor")
func toolResultFoldsAcrossPages() throws {
    try withTranscriptStore { store, sourceID in
        let session = SessionKey(agent: .codex, nativeID: "synthetic-paired")
        let other = SessionKey(agent: .codex, nativeID: "synthetic-pair-other")
        var records = [session, other].map {
            NormalizedRecord.session(.init(key: $0, sourceID: sourceID, environment: "Test"))
        }
        records.append(toolEvent(session, 0, .toolCall, "call", #"{"call_id":"call-1"}"#, text: "synthetic arguments"))
        records += (1...130).map { transcriptEvent(session, sequence: Int64($0), name: "message-\($0)") }
        records.append(toolEvent(session, 131, .toolResult, "result", #"{"call_id":"call-1"}"#, text: "synthetic result"))
        records.append(toolEvent(other, 131, .toolResult, "result", #"{"call_id":"call-1"}"#, text: "unrelated"))
        try store.write(records)

        let call = "\(session.nativeID):call"
        let result = "\(session.nativeID):result"
        let start = try #require(try store.transcriptPage(in: session))
        #expect(start.events.count == 128 && start.events.first?.dedupeKey == call)
        #expect(start.toolResults[call]?.dedupeKey == result)
        #expect(start.toolResults[call]?.text == "synthetic result")
        #expect(start.rowKey(forEvent: result) == call)
        #expect(try store.transcriptPage(in: session, request: .around(result)) == start)
        let cursor = try #require(start.newer)
        let next = try #require(try store.transcriptPage(in: session, request: .after(cursor)))
        #expect(next.events.map(\.sequence) == [128, 129, 130])
        #expect(next.newer == nil && next.toolResults.isEmpty)
        let older = try #require(next.older)
        #expect(try store.transcriptPage(in: session, request: .before(older)) == start)
        #expect(try store.transcriptPage(in: session, request: .around("\(other.nativeID):result")) == nil)
        #expect(try store.events(in: session).count == 132)
        #expect(try store.searchIndex(SearchQuery.parse("result"), scope: .init(now: 1_000, timeZone: .gmt))
            .groups.first?.firstMatchKey == result)
    }
}

@Test("§11.2: ambiguous, backward, malformed, and interleaved child tools stay visible separately")
func transcriptDoesNotGuessToolAssociations() throws {
    try withTranscriptStore { store, sourceID in
        let session = SessionKey(agent: .claudeCode, nativeID: "synthetic-unpaired")
        let evidence: [(EventKind, String)] = [
            (.toolCall, #"{"tool_use_id":"repeat"}"#),
            (.toolCall, #"{"tool_use_id":"repeat"}"#),
            (.toolResult, #"{"tool_use_id":"repeat"}"#),
            (.toolResult, #"{"tool_use_id":"reversed"}"#),
            (.toolCall, #"{"tool_use_id":"reversed"}"#),
            (.toolCall, #"{"call_id":"conflicting","tool_use_id":"other"}"#),
            (.toolResult, #"{"call_id":"conflicting"}"#),
            (.toolCall, #"{"call_id":"child","child_activity":true}"#),
            (.toolResult, #"{"call_id":"child","child_activity":true}"#),
            (.toolCall, #"{"call_id":"bad"#),
            (.toolResult, #"{"call_id":"bad"}"#),
            (.toolCall, #"{"call_id":42}"#),
            (.toolResult, #"{"call_id":"42"}"#),
            (.toolCall, #"{"tool_use_id":"tie"}"#),
            (.toolResult, #"{"tool_use_id":"tie"}"#),
        ]
        let records = evidence.enumerated().map { offset, event in
            toolEvent(session, Int64(min(offset, 13)), event.0, "tool-\(offset)", event.1, text: "same name")
        }
        try store.write([.session(.init(key: session, sourceID: sourceID, environment: "Test"))] + records)
        let page = try #require(try store.transcriptPage(in: session))
        #expect(page.events.count == 14)
        #expect(page.toolResults.keys.sorted() == ["\(session.nativeID):tool-13"])
        #expect(page.toolResults.values.first?.dedupeKey == "\(session.nativeID):tool-14")
    }
}

private func toolEvent(_ session: SessionKey, _ sequence: Int64, _ kind: EventKind, _ key: String,
                       _ metadata: String, text: String) -> NormalizedRecord {
    .event(.init(session: session, sequence: sequence, timestamp: 123, kind: kind, toolName: "Synthetic tool",
                 text: text, metadataJSON: metadata, dedupeKey: "\(session.nativeID):\(key)"))
}

@Test("§11.2: an already open page gains a late result and preserves both when an ID becomes ambiguous",
      .timeLimit(.minutes(1)))
func liveTranscriptUpdatesToolPairMembership() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("tool-pair-watch-\(UUID())")
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic", rootURL: temp))
    let key = SessionKey(agent: .codex, nativeID: "synthetic-late-result")
    let metadata = #"{"call_id":"live"}"#
    try store.write([.session(.init(key: key, sourceID: source, environment: "Test")),
                     toolEvent(key, 0, .toolCall, "call", metadata, text: "arguments")])
    var snapshots = try store.transcriptPageUpdates(in: key, request: .first, limit: 4).makeAsyncIterator()
    let initial = try await snapshots.next() ?? nil
    #expect(initial?.events.count == 1 && initial?.toolResults.isEmpty == true)
    try store.write([toolEvent(key, 1, .toolResult, "result", metadata, text: "synthetic result")])
    let paired = try await snapshots.next() ?? nil
    #expect(paired?.events.count == 1 && paired?.toolResults["\(key.nativeID):call"]?.text == "synthetic result")
    try store.write([toolEvent(key, 2, .toolResult, "duplicate", metadata, text: "synthetic duplicate")])
    let ambiguous = try await snapshots.next() ?? nil
    #expect(ambiguous?.events.count == 3 && ambiguous?.toolResults.isEmpty == true)
}

@Test("NFR-9: paging and search anchors stay bounded on 50,000 synthetic tool events",
      .enabled(if: ProcessInfo.processInfo.environment["AGENTDASH_TRANSCRIPT_BENCHMARK"] == "1"))
func transcriptPagingFiftyThousandToolEvents() throws {
    try withTranscriptStore { store, source in
        let key = SessionKey(agent: .codex, nativeID: "synthetic-tool-density")
        try store.write([.session(.init(key: key, sourceID: source, environment: "Test"))])
        try store.databasePool.write { db in
            try db.execute(sql: """
                WITH RECURSIVE indices(n) AS (VALUES(0) UNION ALL SELECT n+1 FROM indices WHERE n<49999)
                INSERT INTO events(session_id,seq,ts,kind,tool_name,text,meta_json,dedupe_key)
                SELECT (SELECT id FROM sessions),n,n+1,CASE WHEN n%2=0 THEN 'tool_call' ELSE 'tool_result' END,
                       'Synthetic tool','Synthetic tool transcript',
                       json_object('call_id',printf('tool-%d',n/2)),printf('event-%d',n)
                FROM indices
                """)
        }
        let clock = ContinuousClock()
        var openings: [Duration] = []
        var seeks: [Duration] = []
        for _ in 0..<40 {
            let first = clock.now
            let head = try #require(try store.transcriptPage(in: key))
            openings.append(first.duration(to: clock.now))
            #expect(head.events.count == 128 && head.toolResults.count == 128)
            let seek = clock.now
            let deep = try #require(try store.transcriptPage(in: key, request: .around("event-49777")))
            seeks.append(seek.duration(to: clock.now))
            #expect(deep.events.count == 128 && deep.toolResults.count == 128)
            #expect(deep.rowKey(forEvent: "event-49777") == "event-49776")
        }
        let open = openings.sorted()[37]
        let seek = seeks.sorted()[37]
        print("50k tool events, warm read P95: open \(open), seek \(seek)")
        #expect(open < .milliseconds(100) && seek < .milliseconds(100))
    }
}
