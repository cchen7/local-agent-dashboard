import ADPrivacy
import ADStore

public enum LocalIndexMaintenance {
    /// Recompute projections using the same topic tokenizer and masking as Overview.
    public static func rebuild(_ store: AgentStore) throws -> IndexRebuildResult {
        try store.rebuildIndex(scoring: topicScoring())
    }

    static func topicScoring() throws -> IndexTopicScoring {
        let scorer = try TopicScorer()
        return .init(counts: { input in
            let document: TopicDocument
            switch input {
            case .prompt(let text):
                document = .init(userPrompts: [IndexSecretMasker.text(text)], assistantReplies: [], fileNames: [])
            case .reply(let text):
                document = .init(userPrompts: [], assistantReplies: [IndexSecretMasker.text(text)], fileNames: [])
            case .path(let path):
                let file = IndexSecretMasker.text(path).split(separator: "/").last.map(String.init)
                document = .init(userPrompts: [], assistantReplies: [], fileNames: file.map { [$0] } ?? [])
            }
            return scorer.counts(for: document)
        }, top: { counts, documents, frequencies in
            scorer.top(counts, documentCount: documents, documentFrequency: frequencies).map { ($0.term, $0.score) }
        })
    }
}
