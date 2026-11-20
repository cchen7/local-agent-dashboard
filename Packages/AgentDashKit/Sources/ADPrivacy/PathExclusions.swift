/// SEC-7 / SPEC §12.3: match recorded workspace paths against user exclusions.
/// A match is a statement about a path string, never a filesystem authorization.
public struct PathExclusions: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case invalidRule(index: Int)
        case hostHomeRequired(index: Int)
        case invalidHostHome
        case tooManyRules
    }

    private enum Component: Sendable {
        case literal([UInt32])
        case wildcard([UInt32])
        case recursive
    }

    private static let slash: UInt32 = 0x2F
    private static let star: UInt32 = 0x2A
    private static let question: UInt32 = 0x3F
    private let rules: [[Component]]

    /// Validate the complete rule set. Use an explicit home for "~/", keeping
    /// its characters literal. No filesystem, shell, or process home lookup.
    public init(_ patterns: [String], hostHome: String? = nil) throws {
        guard patterns.count <= 64 else { throw Failure.tooManyRules }
        rules = try patterns.enumerated().map { index, pattern in
            guard pattern.utf8.count <= 4096 else { throw Failure.invalidRule(index: index) }
            let scalars = pattern.unicodeScalars.map(\.value)
            let homeRelative = scalars.starts(with: [0x7E, Self.slash])
            guard let parts = Self.components(scalars.dropFirst(homeRelative ? 1 : 0)) else {
                throw Failure.invalidRule(index: index)
            }
            var compiled: [Component] = []
            if homeRelative {
                guard let hostHome else { throw Failure.hostHomeRequired(index: index) }
                guard let home = Self.components(hostHome.unicodeScalars.map(\.value)[...]) else {
                    throw Failure.invalidHostHome
                }
                compiled += home.map(Component.literal)
            }
            for part in parts {
                if part == [Self.star, Self.star] {
                    compiled.append(.recursive)
                } else if part.contains(Self.star) || part.contains(Self.question) {
                    compiled.append(.wildcard(part))
                } else {
                    compiled.append(.literal(part))
                }
            }
            return compiled
        }
    }

    public func matches(_ path: String) -> Bool {
        guard !rules.isEmpty, let path = Self.components(path.unicodeScalars.map(\.value)[...]) else { return false }
        return rules.contains { Self.matches($0, path: path) }
    }

    private static func components(_ absolute: ArraySlice<UInt32>) -> [[UInt32]]? {
        guard absolute.first == slash, !absolute.contains(0) else { return nil }
        var rest = absolute.dropFirst()
        guard rest.first != slash else { return nil }
        while rest.last == slash { rest = rest.dropLast() }
        if rest.isEmpty { return [] }
        let parts = rest.split(separator: slash, omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && !$0.elementsEqual([0x2E]) && !$0.elementsEqual([0x2E, 0x2E]) })
        else { return nil }
        return parts.map { Array($0) }
    }

    private static func matches(_ rule: [Component], path: [[UInt32]]) -> Bool {
        // states[i] is whether the rule prefix matches i path components.
        // A recursive component can consume zero or more complete components.
        var states = [true] + Array(repeating: false, count: path.count)
        for component in rule {
            if case .recursive = component {
                for i in path.indices { states[i + 1] = states[i + 1] || states[i] }
            } else {
                for i in path.indices.reversed() {
                    if !states[i] { states[i + 1] = false; continue }
                    switch component {
                    case .literal(let literal): states[i + 1] = literal == path[i]
                    case .wildcard(let glob): states[i + 1] = matches(glob, scalars: path[i])
                    case .recursive: break
                    }
                }
                states[0] = false
            }
        }
        return states[path.count]
    }

    private static func matches(_ glob: [UInt32], scalars: [UInt32]) -> Bool {
        var states = [true] + Array(repeating: false, count: scalars.count)
        for token in glob {
            if token == star {
                for i in scalars.indices { states[i + 1] = states[i + 1] || states[i] }
            } else {
                for i in scalars.indices.reversed() {
                    states[i + 1] = states[i] && (token == question || token == scalars[i])
                }
                states[0] = false
            }
        }
        return states[scalars.count]
    }
}
