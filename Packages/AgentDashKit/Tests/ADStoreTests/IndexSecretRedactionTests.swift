import ADCore
import ADStore
import Foundation
import Testing

@Test("SEC-8: opt-in redaction rewrites stored text and FTS while retaining identifiers and accounting")
func scrubStoredCredentialsWithoutChangingUsage() throws {
    let box = FileManager.default.temporaryDirectory.appendingPathComponent("index-redaction-\(UUID())")
    try FileManager.default.createDirectory(at: box, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: box) }
    let index = box.appendingPathComponent("index.sqlite")
    let store = try AgentStore(databaseURL: index)
    let sourceID = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic", rootURL: box))
    let key = SessionKey(agent: .claudeCode, nativeID: "synthetic-session")
    let now: Int64 = 1_770_000_000_000
    let initial = "synthetic-original-not-a-real-secret"
    let sameID = "sk-synthetic-not-an-actual-secret-id"
    let rawBody = "API_TOKEN=" + initial + "\nvisible ordinary text"
    let meta = #"{"tool_use_id":"\#(sameID)","claude_message_id":"\#(sameID)","signal":"assistant.turn_end","command_token":"fake-local-value"}"#
    func record(_ id: String, body: String, sequence: Int64, metadata: String? = nil) -> NormalizedRecord {
        .event(.init(session: key, sequence: sequence, timestamp: now, kind: .assistant, text: body,
                     metadataJSON: metadata, dedupeKey: id))
    }
    let scope = IndexedSearchScope(now: now + 1, timeZone: .gmt)
    let query = try SearchQuery.parse(SearchQuery.quotedLiteral(initial))
    #expect(try store.displaySecretMaskingEnabled() && !store.indexSecretRedactionEnabled())
    try store.write([
        .session(.init(key: key, sourceID: sourceID, environment: "Synthetic", title: "API_TOKEN=" + initial)),
        record("synthetic-first", body: rawBody, sequence: 0, metadata: meta),
        record("synthetic-second", body: "visible follow-up", sequence: 1, metadata: meta),
        .tokens(.init(session: key, timestamp: now, model: "synthetic-model", counts: .init(inputFresh: 2, cacheRead: 3, output: 4),
                      dedupeKey: "synthetic-usage")),
    ])
    #expect(try store.searchIndex(query, scope: scope).matchCount == 1)
    try store.setDisplaySecretMaskingEnabled(false)
    #expect(try store.events(in: key).first?.text == rawBody)
    #expect(try store.setIndexSecretRedactionEnabled(true))
    let scrubbed = try store.events(in: key)
    #expect(scrubbed.map(\.dedupeKey) == ["synthetic-first", "synthetic-second"])
    #expect(scrubbed.first?.text == "API_TOKEN=••••••\nvisible ordinary text")
    let fields = try scrubbed.map { event in
        let json = try #require(event.metadataJSON)
        return try JSONDecoder().decode([String: String].self, from: Data(json.utf8))
    }
    #expect(fields.count == 2 && fields.first == fields.last)
    #expect(fields.first?["signal"] == "assistant.turn_end")
    #expect(fields.first?["command_token"] == "••••••")
    #expect(fields.first?["tool_use_id"]?.hasPrefix("masked-call:") == true)
    #expect(fields.first?["claude_message_id"] == fields.first?["tool_use_id"])
    #expect(try store.searchIndex(query, scope: scope).matchCount == 0)
    #expect(try store.searchIndex(SearchQuery.parse("ordinary"), scope: scope).matchCount == 1)

    let reopened = try AgentStore(databaseURL: index)
    #expect(try !reopened.displaySecretMaskingEnabled() && reopened.indexSecretRedactionEnabled())
    try reopened.write([record("synthetic-new", body: "API_TOKEN=synthetic-next-value", sequence: 2, metadata: "{malformed")])
    #expect(try reopened.events(in: key).last?.text == "API_TOKEN=••••••")
    #expect(try reopened.events(in: key).last?.metadataJSON == nil)
    let window = try UsageWindow.make(.hour, now: now + 60_000, timeZone: .gmt)
    #expect(try reopened.usage(window: window).totals.counts.total == 9)
    #expect(try reopened.setIndexSecretRedactionEnabled(false))
    #expect(try reopened.events(in: key).first?.text == scrubbed.first?.text)
}
