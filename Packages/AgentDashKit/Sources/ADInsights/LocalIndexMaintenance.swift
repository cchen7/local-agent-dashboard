import ADPrivacy
import ADStore

public enum LocalIndexMaintenance {
    /// Recompute projections using the same topic tokenizer and masking as Overview.
    public static func rebuild(_ store: AgentStore) throws -> IndexRebuildResult {
        let scorer = try TopicScorer()
        return try store.rebuildIndex(scoring: .init(counts: { input in
            let document: TopicDocument
            switch input {
            case .prompt(let text):
                document = .init(userPrompts: [SecretMasker.mask(text)], assistantReplies: [], fileNames: [])
            case .reply(let text):
                document = .init(userPrompts: [], assistantReplies: [SecretMasker.mask(text)], fileNames: [])
            case .path(let path):
                let file = SecretMasker.mask(path).split(separator: "/").last.map(String.init)
                document = .init(userPrompts: [], assistantReplies: [], fileNames: file.map { [$0] } ?? [])
            }
            return scorer.counts(for: document)
        }, top: { counts, documents, frequencies in
            scorer.top(counts, documentCount: documents, documentFrequency: frequencies).map { ($0.term, $0.score) }
        }))
    }
}
