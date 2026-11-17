import Foundation

/// A primary token and its aliases at one FTS position, with UTF-8 byte offsets.
public struct SearchTokenGroup: Equatable, Sendable {
    public let terms: [String]
    public let start: Int
    public let end: Int
}

/// Pure deterministic splitting shared by Store registration and future Search code (DEV-004).
/// Input is one unicode61 word (configured to retain `_-.`), preserving its original case.
public enum SearchTokenization {
    /// Split one word into ordered CJK bigrams or a whole identifier with colocated aliases.
    public static func groups(in word: String) -> [SearchTokenGroup] {
        let scalars = Array(word.unicodeScalars)
        var offsets = [0]
        for scalar in scalars { offsets.append(offsets[offsets.count - 1] + scalar.utf8.count) }
        var result: [SearchTokenGroup] = []
        var index = 0
        func text(_ lower: Int, _ upper: Int) -> String {
            String(String.UnicodeScalarView(scalars[lower..<upper]))
        }
        while index < scalars.count {
            let start = index
            let cjk = isCJK(scalars[index])
            while index < scalars.count && isCJK(scalars[index]) == cjk { index += 1 }
            if cjk {
                if index - start == 1 {
                    result.append(.init(terms: [text(start, index)], start: offsets[start], end: offsets[index]))
                } else {
                    for position in start..<(index - 1) {
                        result.append(.init(terms: [text(position, position + 2)], start: offsets[position], end: offsets[position + 2]))
                    }
                }
            } else {
                let raw = text(start, index)
                let whole = normalize(raw)
                var terms = whole.isEmpty ? [] : [whole]
                var partStart = start
                for position in start...index {
                    let atEnd = position == index
                    let separator = !atEnd && "_-.".unicodeScalars.contains(scalars[position])
                    let camel = position > partStart && !atEnd && (
                        (CharacterSet.lowercaseLetters.contains(scalars[position - 1]) && CharacterSet.uppercaseLetters.contains(scalars[position])) ||
                        (position + 1 < index && CharacterSet.uppercaseLetters.contains(scalars[position - 1]) &&
                         CharacterSet.uppercaseLetters.contains(scalars[position]) && CharacterSet.lowercaseLetters.contains(scalars[position + 1])))
                    if atEnd || separator || camel {
                        if position > partStart {
                            let part = normalize(text(partStart, position))
                            if !terms.contains(part) { terms.append(part) }
                        }
                        partStart = separator ? position + 1 : position
                    }
                }
                if !terms.isEmpty { result.append(.init(terms: terms, start: offsets[start], end: offsets[index])) }
            }
        }
        return result
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF,
             0x3040...0x30FF, 0x31F0...0x31FF, 0xAC00...0xD7AF: true
        default: false
        }
    }
}
