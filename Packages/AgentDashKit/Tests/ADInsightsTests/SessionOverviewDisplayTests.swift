import ADCore
import ADInsights
@testable import ADStore
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
