import ADCore
import Testing

@Test("FR-SR: filter tokens retain query spelling, quoted phrases, exclusions, OR and duplicates")
func presentingFiltersKeepsTheSavedQuery() throws {
    let original = #" 登录 agent:codex "status:running" OR 核对 -草稿 env:"工作 空间" status:waiting status:waiting "#
    let shown = SearchFieldQuery(query: original)
    #expect(shown.query.utf8.elementsEqual(original.utf8))
    #expect(shown.tokens.map(\.spelling) == ["agent:codex", #"env:"工作 空间""#, "status:waiting", "status:waiting"])
    let text = try SearchQuery.parse(shown.text)
    let full = try SearchQuery.parse(original)
    #expect(text.groups == full.groups && text.filters.isEmpty)
    #expect(text.groups.count == 2)
    #expect(Set(shown.tokens.map(\.id)).count == 4)
    let removed = shown.editingTokens(shown.tokens.filter { $0.id != 2 })
    #expect(try SearchQuery.parse(removed.query) == SearchQuery(groups: full.groups, filters: Array(full.filters.dropLast())))
    #expect(removed.tokens.map(\.id) == [0, 1, 3])
}

@Test("FR-SR: typing is preserved until explicit promotion and unfinished queries cannot lose pieces")
func stagedAndInvalidTextStaysEditable() throws {
    let original = SearchFieldQuery(query: "agent:codex")
    let partial = original.editingText(#"登录 dir:"/synthetic/path with"#)
    #expect(partial.text == #"登录 dir:"/synthetic/path with"#)
    #expect(partial.committingFilters() == partial)
    #expect(throws: SearchQuery.Failure.unterminatedQuote) { try SearchQuery.parse(partial.query) }

    let draft = original.editingText(#"登录 dir:"/synthetic/path with spaces" -样例"#)
    #expect(draft.tokens.count == 1)
    let committed = draft.committingFilters()
    #expect(committed.query.utf8.elementsEqual(draft.query.utf8))
    #expect(committed.tokens.first == original.tokens.first)
    #expect(committed.tokens.last?.spelling == #"dir:"/synthetic/path with spaces""#)
    #expect(try SearchQuery.parse(committed.text).groups == SearchQuery.parse(draft.query).groups)
    #expect(committed.committingFilters() == committed)
}

@Test("FR-SR: quoted and unknown filter-like spellings remain literal and filter-only searches can clear")
func onlyGrammarFiltersBecomeNativeTokens() {
    let terms = #"branch:"feature branch" "agent:codex" -statuss:waiting"#
    let mixed = SearchFieldQuery(query: terms)
    #expect(mixed.text == terms && mixed.tokens.isEmpty)
    let invalid = "agent:codex OR"
    let shown = SearchFieldQuery(query: invalid)
    #expect(shown.text == invalid && shown.tokens.isEmpty)
    let filters = SearchFieldQuery(query: #"in:7d model:"a\"b""#)
    #expect(filters.text == "" && filters.tokens.count == 2)
    #expect(filters.editingTokens([]).query.isEmpty)
}

@Test("FR-SR: canonically equivalent input is still an edit when its stored bytes change")
func searchPresentationDoesNotNormalizeUnicode() {
    let initial = SearchFieldQuery(query: "agent:codex café")
    let edited = initial.editingText("cafe\u{0301}")
    #expect(edited != initial)
    #expect(edited.query.utf8.elementsEqual("agent:codex cafe\u{0301}".utf8))
}
