import ADCore
import ADPrivacy
import ADStore
import Foundation

/// Display-safe text with highlighting attached to the masked value.
public struct SearchSnippetPart: Equatable, Sendable {
    public let text: String
    public let highlighted: Bool
}

public struct SessionSearchHit: Identifiable, Equatable, Sendable {
    public let id: SessionKey
    public let firstMatchKey: String
    public let matchCount: Int
    public let snippet: [SearchSnippetPart]
}

public struct SessionSearchResults: Equatable, Sendable {
    public let hits: [SessionSearchHit]
    public let matchCount: Int
    public let sessionCount: Int
}

public enum SessionSearch {
    /// Search the raw index; mask complete display text before cutting or highlighting it.
    public static func run(_ raw: String, in store: AgentStore, scope: IndexedSearchScope,
                           order: SessionSearchOrder = .relevance, limit: Int = 50, offset: Int = 0,
                           maskSecrets: Bool = true) throws -> SessionSearchResults {
        let query = try SearchQuery.parse(raw)
        let snapshot = try store.searchIndex(query, scope: scope, order: order, limit: limit, offset: offset)
        let terms = query.groups.flatMap(\.positive).map(\.text)
        let hits = try snapshot.groups.map { group in
            try Task.checkCancellation()
            let rawBody = group.bestText ?? ""
            let rawTool = group.bestTool ?? ""
            let body = maskSecrets ? SecretMasker.mask(rawBody) : rawBody
            let tool = maskSecrets ? SecretMasker.mask(rawTool) : rawTool
            let text = containsAny(body, terms: terms) || tool.isEmpty ? body :
                ([tool, body].filter { !$0.isEmpty }.joined(separator: " · "))
            return SessionSearchHit(id: group.session, firstMatchKey: group.firstMatchKey,
                                    matchCount: group.matchCount, snippet: snippet(text, terms: terms))
        }
        return .init(hits: hits, matchCount: snapshot.matchCount, sessionCount: snapshot.sessionCount)
    }

    /// Match navigation uses the same parsed filters and search scope as the list.
    public static func position(_ raw: String, in store: AgentStore, scope: IndexedSearchScope,
                                session: SessionKey, around preferred: String? = nil) throws -> IndexedSearchMatchPosition? {
        try store.searchMatchPosition(SearchQuery.parse(raw), scope: scope, in: session, around: preferred)
    }

    private static let comparison: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    private static func containsAny(_ text: String, terms: [String]) -> Bool {
        terms.contains { text.range(of: $0, options: comparison) != nil }
    }

    private static func snippet(_ masked: String, terms: [String]) -> [SearchSnippetPart] {
        guard !masked.isEmpty else { return [] }
        let first = terms.compactMap { masked.range(of: $0, options: comparison)?.lowerBound }.min()
        let start = first.flatMap { masked.index($0, offsetBy: -44, limitedBy: masked.startIndex) } ?? masked.startIndex
        let end = masked.index(start, offsetBy: 180, limitedBy: masked.endIndex) ?? masked.endIndex
        let window = String(masked[start..<end])
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var from = window.startIndex
            while from < window.endIndex,
                  let range = window.range(of: term, options: comparison, range: from..<window.endIndex),
                  !range.isEmpty {
                ranges.append(range)
                from = range.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for range in ranges {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        var output: [SearchSnippetPart] = []
        if start != masked.startIndex { output.append(.init(text: "…", highlighted: false)) }
        var cursor = window.startIndex
        for range in merged {
            if cursor < range.lowerBound {
                output.append(.init(text: String(window[cursor..<range.lowerBound]), highlighted: false))
            }
            output.append(.init(text: String(window[range]), highlighted: true))
            cursor = range.upperBound
        }
        if cursor < window.endIndex {
            output.append(.init(text: String(window[cursor...]), highlighted: false))
        }
        if end != masked.endIndex { output.append(.init(text: "…", highlighted: false)) }
        return output
    }
}
