import Foundation
import ADCore

/// Caller-supplied session text for SPEC §10.2. File names are text, never opened.
public struct TopicDocument: Equatable, Sendable {
    public let userPrompts: [String]
    public let assistantReplies: [String]
    public let fileNames: [String]

    /// Keep message boundaries and roles separate when collecting a session's corpus.
    public init(userPrompts: [String], assistantReplies: [String], fileNames: [String]) {
        self.userPrompts = userPrompts
        self.assistantReplies = assistantReplies
        self.fileNames = fileNames
    }
}

/// A normalized topic term and its unmodified SPEC §10.2 TF-IDF score.
public struct WeightedTopic: Equatable, Sendable {
    public let term: String
    public let score: Double

    /// Scores may be zero or negative for terms common throughout a small corpus.
    public init(term: String, score: Double) {
        self.term = term
        self.score = score
    }
}

/// Deterministic, store-independent topic extraction using only bundled stop words.
public struct TopicScorer: Sendable {
    private let stopWords: Set<String>

    /// Load the curated English/programming and Chinese-bigram resource lists.
    /// Throws if a bundled resource is missing or cannot be read as UTF-8.
    public init() throws {
        stopWords = try Self.loadStopWords("stopwords-en").union(Self.loadStopWords("stopwords-zh"))
    }

    /// Weighted occurrences: prompts 2, assistant replies 1, touched file names 1.5.
    /// Each distinct alias is counted once per occurrence; Chinese singles and
    /// non-CJK terms shorter than three characters (or without letters) are omitted.
    public func counts(for document: TopicDocument) -> [String: Double] {
        var counts: [String: Double] = [:]
        for (texts, weight) in [(document.userPrompts, 2.0), (document.assistantReplies, 1.0),
                                (document.fileNames, 1.5)] {
            for text in texts {
                // Match the shared splitter's word contract without SQLite or unsafe pointers.
                let words = text.unicodeScalars.split { scalar in
                    !CharacterSet.alphanumerics.contains(scalar)
                        && !CharacterSet.nonBaseCharacters.contains(scalar)
                        && !"_-.".unicodeScalars.contains(scalar)
                }
                for word in words {
                    // Strip prose/Markdown punctuation, retaining internal identifier separators.
                    let identifier = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "_-."))
                    for group in SearchTokenization.groups(in: identifier) {
                        for term in group.terms where Self.isTopic(term) && !stopWords.contains(term) {
                            counts[term, default: 0] += weight
                        }
                    }
                }
            }
        }
        return counts
    }

    /// Rank by exactly ln(1 + count) * ln(N / (1 + df)), then ascending term.
    /// Missing df is zero. Nonpositive N/limit produces no topics; empty terms,
    /// nonpositive/nonfinite counts and df outside 0...N are ignored.
    /// Keep zero/negative scores, skipping substrings of already selected terms.
    public func top(_ counts: [String: Double], documentCount: Int,
                    documentFrequency: [String: Int], limit: Int = 5) -> [WeightedTopic] {
        guard documentCount > 0, limit > 0 else { return [] }
        let ranked = counts.compactMap { term, count -> WeightedTopic? in
            let frequency = documentFrequency[term, default: 0]
            guard !term.isEmpty, count.isFinite, count > 0,
                  frequency >= 0, frequency <= documentCount else { return nil }
            let score = log(1 + count) * log(Double(documentCount) / (1 + Double(frequency)))
            return WeightedTopic(term: term, score: score)
        }.sorted { lhs, rhs in
            lhs.score == rhs.score ? lhs.term < rhs.term : lhs.score > rhs.score
        }
        var selected: [WeightedTopic] = []
        for candidate in ranked {
            guard !selected.contains(where: { $0.term.contains(candidate.term) }) else { continue }
            selected.append(candidate)
            if selected.count == limit { break }
        }
        return selected
    }

    private static func isTopic(_ term: String) -> Bool {
        let scalars = term.unicodeScalars
        if scalars.allSatisfy(isCJK) { return scalars.count == 2 }
        return term.count >= 3 && scalars.contains(where: CharacterSet.letters.contains)
    }

    // Same CJK ranges as ADCore.SearchTokenization; only bigrams are topics (§10.2).
    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF,
             0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF: true
        default: false
        }
    }

    private static func loadStopWords(_ name: String) throws -> Set<String> {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt") else {
            throw StopWordError.missingResource(name)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let word = line.trimmingCharacters(in: .whitespaces)
            return word.isEmpty || word.hasPrefix("#") ? nil : word
        })
    }

    private enum StopWordError: Error {
        case missingResource(String)
    }
}
