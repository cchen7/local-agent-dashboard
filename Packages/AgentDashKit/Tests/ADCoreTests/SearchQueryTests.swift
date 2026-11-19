import Testing
import ADCore

@Suite("FR-SR: pure query syntax (SPEC §9 / Appendix B)")
struct SearchQueryTests {
    private typealias Query = SearchQuery
    private typealias Term = Query.Term
    private typealias Clause = Query.Clause
    private typealias Filter = Query.Filter
    private typealias Field = Query.FilterField

    @Test("Every Appendix B example has an exact syntax tree")
    func appendixB() throws {
        let examples: [(String, Query)] = [
            ("登录 middleware", .init(groups: [.init(positive: [word("登录"), word("middleware")])])),
            (#""refresh token""#, .init(groups: [.init(positive: [phrase("refresh token")])])),
            ("auth -test", .init(groups: [.init(positive: [word("auth")], negative: [word("test")])])),
            ("redis OR memcached", .init(groups: [
                .init(positive: [word("redis")]), .init(positive: [word("memcached")])
            ])),
            ("agent:codex", .init(filters: [.init(field: .agent, value: "codex")])),
            ("project:payments", .init(filters: [.init(field: .project, value: "payments")])),
            ("dir:~/code/api", .init(filters: [.init(field: .dir, value: "~/code/api")])),
            ("env:work", .init(filters: [.init(field: .env, value: "work")])),
            ("status:waiting", .init(filters: [.init(field: .status, value: "waiting")])),
            ("role:user refactor", .init(groups: [.init(positive: [word("refactor")])],
                                        filters: [.init(field: .role, value: "user")])),
            ("tool:Bash docker", .init(groups: [.init(positive: [word("docker")])],
                                      filters: [.init(field: .tool, value: "Bash")])),
            ("file:auth.ts", .init(filters: [.init(field: .file, value: "auth.ts")])),
            ("model:opus", .init(filters: [.init(field: .model, value: "opus")])),
            ("after:2026-11-01", .init(filters: [.init(field: .after, value: "2026-11-01")])),
            ("in:7d", .init(filters: [.init(field: .recent, value: "7d")])),
            ("in:24h", .init(filters: [.init(field: .recent, value: "24h")]))
        ]
        for (raw, expected) in examples {
            #expect(try Query.parse(raw) == expected)
        }
    }

    @Test("All public filter fields use the specified raw names")
    func filterNames() throws {
        let fields: [Field] = [.agent, .project, .dir, .env, .status, .role, .tool,
                               .file, .model, .after, .before, .recent]
        #expect(fields.map(\.rawValue) == ["agent", "project", "dir", "env", "status", "role",
                                           "tool", "file", "model", "after", "before", "in"])
        #expect(Field(rawValue: "recent") == nil)
        #expect(try Query.parse("before:2026-11-15").filters == [
            Filter(field: .before, value: "2026-11-15")
        ])
    }

    @Test("Implicit AND binds inside OR groups and every filter remains global")
    func booleanPrecedence() throws {
        #expect(try Query.parse("agent:codex A B -C OR D -E F status:waiting OR G env:work") == Query(
            groups: [
                Clause(positive: [word("A"), word("B")], negative: [word("C")]),
                Clause(positive: [word("D"), word("F")], negative: [word("E")]),
                Clause(positive: [word("G")])
            ], filters: [
                Filter(field: .agent, value: "codex"), Filter(field: .status, value: "waiting"),
                Filter(field: .env, value: "work")
            ]))
        #expect(try Query.parse("A OR agent:codex B").groups == [
            Clause(positive: [word("A")]), Clause(positive: [word("B")])
        ])
    }

    @Test("Only an entire unquoted uppercase OR token is an operator")
    func literalOperators() throws {
        #expect(try Query.parse(#"or Or ORANGE -OR "OR" "agent:codex" AND NOT (literal) x|y"#) == Query(
            groups: [Clause(positive: [word("or"), word("Or"), word("ORANGE"), phrase("OR"),
                                      phrase("agent:codex"), word("AND"), word("NOT"),
                                      word("(literal)"), word("x|y")], negative: [word("OR")])]))
        #expect(try Query.parse("OR:literal tool:OR").groups == [Clause(positive: [word("OR:literal")])])
    }

    @Test("Negative-only queries are valid without OR")
    func negativeOnly() throws {
        #expect(try Query.parse(#"-test -"synthetic phrase" agent:codex"#) == Query(
            groups: [Clause(negative: [word("test"), phrase("synthetic phrase")])],
            filters: [Filter(field: .agent, value: "codex")]))
    }

    @Test("Empty and filter-only queries have no text groups", arguments: ["", " \t\n\r\u{3000}"])
    func emptyQueries(_ raw: String) throws {
        #expect(try Query.parse(raw) == Query())
        #expect(try Query.parse(raw + "agent:claude") == Query(filters: [Filter(field: .agent, value: "claude")]))
    }

    @Test("Quoted terms, exclusions and values preserve text and phrase boundaries")
    func quotedValues() throws {
        let raw = #""登录 OR refresh" -"test phrase" project:"synthetic project" dir:"~/code/demo folder" env:"test OR lab" tool:"Synthetic Tool" file:"a file.swift" model:"demo model" agent:"codex""#
        #expect(try Query.parse(raw) == Query(
            groups: [Clause(positive: [phrase("登录 OR refresh")], negative: [phrase("test phrase")])],
            filters: [
                Filter(field: .project, value: "synthetic project"), Filter(field: .dir, value: "~/code/demo folder"),
                Filter(field: .env, value: "test OR lab"), Filter(field: .tool, value: "Synthetic Tool"),
                Filter(field: .file, value: "a file.swift"), Filter(field: .model, value: "demo model"),
                Filter(field: .agent, value: "codex")
            ]))
        #expect(try Query.parse("\"  A\tB  \"").groups == [Clause(positive: [phrase("  A\tB  ")])])
    }

    @Test("Quotes and backslashes can be escaped inside quoted text; other backslashes stay literal")
    func quoteEscapes() throws {
        #expect(try Query.parse(#""say \"hello\" \\ path\q" dir:"C:\synthetic\folder" C:\synthetic\file"#) == Query(
            groups: [Clause(positive: [phrase(#"say "hello" \ path\q"#), word(#"C:\synthetic\file"#)])],
            filters: [Filter(field: .dir, value: #"C:\synthetic\folder"#)]))
    }

    @Test("Unknown and differently cased filter keys remain literal terms")
    func unknownFilters() throws {
        #expect(try Query.parse(#"owner:demo -future:value owner:"demo person" AGENT:codex https://example.invalid :value custom:"#) == Query(
            groups: [Clause(positive: [word("owner:demo"), word("owner:demo person"), word("AGENT:codex"),
                                      word("https://example.invalid"), word(":value"), word("custom:")],
                            negative: [word("future:value")])]))
    }

    @Test("Unicode whitespace separates tokens without normalization or path expansion")
    func unicodeAndPaths() throws {
        #expect(try Query.parse("登录\u{3000}Cafe\u{301}\u{a0}🧪\nOR\u{2003}verifyAndRotate\tfile:auth.ts dir:~/code/../demo") == Query(
            groups: [Clause(positive: [word("登录"), word("Cafe\u{301}"), word("🧪")]),
                     Clause(positive: [word("verifyAndRotate")])],
            filters: [Filter(field: .file, value: "auth.ts"), Filter(field: .dir, value: "~/code/../demo")]))
        #expect(try Query.parse("OR\u{301} -\u{301}text").groups == [
            Clause(positive: [word("OR\u{301}")], negative: [word("\u{301}text")])
        ])
    }

    @Test("Repeated filters are retained in input order without resolving their meaning")
    func repeatedFilters() throws {
        #expect(try Query.parse("agent:claude A agent:codex OR B agent:grok").filters == [
            Filter(field: .agent, value: "claude"), Filter(field: .agent, value: "codex"),
            Filter(field: .agent, value: "grok")
        ])
    }

    @Test("Agent, status and role accept exactly the SPEC vocabulary")
    func validEnumFilters() throws {
        let examples: [(Field, [String])] = [
            (.agent, ["claude", "codex", "copilot", "grok"]),
            (.status, ["running", "waiting", "completed", "failed"]),
            (.role, ["user", "assistant", "tool"])
        ]
        for (field, values) in examples {
            for value in values {
                #expect(try Query.parse("\(field.rawValue):\(value)").filters == [Filter(field: field, value: value)])
            }
        }
    }

    @Test("Invalid enum values are rejected", arguments: [
        "agent:other", "agent:Codex", "agent:claude_code", "agent:grok_build",
        "status:unknown", "status:done", "status:Running", "role:system", "role:User", "role:user|assistant|tool"
    ])
    func invalidEnumFilters(_ raw: String) {
        #expect(throws: Query.Failure.invalidFilterValue) { try Query.parse(raw) }
    }

    @Test("Dates validate Gregorian calendar days and retain local date strings", arguments: [
        "0001-01-01", "2000-02-29", "2024-02-29", "2026-11-01", "2400-02-29", "9999-12-31"
    ])
    func validDates(_ date: String) throws {
        for field: Field in [.after, .before] {
            #expect(try Query.parse("\(field.rawValue):\(date)").filters == [Filter(field: field, value: date)])
        }
        #expect(try Query.parse("after:\"\(date)\"").filters == [Filter(field: .after, value: date)])
    }

    @Test("Malformed or impossible dates fail", arguments: [
        "0000-01-01", "1900-02-29", "2100-02-29", "2026-02-29", "2026-04-31",
        "2026-00-01", "2026-13-01", "2026-01-00", "2026-01-32", "2026-1-01",
        "26-01-01", "10000-01-01", "2026/01/01", "２０２６-01-01", "2026-01-01T00:00:00Z"
    ])
    func invalidDates(_ date: String) {
        for field: Field in [.after, .before] {
            #expect(throws: Query.Failure.invalidDate) { try Query.parse("\(field.rawValue):\(date)") }
        }
    }

    @Test("Recent windows are positive ASCII hours or days with checked millisecond bounds", arguments: [
        "1h", "24h", "7d", "01d", "106751991167d", "2562047788015h"
    ])
    func validWindows(_ value: String) throws {
        #expect(try Query.parse("in:\(value)").filters == [Filter(field: .recent, value: value)])
        #expect(try Query.parse("in:\"\(value)\"").filters == [Filter(field: .recent, value: value)])
    }

    @Test("Invalid or overflowing windows fail", arguments: [
        "0d", "00h", "-1d", "+1h", "1.5d", "1w", "24H", "d", "1", "１d", "1dd",
        "106751991168d", "2562047788016h", "9223372036854775808h", "999999999999999999999999999d"
    ])
    func invalidWindows(_ value: String) {
        #expect(throws: Query.Failure.invalidWindow) { try Query.parse("in:\(value)") }
    }

    @Test("Every OR group requires positive text, including groups with global filters", arguments: [
        "OR", "OR A", "A OR", "A OR OR B", "-test OR B", "A OR -test",
        "agent:codex OR B", "A OR agent:codex", "A OR agent:codex -test OR B"
    ])
    func invalidORGroups(_ raw: String) {
        #expect(throws: Query.Failure.invalidORGroup) { try Query.parse(raw) }
    }

    @Test("Unterminated quotes fail", arguments: [#""synthetic"#, #"-"synthetic"#, #"env:"synthetic"#, #""synthetic\""#])
    func unterminatedQuotes(_ raw: String) {
        #expect(throws: Query.Failure.unterminatedQuote) { try Query.parse(raw) }
    }

    @Test("Empty phrases and missing known-filter values fail", arguments: [
        #""""#, #"-"""#, #""   ""#, "agent:", "agent: codex", #"env:"""#, #"dir:"   ""#,
        "project:", "status:", "role:", "tool:", "file:", "model:", "after:", "before:", "in:"
    ])
    func emptyValues(_ raw: String) {
        #expect(throws: Query.Failure.emptyValue) { try Query.parse(raw) }
    }

    @Test("Quotes must enclose a complete term or filter value", arguments: [
        #"pre"suffix""#, #""quoted"suffix"#, #"env:"quoted"suffix"#, #"env:pre"suffix""#
    ])
    func invalidSyntax(_ raw: String) {
        #expect(throws: Query.Failure.invalidSyntax) { try Query.parse(raw) }
    }

    @Test("Bare exclusion and negated filters cannot be represented", arguments: ["-", "- test", "-agent:codex", #"-env:"test lab""#])
    func invalidExclusions(_ raw: String) {
        #expect(throws: Query.Failure.invalidExclusion) { try Query.parse(raw) }
    }

    @Test("Non-whitespace control characters fail even in quoted text", arguments: ["a\0b", "\u{1b}", "\u{7f}", "\"a\0b\"", "env:a\u{80}"])
    func invalidCharacters(_ raw: String) {
        #expect(throws: Query.Failure.invalidCharacter) { try Query.parse(raw) }
    }

    @Test("UTF-8 byte limit includes whitespace, multibyte and combining scalars")
    func byteBounds() throws {
        #expect(Query.maximumUTF8Bytes == 16_384)
        for text in [String(repeating: "a", count: 16_384), String(repeating: "🧪", count: 4_096),
                     String(repeating: "\u{301}", count: 8_192)] {
            #expect(try Query.parse(text).groups == [Clause(positive: [word(text)])])
            #expect(throws: Query.Failure.inputTooLong) { try Query.parse(text + "a") }
        }
        #expect(try Query.parse(String(repeating: " ", count: 16_384)) == Query())
        let quoted = String(repeating: "a", count: 16_382)
        #expect(try Query.parse("\"" + quoted + "\"").groups == [Clause(positive: [phrase(quoted)])])
        #expect(throws: Query.Failure.inputTooLong) { try Query.parse("\"" + quoted + "a\"") }
        #expect(throws: Query.Failure.inputTooLong) { try Query.parse(String(repeating: " ", count: 16_385)) }
        #expect(throws: Query.Failure.inputTooLong) { try Query.parse("\"" + String(repeating: "a", count: 16_384)) }
    }

    @Test("Token limit counts terms, filters and OR operators")
    func tokenBounds() throws {
        #expect(Query.maximumTokens == 256)
        let terms = Array(repeating: "a", count: 256).joined(separator: " ")
        #expect(try Query.parse(terms).groups.first?.positive.count == 256)
        #expect(throws: Query.Failure.tooManyTokens) { try Query.parse(terms + " a") }
        let filters = Array(repeating: "env:test", count: 256).joined(separator: " ")
        #expect(try Query.parse(filters).filters.count == 256)
        #expect(throws: Query.Failure.tooManyTokens) { try Query.parse(filters + " env:test") }
        let groups = Array(repeating: "a", count: 128).joined(separator: " OR ") + " env:test"
        #expect(try Query.parse(groups).groups.count == 128)
        #expect(throws: Query.Failure.tooManyTokens) { try Query.parse(groups + " env:test") }
    }

    @Test("Errors contain categories only, without query text or associated data")
    func categoryOnlyErrors() {
        for raw in ["agent:synthetic-marker", "after:synthetic-marker", "in:synthetic-marker", #""synthetic-marker"#] {
            do {
                _ = try Query.parse(raw)
                Issue.record("Expected invalid synthetic query to fail")
            } catch {
                #expect(error is Query.Failure)
                #expect(!String(describing: error).contains("synthetic-marker"))
                #expect(!String(reflecting: error).contains("synthetic-marker"))
                #expect(Mirror(reflecting: error).children.isEmpty)
            }
        }
    }

    @Test("Public values are Equatable/Sendable and parsing has no shared mutable state")
    func concurrentParsing() async throws {
        func sendable<T: Equatable & Sendable>(_ value: T) -> T { value }
        let expected = Query(groups: [Clause(positive: [word("登录")], negative: [phrase("test phrase")])],
                             filters: [Filter(field: .agent, value: "codex")])
        #expect(sendable(expected) == expected)
        #expect(sendable(word("word")) == word("word"))
        #expect(sendable(Clause()) == Clause())
        #expect(sendable(Filter(field: .recent, value: "7d")) == Filter(field: .recent, value: "7d"))
        #expect(sendable(Field.recent) == .recent)
        #expect(sendable(Query.Failure.invalidDate) == .invalidDate)
        try await withThrowingTaskGroup(of: Query.self) { tasks in
            for _ in 0..<32 {
                tasks.addTask { try Query.parse(#"登录 -"test phrase" agent:codex"#) }
            }
            for try await actual in tasks { #expect(actual == expected) }
        }
    }

    private func word(_ text: String) -> Term { Term(text: text, isPhrase: false) }
    private func phrase(_ text: String) -> Term { Term(text: text, isPhrase: true) }
}
