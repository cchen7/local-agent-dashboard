import Foundation

/// User-editable metadata. Source identity, permissions and checkpoint state
/// deliberately aren't represented here.
public struct SourceSettings: Equatable, Sendable {
    public var label: String
    public var environment: String
    public var pathMappings: [PathMapping]
    public var environmentRules: [EnvironmentRule]

    public static let codexEnvironmentFields = ["model_provider", "originator"]

    public init(_ source: Source) {
        label = source.label
        environment = source.environment
        pathMappings = source.pathMappings
        environmentRules = source.environmentRules
    }

    /// Compare bytes for the optimistic edit check: differently encoded
    /// paths may refer to different files even when Swift strings compare equal.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        bytesEqual(lhs.label, rhs.label) && bytesEqual(lhs.environment, rhs.environment) &&
            sameMappings(lhs.pathMappings, rhs.pathMappings) &&
            sameRules(lhs.environmentRules, rhs.environmentRules)
    }

    public func validated(for agent: AgentKind, previous: SourceSettings, hostHome: String?) throws -> SourceSettings {
        var result = self
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnvironment = environment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else { throw SourceSettingsValidation.missingLabel }
        guard !trimmedEnvironment.isEmpty else { throw SourceSettingsValidation.missingEnvironment }
        if !Self.bytesEqual(label, previous.label) { result.label = trimmedLabel }
        if !Self.bytesEqual(environment, previous.environment) { result.environment = trimmedEnvironment }
        if !Self.sameMappings(pathMappings, previous.pathMappings) {
            do {
                // PathMapper validates every rule, even when the probe isn't mapped.
                _ = try PathMapper.map("/", using: pathMappings, hostHome: hostHome)
            } catch let failure as PathMapper.Failure {
                throw SourceSettingsValidation.invalidMapping(failure)
            }
        }
        if !Self.sameRules(environmentRules, previous.environmentRules) {
            guard agent == .codex else { throw SourceSettingsValidation.unsupportedEnvironmentRules }
            var claims: [String: [String: String]] = [:]
            for (index, rule) in environmentRules.enumerated() {
                let unchanged = previous.environmentRules.contains { Self.sameRule($0, rule) }
                let trimmed = rule.environment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard Self.codexEnvironmentFields.contains(rule.field),
                      !rule.equals.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !rule.equals.utf8.contains(0), !trimmed.utf8.contains(0), !trimmed.isEmpty else {
                    if unchanged { continue } // Preserve opaque legacy rules when adding supported rules.
                    throw SourceSettingsValidation.invalidRule(index)
                }
                let environment = unchanged ? rule.environment : trimmed
                if let existing = claims[rule.field]?[rule.equals], !Self.bytesEqual(existing, environment) {
                    throw SourceSettingsValidation.conflictingRule(index)
                }
                claims[rule.field, default: [:]][rule.equals] = environment
                result.environmentRules[index].environment = environment
            }
        }
        return result
    }

    private static func bytesEqual(_ a: String, _ b: String) -> Bool { a.utf8.elementsEqual(b.utf8) }

    public static func sameMappings(_ a: [PathMapping], _ b: [PathMapping]) -> Bool {
        a.elementsEqual(b) { bytesEqual($0.from, $1.from) && bytesEqual($0.to, $1.to) }
    }

    private static func sameRules(_ a: [EnvironmentRule], _ b: [EnvironmentRule]) -> Bool {
        a.elementsEqual(b, by: sameRule)
    }

    private static func sameRule(_ a: EnvironmentRule, _ b: EnvironmentRule) -> Bool {
        bytesEqual(a.field, b.field) && bytesEqual(a.equals, b.equals) && bytesEqual(a.environment, b.environment)
    }
}

public enum SourceSettingsValidation: Error, Equatable, Sendable {
    case missingLabel, missingEnvironment
    case invalidMapping(PathMapper.Failure)
    case unsupportedEnvironmentRules
    case invalidRule(Int)
    case conflictingRule(Int)
}
