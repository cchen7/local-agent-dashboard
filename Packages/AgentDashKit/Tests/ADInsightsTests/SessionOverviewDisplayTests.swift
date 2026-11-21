import ADCore
import ADInsights
@testable import ADStore
import Foundation
import Testing

@Test("SEC-8: an overview masks complete values before excerpts or validating catalog keywords")
func overviewNeverExposesTruncatedCredentialFragments() throws {
    let phrase = "secretsuffix"
    let token = "sk-proj-" + String(repeating: "synthetic", count: 20) + phrase
    let prompt = "API_TOKEN=" + token + " # visible comment\n" + String(repeating: "rotation ", count: 40)
    let reply = "USER_SECRET=" + token + "\n" + String(repeating: "lookup ", count: 60)
    let command = IndexedOverviewCommand(text: "SERVICE_TOKEN=" + token, timestamp: 50, exitCode: 0, durationMS: 40)
    let raw = IndexedSessionOverview(summary: "Synthetic rotation summary", lastPrompt: prompt, lastReply: reply,
                                     topics: [phrase, "rotation", "lookup"], recentActions: [.command(command)],
                                     files: [], commands: [command])
    let safe = SessionOverviewDisplay(raw, scorer: try TopicScorer())
    #expect(safe.lastPrompt?.hasPrefix("API_TOKEN=•••••• # visible comment") == true)
    #expect(safe.lastPrompt?.count == 201)
    #expect(safe.lastReply?.count == 301)
    #expect(safe.lastReply?.contains(phrase) == false)
    #expect(safe.topics == ["rotation", "lookup"])
    #expect(safe.recentActions.first?.text == "SERVICE_TOKEN=••••••")
    #expect(safe.commands.first?.exitCode == 0 && safe.commands.first?.durationMS == 40)
}

@Test("SEC-8: join only the selected Claude record in numeric block order before masking its excerpt",
      .timeLimit(.minutes(1)))
func overviewMasksCredentialsAcrossClaudeBlocks() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("overview-mask-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
    let sourceID = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic", rootURL: directory))
    let session = SessionKey(agent: .claudeCode, nativeID: "synthetic-mask")
    func event(_ suffix: String, _ text: String) -> NormalizedRecord {
        .event(.init(session: session, sequence: 14, timestamp: 100, kind: .assistant,
                     text: text, dedupeKey: "claude:event:" + suffix))
    }

    // Both decoys share the sequence. One even shares the prefix up to the
    // last identifier component. Store the selected blocks in reverse order.
    let tail = String(repeating: "synthetic", count: 40) + "synthetictail"
    try store.write([
        .session(.init(key: session, sourceID: sourceID, environment: "Synthetic")),
        event("copied:0", "Other record"),
        event("selected:part:9:0", "Nested decoy"),
        event("selected:part:10", "j-" + tail + " # visible comment"),
        event("selected:part:2", "API_TOKEN=sk-pro"),
    ])
    var snapshots = store.sessionOverviewUpdates(in: session).makeAsyncIterator()
    let first = try await snapshots.next()
    let raw = try #require(first ?? nil)
    #expect(raw.lastReply == "API_TOKEN=sk-proj-" + tail + " # visible comment")
    #expect(SessionOverviewDisplay(raw).lastReply == "API_TOKEN=•••••• # visible comment")
}
