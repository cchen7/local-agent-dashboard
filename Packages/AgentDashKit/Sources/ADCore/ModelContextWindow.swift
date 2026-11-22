import Foundation

/// User-supplied fallback for a literal, case-sensitive model ID prefix.
public struct ModelContextWindow: Codable, Equatable, Sendable {
    public let prefix: String
    public let tokens: Int64

    public static let maximumRules = 64

    public init(prefix: String, tokens: Int64) {
        self.prefix = prefix
        self.tokens = tokens
    }

    public static func areValid(_ rules: [Self]) -> Bool {
        guard rules.count <= maximumRules else { return false }
        var prefixes = Set<[UInt8]>()
        return rules.allSatisfy { rule in
            let key = Array(rule.prefix.utf8.prefix(257))
            return rule.tokens > 0 && !key.isEmpty && key.count <= 256 &&
                !rule.prefix.unicodeScalars.contains {
                    $0.properties.isWhitespace || $0.properties.generalCategory == .control
                } && prefixes.insert(key).inserted
        }
    }
}

public struct SessionContextUsage: Equatable, Sendable {
    public enum CapacitySource: Equatable, Sendable { case recorded, configured }

    public let input: Int64
    public let capacity: Int64
    public let source: CapacitySource
    public var fraction: Double { Double(input) / Double(capacity) }

    public init?(input: Int64?, recordedCapacity: Int64?, model: String?, rules: [ModelContextWindow]) {
        guard let input, input >= 0 else { return nil }
        self.input = input
        if let recordedCapacity, recordedCapacity > 0 {
            capacity = recordedCapacity
            source = .recorded
        } else {
            guard let model, !model.isEmpty,
                  let rule = rules.filter({ $0.tokens > 0 && !$0.prefix.isEmpty && model.utf8.starts(with: $0.prefix.utf8) })
                      .max(by: { $0.prefix.utf8.count < $1.prefix.utf8.count }) else { return nil }
            capacity = rule.tokens
            source = .configured
        }
    }
}
