/// FR-SRC-1: pure, one-pass mapping for display and future copy-resume paths.
/// Never use the result to open a source or infer permission to access it.
public enum PathMapper {
    /// Categories and zero-based rule indices only; no paths or underlying errors.
    public enum Failure: Error, Equatable, Sendable {
        case invalidPath
        case invalidFrom(ruleIndex: Int)
        case invalidTo(ruleIndex: Int)
        case hostHomeRequired(ruleIndex: Int)
        case invalidHostHome
        case ambiguousRules(firstIndex: Int, secondIndex: Int)
    }

    /// Match the longest case-sensitive component prefix, comparing UTF-8 bytes.
    /// Rules accept absolute POSIX paths; only `to` also accepts `~/`, requiring
    /// an explicit absolute `hostHome`. No ambient home, filesystem or shell is used.
    /// Dot components, NUL, leading `//` and internal repeated separators fail.
    /// Rule trailing separators are ignored. Mapped input trailing separators
    /// become one (except at root); valid unmatched input is returned unchanged.
    /// All rules are validated, even unmatched ones. Conflicting destinations for
    /// the same normalized source fail; equivalent duplicate rules are allowed.
    /// Returns a path string, not a shell-quoted command or an authorized source URL.
    public static func map(_ path: String, using mappings: [PathMapping], hostHome: String? = nil) throws -> String {
        var rules: [Rule] = []
        for (index, mapping) in mappings.enumerated() {
            guard let from = absoluteBytes(mapping.from) else { throw Failure.invalidFrom(ruleIndex: index) }
            let to = try destination(mapping.to, hostHome: hostHome, ruleIndex: index)
            if let previous = rules.first(where: { $0.from == from }), previous.to != to {
                throw Failure.ambiguousRules(firstIndex: previous.index, secondIndex: index)
            }
            rules.append(Rule(index: index, from: from, to: to))
        }

        guard let input = absoluteBytes(path) else { throw Failure.invalidPath }
        var winner: Rule?
        for rule in rules {
            guard input.starts(with: rule.from),
                  rule.from.count == 1 || input.count == rule.from.count || input[rule.from.count] == slash else { continue }
            if rule.from.count > (winner?.from.count ?? 0) { winner = rule }
        }
        guard let winner else { return path }

        var suffix = input.dropFirst(winner.from.count)
        if suffix.first == slash { suffix = suffix.dropFirst() }
        var output = winner.to
        if !suffix.isEmpty {
            if output.last != slash { output.append(slash) }
            output.append(contentsOf: suffix)
        }
        if path.utf8.count > 1, path.utf8.last == slash, output.last != slash { output.append(slash) }
        return String(decoding: output, as: UTF8.self)
    }

    private struct Rule {
        let index: Int
        let from: [UInt8]
        let to: [UInt8]
    }

    private static let slash: UInt8 = 0x2F

    private static func destination(_ value: String, hostHome: String?, ruleIndex: Int) throws -> [UInt8] {
        var bytes = Array(value.utf8)
        if bytes.starts(with: [0x7E, slash]) {
            guard let hostHome else { throw Failure.hostHomeRequired(ruleIndex: ruleIndex) }
            guard var home = absoluteBytes(hostHome) else { throw Failure.invalidHostHome }
            let suffix = bytes.dropFirst(2)
            if !suffix.isEmpty {
                if home.last != slash { home.append(slash) }
                home.append(contentsOf: suffix)
            }
            bytes = home
        }
        guard let result = absoluteBytes(String(decoding: bytes, as: UTF8.self)) else {
            throw Failure.invalidTo(ruleIndex: ruleIndex)
        }
        return result
    }

    /// Trim trailing separators only; never standardize or resolve path components.
    private static func absoluteBytes(_ value: String) -> [UInt8]? {
        var bytes = Array(value.utf8)
        guard bytes.first == slash, !bytes.contains(0), bytes.count == 1 || bytes[1] != slash else { return nil }
        while bytes.count > 1 && bytes.last == slash { bytes.removeLast() }
        if bytes.count == 1 { return bytes }
        let components = bytes.dropFirst().split(separator: slash, omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && !$0.elementsEqual([0x2E]) && !$0.elementsEqual([0x2E, 0x2E]) }) else {
            return nil
        }
        return bytes
    }
}
