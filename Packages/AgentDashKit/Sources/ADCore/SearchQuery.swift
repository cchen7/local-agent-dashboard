import Foundation

/// FR-SR: a pure, bounded syntax tree for SPEC §9 / Appendix B.
/// Groups are OR alternatives; positive and negative terms within a group are
/// AND constraints. Filters apply globally, in input order (including repeats).
/// Empty/filter-only queries have no groups. A negative-only query has one group;
/// when OR is present, every group must contain at least one positive term.
public struct SearchQuery: Equatable, Sendable {
    /// Treat a displayed term as literal input, even if it includes query syntax.
    public static func quotedLiteral(_ term: String) -> String {
        let quoted = term.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(quoted)\""
    }

    public struct Term: Equatable, Sendable {
        public let text: String
        public let isPhrase: Bool

        public init(text: String, isPhrase: Bool) {
            self.text = text
            self.isPhrase = isPhrase
        }
    }

    public struct Clause: Equatable, Sendable {
        public let positive: [Term]
        public let negative: [Term]

        public init(positive: [Term] = [], negative: [Term] = []) {
            self.positive = positive
            self.negative = negative
        }
    }

    public enum FilterField: String, Equatable, Sendable {
        case agent, project, dir, env, status, role, tool, file, model, after, before
        case recent = "in"
    }

    public struct Filter: Equatable, Sendable {
        public let field: FilterField
        public let value: String

        public init(field: FilterField, value: String) {
            self.field = field
            self.value = value
        }
    }

    /// Categories only: no query text, paths, positions or underlying errors.
    public enum Failure: Error, Equatable, Sendable {
        case inputTooLong, tooManyTokens, invalidCharacter, unterminatedQuote
        case invalidSyntax, emptyValue, invalidExclusion, invalidORGroup
        case invalidFilterValue, invalidDate, invalidWindow
    }

    public static let maximumUTF8Bytes = 16_384
    /// Includes terms, filters and OR operators; also bounds the number of groups.
    public static let maximumTokens = 256

    public let groups: [Clause]
    public let filters: [Filter]

    public init(groups: [Clause] = [], filters: [Filter] = []) {
        self.groups = groups
        self.filters = filters
    }

    /// Parse without I/O, clock access, normalization, path expansion or date conversion.
    /// Keys and enumerated values are case-sensitive. Only a whole, unquoted `OR`
    /// is an operator. Double quotes must enclose a whole term or filter value;
    /// inside them, `\"` and `\\` are decoded and other backslashes stay literal.
    /// Unknown keys stay literal terms (with any quoted value decoded). `-` excludes
    /// a term/phrase; negated known filters are rejected because Filter has no polarity.
    /// Dates are Gregorian YYYY-MM-DD (years 0001–9999), retained as local dates.
    /// Recent windows are positive ASCII integers plus `h` or `d`, bounded to Int64
    /// milliseconds. Temporal filters are validated independently, without a clock.
    public static func parse(_ raw: String) throws -> SearchQuery {
        var lexer = try QueryLexer(raw)
        var groups: [Clause] = []
        var filters: [Filter] = []
        var positive: [Term] = []
        var negative: [Term] = []
        var hasOR = false

        while let token = try lexer.next() {
            switch token {
            case .term(let term, let excluded):
                if excluded { negative.append(term) } else { positive.append(term) }
            case .filter(let filter):
                filters.append(filter)
            case .or:
                guard !positive.isEmpty else { throw Failure.invalidORGroup }
                groups.append(Clause(positive: positive, negative: negative))
                positive = []
                negative = []
                hasOR = true
            }
        }
        if hasOR && positive.isEmpty { throw Failure.invalidORGroup }
        if !positive.isEmpty || !negative.isEmpty {
            groups.append(Clause(positive: positive, negative: negative))
        }
        return SearchQuery(groups: groups, filters: filters)
    }
}

/// Scalar scanning keeps ASCII syntax visible even beside combining marks.
/// No recursion or unbounded intermediate token array is needed.
private struct QueryLexer {
    private typealias Failure = SearchQuery.Failure
    private typealias Field = SearchQuery.FilterField

    enum Token {
        case term(SearchQuery.Term, excluded: Bool)
        case filter(SearchQuery.Filter)
        case or
    }

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var tokenCount = 0

    init(_ raw: String) throws {
        // Stop counting after the first disallowed byte, before copying scalars.
        guard raw.utf8.prefix(SearchQuery.maximumUTF8Bytes + 1).count <= SearchQuery.maximumUTF8Bytes else {
            throw Failure.inputTooLong
        }
        scalars = Array(raw.unicodeScalars)
        guard !scalars.contains(where: { $0.properties.generalCategory == .control && !$0.properties.isWhitespace }) else {
            throw Failure.invalidCharacter
        }
    }

    mutating func next() throws -> Token? {
        while index < scalars.count && scalars[index].properties.isWhitespace { index += 1 }
        guard index < scalars.count else { return nil }
        tokenCount += 1
        guard tokenCount <= SearchQuery.maximumTokens else { throw Failure.tooManyTokens }

        let excluded = scalars[index] == "-"
        if excluded { index += 1 }
        guard !atBoundary else { throw Failure.invalidExclusion }

        if scalars[index] == "\"" {
            return .term(.init(text: try quoted(), isPhrase: true), excluded: excluded)
        }

        let start = index
        while !atBoundary && scalars[index] != ":" && scalars[index] != "\"" { index += 1 }
        let prefix = text(start, index)
        if !atBoundary && scalars[index] == ":" {
            index += 1
            if let field = Field(rawValue: prefix) {
                guard !excluded else { throw Failure.invalidExclusion }
                let value = try value(allowEmpty: false)
                try validate(value, for: field)
                return .filter(.init(field: field, value: value))
            }
            let literal = prefix + ":" + (try value(allowEmpty: true))
            return .term(.init(text: literal, isPhrase: false), excluded: excluded)
        }
        guard atBoundary else { throw Failure.invalidSyntax }
        if prefix == "OR" && !excluded { return .or }
        return .term(.init(text: prefix, isPhrase: false), excluded: excluded)
    }

    private var atBoundary: Bool {
        index == scalars.count || scalars[index].properties.isWhitespace
    }

    private func text(_ start: Int, _ end: Int) -> String {
        String(String.UnicodeScalarView(scalars[start..<end]))
    }

    private mutating func value(allowEmpty: Bool) throws -> String {
        if atBoundary {
            guard allowEmpty else { throw Failure.emptyValue }
            return ""
        }
        if scalars[index] == "\"" { return try quoted() }
        let start = index
        while !atBoundary {
            guard scalars[index] != "\"" else { throw Failure.invalidSyntax }
            index += 1
        }
        return text(start, index)
    }

    private mutating func quoted() throws -> String {
        index += 1
        var result = ""
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar == "\"" {
                guard atBoundary else { throw Failure.invalidSyntax }
                guard !result.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else {
                    throw Failure.emptyValue
                }
                return result
            }
            if scalar == "\\", index < scalars.count,
               scalars[index] == "\"" || scalars[index] == "\\" {
                result.unicodeScalars.append(scalars[index])
                index += 1
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        throw Failure.unterminatedQuote
    }

    private func validate(_ value: String, for field: Field) throws {
        switch field {
        case .agent:
            guard ["claude", "codex", "copilot", "grok"].contains(value) else { throw Failure.invalidFilterValue }
        case .status:
            guard ["running", "waiting", "completed", "failed"].contains(value) else { throw Failure.invalidFilterValue }
        case .role:
            guard ["user", "assistant", "tool"].contains(value) else { throw Failure.invalidFilterValue }
        case .after, .before:
            guard validDate(value) else { throw Failure.invalidDate }
        case .recent:
            guard validWindow(value) else { throw Failure.invalidWindow }
        case .project, .dir, .env, .tool, .file, .model:
            break
        }
    }

    private func validDate(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
        let digits = bytes.enumerated().filter { $0.offset != 4 && $0.offset != 7 }.map(\.element)
        guard digits.allSatisfy({ (48...57).contains($0) }) else { return false }
        func number(_ range: Range<Int>) -> Int {
            bytes[range].reduce(0) { $0 * 10 + Int($1 - 48) }
        }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        guard year > 0, (1...12).contains(month), day > 0 else { return false }
        let leap = year.isMultiple(of: 4) && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        return day <= days[month - 1]
    }

    private func validWindow(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let unit = bytes.last, unit == 104 || unit == 100 else { return false }
        let digits = bytes.dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
              let amount = Int64(String(decoding: digits, as: UTF8.self)), amount > 0 else { return false }
        let milliseconds: Int64 = unit == 104 ? 3_600_000 : 86_400_000
        return !amount.multipliedReportingOverflow(by: milliseconds).overflow
    }
}
