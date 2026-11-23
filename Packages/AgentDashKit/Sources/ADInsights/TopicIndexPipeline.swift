import ADStore

/// Runs on an actor separate from the UI and the ingestion writer. No work
/// is scheduled while the owned index has no changed documents.
public actor TopicIndexPipeline {
    private let store: AgentStore
    private let scoring: IndexTopicScoring

    public init(store: AgentStore) throws {
        self.store = store
        scoring = try LocalIndexMaintenance.topicScoring()
    }

    public func run() async throws {
        for try await revision in store.topicWorkUpdates() {
            try Task.checkCancellation()
            if revision != nil { try refresh() }
        }
    }

    @discardableResult
    public func refresh() throws -> Int {
        var after: Int64 = 0
        var applied = 0
        while true {
            try Task.checkCancellation()
            let batch = try store.prepareTopicUpdates(scoring: scoring, afterID: after)
            if let last = batch.last {
                applied += try store.applyTopicUpdates(batch)
                after = last.sessionID
            } else if after > 0 {
                // Visit any earlier sessions that changed during this pass,
                // without letting a busy session starve later documents.
                after = 0
            } else { return applied }
        }
    }
}
