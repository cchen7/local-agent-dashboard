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
