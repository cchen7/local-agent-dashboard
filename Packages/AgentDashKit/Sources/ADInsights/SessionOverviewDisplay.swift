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

    public init(_ snapshot: IndexedSessionOverview, scorer: TopicScorer? = nil, maskSecrets: Bool = true) {
        summary = Self.excerpt(snapshot.summary, limit: 300, maskSecrets: maskSecrets)
        lastPrompt = Self.excerpt(snapshot.lastPrompt, limit: 200, maskSecrets: maskSecrets)
        lastReply = Self.excerpt(snapshot.lastReply, limit: 300, maskSecrets: maskSecrets)
        files = snapshot.files.map { Self.file($0, maskSecrets: maskSecrets) }
        commands = snapshot.commands.map { Self.command($0, maskSecrets: maskSecrets) }
        recentActions = snapshot.recentActions.map { action in
            switch action {
            case .file(let value): Self.file(value, maskSecrets: maskSecrets)
            case .command(let value): Self.command(value, maskSecrets: maskSecrets)
            case let .tool(kind, name, text, timestamp):
                Row(kind: .tool(kind), text: Self.excerpt(text, limit: 180, maskSecrets: maskSecrets),
                    detail: Self.excerpt(name, limit: 80, maskSecrets: maskSecrets),
                    timestamp: timestamp, count: nil, added: nil, removed: nil, exitCode: nil, durationMS: nil)
            }
        }

        // Catalog topics may have been produced by a different version.
        // Never show a token that isn't present in today's masked source sample.
        let topicFiles = maskSecrets ? files : snapshot.files.map { Self.file($0, maskSecrets: true) }
        let corpus = TopicDocument(
            userPrompts: [maskSecrets ? lastPrompt : Self.excerpt(snapshot.lastPrompt, limit: 200)].compactMap { $0 },
            assistantReplies: [maskSecrets ? summary : Self.excerpt(snapshot.summary, limit: 300),
                               maskSecrets ? lastReply : Self.excerpt(snapshot.lastReply, limit: 300)].compactMap { $0 },
            fileNames: topicFiles.compactMap { $0.text?.split(separator: "/").last.map(String.init) })
        let allowed = scorer?.counts(for: corpus) ?? [:]
        topics = Array(snapshot.topics.lazy.filter { allowed[$0] != nil }.prefix(5))
    }

    private static func file(_ item: IndexedOverviewFile, maskSecrets: Bool) -> Row {
        .init(kind: .file, text: excerpt(item.path, limit: 200, maskSecrets: maskSecrets), detail: excerpt(item.operation, limit: 32, maskSecrets: maskSecrets),
              timestamp: item.timestamp, count: item.count, added: item.added, removed: item.removed,
              exitCode: nil, durationMS: nil)
    }

    private static func command(_ item: IndexedOverviewCommand, maskSecrets: Bool) -> Row {
        .init(kind: .command, text: excerpt(item.text, limit: 180, maskSecrets: maskSecrets), detail: nil,
              timestamp: item.timestamp, count: nil, added: nil, removed: nil,
              exitCode: item.exitCode, durationMS: item.durationMS)
    }

    private static func excerpt(_ raw: String?, limit: Int, maskSecrets: Bool = true) -> String? {
        guard let raw else { return nil }
        let safe = (maskSecrets ? SecretMasker.mask(raw) : raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !safe.isEmpty else { return nil }
        return safe.count > limit ? String(safe.prefix(limit)) + "…" : safe
    }
}
