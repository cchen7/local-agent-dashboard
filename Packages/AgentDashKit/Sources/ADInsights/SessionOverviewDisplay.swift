import ADCore
import ADPrivacy
import ADStore
import Foundation

/// Display-safe excerpts. A complete raw field is masked before trimming,
/// clipping or using it to validate a topic chip.
public struct SessionOverviewDisplay: Equatable, Sendable {
    public struct Row: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case file, command, tool(EventKind) }

        public let kind: Kind
        public let text: String?
        public let detail: String?
        public let timestamp: Int64
        public let count: Int64?
        public let added: Int64?
        public let removed: Int64?
        public let exitCode: Int64?
        public let durationMS: Int64?
    }

    public let summary: String?
    public let lastPrompt: String?
    public let lastReply: String?
    public let topics: [String]
    public let recentActions: [Row]
    public let files: [Row]
    public let commands: [Row]
    public var isEmpty: Bool {
        summary == nil && lastPrompt == nil && lastReply == nil &&
            topics.isEmpty && recentActions.isEmpty && files.isEmpty && commands.isEmpty
    }

    public init(_ snapshot: IndexedSessionOverview, scorer: TopicScorer? = nil) {
        summary = Self.excerpt(snapshot.summary, limit: 300)
        lastPrompt = Self.excerpt(snapshot.lastPrompt, limit: 200)
        lastReply = Self.excerpt(snapshot.lastReply, limit: 300)
        files = snapshot.files.map(Self.file)
        commands = snapshot.commands.map(Self.command)
        recentActions = snapshot.recentActions.map { action in
            switch action {
            case .file(let value): Self.file(value)
            case .command(let value): Self.command(value)
            case let .tool(kind, name, text, timestamp):
                Row(kind: .tool(kind), text: Self.excerpt(text, limit: 180), detail: Self.excerpt(name, limit: 80),
                    timestamp: timestamp, count: nil, added: nil, removed: nil, exitCode: nil, durationMS: nil)
            }
        }

        // Catalog topics may have been produced by a different version.
        // Never show a token that isn't present in today's masked source sample.
        let corpus = TopicDocument(userPrompts: [lastPrompt].compactMap { $0 },
            assistantReplies: [summary, lastReply].compactMap { $0 },
            fileNames: files.compactMap { $0.text?.split(separator: "/").last.map(String.init) })
        let allowed = scorer?.counts(for: corpus) ?? [:]
        topics = Array(snapshot.topics.lazy.filter { allowed[$0] != nil }.prefix(5))
    }

    private static func file(_ item: IndexedOverviewFile) -> Row {
        .init(kind: .file, text: excerpt(item.path, limit: 200), detail: excerpt(item.operation, limit: 32),
              timestamp: item.timestamp, count: item.count, added: item.added, removed: item.removed,
              exitCode: nil, durationMS: nil)
    }

    private static func command(_ item: IndexedOverviewCommand) -> Row {
        .init(kind: .command, text: excerpt(item.text, limit: 180), detail: nil,
              timestamp: item.timestamp, count: nil, added: nil, removed: nil,
              exitCode: item.exitCode, durationMS: item.durationMS)
    }

    private static func excerpt(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let safe = SecretMasker.mask(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return nil }
        return safe.count > limit ? String(safe.prefix(limit)) + "…" : safe
    }
}
