import Foundation
import Testing
import ADInsights

@Test("SPEC 10.2: repeated occurrences use prompt/reply/file weights 2/1/1.5")
func weightedTopicCounts() throws {
    let scorer = try TopicScorer()
    let document = TopicDocument(userPrompts: ["cache cache", "index"],
                                 assistantReplies: ["cache index index"], fileNames: ["cache", "index"])
    #expect(scorer.counts(for: document) == ["cache": 6.5, "index": 5.5])
}

@Test("SPEC 9.2/10.2: shared identifier aliases, case folding and accents")
func topicIdentifierAliases() throws {
    let scorer = try TopicScorer()
    let document = TopicDocument(
        userPrompts: ["verifyAndRotate verify_and_rotate verify-and-rotate parseHTTPResponse Café cache_cache"],
        assistantReplies: [], fileNames: [])
    #expect(scorer.counts(for: document) == [
        "verifyandrotate": 2, "verify_and_rotate": 2, "verify-and-rotate": 2,
        "verify": 6, "rotate": 6, "parsehttpresponse": 2, "parse": 2,
        "http": 2, "response": 2, "cafe": 2, "cache_cache": 2, "cache": 2
    ])
}

@Test("SPEC 9.2/10.2: punctuation and paths bound words, filenames stay intact")
func topicWordBoundaries() throws {
    let scorer = try TopicScorer()
    let document = TopicDocument(userPrompts: ["(cache),[login];'auth'!\ncache. ui.ts 🚀 /delta/gamma.json 123 12"],
                                 assistantReplies: [], fileNames: [])
    #expect(scorer.counts(for: document) == [
        "cache": 4, "login": 2, "auth": 2, "ui.ts": 2,
        "delta": 2, "gamma.json": 2, "gamma": 2, "json": 2
    ])
}

@Test("SPEC 9.2/10.2: Chinese overlapping bigrams, mixed words and emoji", arguments: [
    ("登录", ["登录": 2.0]),
    ("修复登录问题", ["修复": 2, "复登": 2, "登录": 2, "录问": 2, "问题": 2]),
    ("缓存缓存", ["缓存": 4, "存缓": 2]),
    ("修复Login问题", ["修复": 2, "login": 2, "问题": 2]),
    ("登录😀成功🚀canvas", ["登录": 2, "成功": 2, "canvas": 2]),
    ("𠀀𠀁𠀂", ["𠀀𠀁": 2, "𠀁𠀂": 2]),
    ("中 😀🚀", [:])
])
func chineseTopicBigrams(_ text: String, _ expected: [String: Double]) throws {
    let scorer = try TopicScorer()
    #expect(scorer.counts(for: .init(userPrompts: [text], assistantReplies: [], fileNames: [])) == expected)
}

@Test("SPEC 10.2: bilingual conversational and programming stop resources are applied")
func topicStopWords() throws {
    let scorer = try TopicScorer()
    let document = TopicDocument(
        userPrompts: ["The AND please function public return nil false 我们 这个 一下 可以 需要 然后"],
        assistantReplies: ["这些 那些 已经 如果 但是 怎么 帮我 能够"],
        fileNames: ["class", "const", "let", "var", "void", "string"])
    #expect(scorer.counts(for: document).isEmpty)
    #expect(scorer.counts(for: .init(userPrompts: ["cache authentication parser 登录 缓存 修复 问题"],
                                    assistantReplies: [], fileNames: [])) == [
        "cache": 2, "authentication": 2, "parser": 2, "登录": 2, "缓存": 2, "修复": 2, "问题": 2
    ])
}

@Test("SPEC 10.2: empty, short and separate inputs never create joined tokens")
func topicEmptyAndSeparateInputs() throws {
    let scorer = try TopicScorer()
    #expect(scorer.counts(for: .init(userPrompts: [], assistantReplies: [], fileNames: [])).isEmpty)
    #expect(scorer.counts(for: .init(userPrompts: ["", "修", "复", "a ab", "--- ___ ..."],
                                    assistantReplies: ["😀"], fileNames: [])).isEmpty)
    #expect(scorer.counts(for: .init(userPrompts: ["auth", "cache"], assistantReplies: [], fileNames: []))
            == ["auth": 2, "cache": 2])
}

@Test("SPEC 10.2: exact natural-log TF-IDF, absent df is zero, negative scores survive")
func exactTopicScores() throws {
    let scorer = try TopicScorer()
    let topics = scorer.top(["cache": 6.5, "login": 2, "ubiquitous": 1.5, "novel": 3],
                            documentCount: 8, documentFrequency: ["cache": 1, "login": 3, "ubiquitous": 8])
    let scores = Dictionary(uniqueKeysWithValues: topics.map { ($0.term, $0.score) })
    #expect(scores["cache"] == log(1 + 6.5) * log(8.0 / (1 + 1)))
    #expect(scores["login"] == log(1 + 2.0) * log(8.0 / (1 + 3)))
    #expect(scores["ubiquitous"] == log(1 + 1.5) * log(8.0 / (1 + 8)))
    #expect(scores["novel"] == log(1 + 3.0) * log(8.0 / (1 + 0)))
    #expect(topics.map(\.term) == ["novel", "cache", "login", "ubiquitous"])
}

@Test("SPEC 10.2: one-session corpora keep zero and negative IDF without smoothing")
func oneDocumentTopicScores() throws {
    let scorer = try TopicScorer()
    let topics = scorer.top(["cache": 2, "login": 2], documentCount: 1, documentFrequency: ["login": 1])
    #expect(topics == [WeightedTopic(term: "cache", score: 0),
                       WeightedTopic(term: "login", score: log(3) * log(0.5))])
}

@Test("SPEC 10.2: skip substrings of selected terms, then fill the requested limit")
func topicSubstringSelection() throws {
    let scorer = try TopicScorer()
    let counts = ["cachemanager": 10.0, "cache": 9, "manager": 8, "login": 7,
                  "rotate": 6, "repair": 5, "verify": 4, "zebra": 3]
    #expect(scorer.top(counts, documentCount: 10, documentFrequency: [:]).map(\.term)
            == ["cachemanager", "login", "rotate", "repair", "verify"])
    #expect(scorer.top(counts, documentCount: 10, documentFrequency: [:], limit: 2).map(\.term)
            == ["cachemanager", "login"])
    #expect(scorer.top(["auth": 4, "authentication": 3], documentCount: 10,
                       documentFrequency: [:]).map(\.term) == ["auth", "authentication"])
}

@Test("SPEC 10.2: ties use ascending terms regardless of dictionary insertion order")
func stableTopicTies() throws {
    let scorer = try TopicScorer()
    let terms = ["zebra", "登录", "echo", "delta", "charlie", "bravo", "alpha"]
    for offset in terms.indices {
        let ordered = Array(terms[offset...]) + Array(terms[..<offset])
        let counts = Dictionary(uniqueKeysWithValues: ordered.map { ($0, 2.0) })
        #expect(scorer.top(counts, documentCount: 10, documentFrequency: [:]).map(\.term)
                == ["alpha", "bravo", "charlie", "delta", "echo"])
        #expect(scorer.top(counts, documentCount: 10, documentFrequency: [:], limit: 20).map(\.term)
                == ["alpha", "bravo", "charlie", "delta", "echo", "zebra", "登录"])
    }
}

@Test("SPEC 10.2: invalid metadata and nonfinite counts cannot poison ranking")
func invalidTopicInputs() throws {
    let scorer = try TopicScorer()
    for documentCount in [0, -1] {
        #expect(scorer.top(["cache": 2], documentCount: documentCount, documentFrequency: [:]).isEmpty)
    }
    for limit in [0, -1] {
        #expect(scorer.top(["cache": 2], documentCount: 10, documentFrequency: [:], limit: limit).isEmpty)
    }
    #expect(scorer.top([:], documentCount: 10, documentFrequency: [:]).isEmpty)
    let counts = ["": 2.0, "zero": 0, "negative": -1, "nan": Double.nan,
                  "infinite": .infinity, "negativeinfinite": -.infinity,
                  "badfrequency": 2, "toofrequent": 2, "cache": 2]
    #expect(scorer.top(counts, documentCount: 10,
                       documentFrequency: ["badfrequency": -1, "toofrequent": 11]).map(\.term) == ["cache"])
    let boundary = scorer.top(["cache": .greatestFiniteMagnitude], documentCount: Int.max,
                              documentFrequency: ["cache": Int.max])
    #expect(boundary.count == 1)
    #expect(boundary.allSatisfy { $0.score.isFinite })
}

@Test("SPEC 10.2: a bounded synthetic corpus produces repeatable weighted counts and topics")
func boundedSyntheticTopicCorpus() throws {
    let scorer = try TopicScorer()
    let text = String(repeating: "cache 登录 verifyAndRotate 😀 ", count: 256)
    let document = TopicDocument(userPrompts: [text], assistantReplies: ["cache"], fileNames: ["cache"])
    let counts = scorer.counts(for: document)
    #expect(counts == ["cache": 514.5, "登录": 512, "verifyandrotate": 512, "verify": 512, "rotate": 512])
    let expected = [WeightedTopic(term: "cache", score: log(515.5) * log(5)),
                    WeightedTopic(term: "rotate", score: log(513) * log(5)),
                    WeightedTopic(term: "verify", score: log(513) * log(5)),
                    WeightedTopic(term: "verifyandrotate", score: log(513) * log(5)),
                    WeightedTopic(term: "登录", score: log(513) * log(5))]
    for _ in 0..<3 {
        #expect(scorer.counts(for: document) == counts)
        #expect(scorer.top(counts, documentCount: 5, documentFrequency: [:]) == expected)
    }
}
