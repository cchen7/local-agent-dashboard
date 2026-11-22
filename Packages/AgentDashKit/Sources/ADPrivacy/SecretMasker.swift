import Foundation

/// SEC-8 / SPEC §12.2: make a display copy of text with common credentials hidden.
public enum SecretMasker {
    static let placeholder = "••••••"
    private static let tokens = try? NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])(?:sk-[A-Za-z0-9_-]{16,}|(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}(?![A-Za-z0-9_])|xox[bp]-[A-Za-z0-9-]{12,})"#
    )
    private static let assignments = try? NSRegularExpression(
        pattern: #"(?m)^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)[ \t]*=[ \t]*"#
    )
    private static let privateKeyMarkers = try? NSRegularExpression(
        pattern: #"-----(BEGIN|END) ((?:[A-Z0-9-]+ )*PRIVATE KEY)-----"#
    )
    private static let sensitiveSuffixes = ["KEY", "TOKEN", "SECRET", "PASSWORD"]

    /// Return the original text if no known pattern matched. No files are read
    /// or changed. Callers should apply this to raw text before formatting it.
    public static func mask(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        guard let tokens, let assignments, let privateKeyMarkers else { return placeholder }
        let utf16 = text as NSString
        let whole = NSRange(location: 0, length: utf16.length)
        var matches = tokens.matches(in: text, range: whole).map(\.range)

        var valueEnd = 0
        for assignment in assignments.matches(in: text, range: whole) where assignment.range.location >= valueEnd {
            let name = utf16.substring(with: assignment.range(at: 1)).uppercased()
            guard sensitiveSuffixes.contains(where: name.hasSuffix),
                  let value = assignmentValue(in: utf16, from: NSMaxRange(assignment.range)) else { continue }
            matches.append(value)
            valueEnd = NSMaxRange(value)
        }

        var openLabels: [String] = []
        var blockStart = 0
        for marker in privateKeyMarkers.matches(in: text, range: whole) {
            let label = utf16.substring(with: marker.range(at: 2))
            if utf16.substring(with: marker.range(at: 1)) == "BEGIN" {
                if openLabels.isEmpty { blockStart = marker.range.location }
                openLabels.append(label)
            } else if openLabels.last == label {
                openLabels.removeLast()
                if openLabels.isEmpty {
                    matches.append(NSRange(location: blockStart, length: NSMaxRange(marker.range) - blockStart))
                }
            }
        }
        if !openLabels.isEmpty {
            matches.append(NSRange(location: blockStart, length: whole.length - blockStart))
        }

        guard !matches.isEmpty else { return text }
        // All detectors see the raw text. Merge their ranges before replacing
        // so an assignment containing a recognized token is masked only once.
        matches.sort { $0.location < $1.location }
        var output = ""
        var end = 0
        for match in matches {
            if match.location >= end {
                output += utf16.substring(with: NSRange(location: end, length: match.location - end))
                output += placeholder
            }
            end = max(end, NSMaxRange(match))
        }
        output += utf16.substring(from: end)
        return output
    }

    private static func assignmentValue(in text: NSString, from start: Int) -> NSRange? {
        guard start < text.length else { return nil }
        let first = text.character(at: start)
        let quoted = first == 0x22 || first == 0x27 || first == 0x60
        let valueStart = quoted ? start + 1 : start
        var cursor = valueStart
        var precededBySpace = true
        var lastValueEnd = valueStart
        while cursor < text.length {
            let unit = text.character(at: cursor)
            if quoted {
                if unit == first { break }
            } else if isLineBreak(unit) || (unit == 0x23 && precededBySpace) {
                break
            }
            cursor += 1
            if unit == 0x5C, cursor < text.length {
                // Include one escaped character, or a continued CRLF, in the value.
                if text.character(at: cursor) == 0x0D, cursor + 1 < text.length,
                   text.character(at: cursor + 1) == 0x0A {
                    cursor += 1
                }
                cursor += 1
                precededBySpace = false
            } else {
                precededBySpace = unit == 0x20 || unit == 0x09
            }
            if quoted || !precededBySpace { lastValueEnd = cursor }
        }
        guard lastValueEnd > valueStart else { return nil }
        return NSRange(location: valueStart, length: lastValueEnd - valueStart)
    }

    private static func isLineBreak(_ unit: unichar) -> Bool {
        switch unit {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029: true
        default: false
        }
    }
}
