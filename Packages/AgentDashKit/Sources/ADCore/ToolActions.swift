import Foundation

/// One recorded target of a known tool operation. Counts describe the edit
/// or patch sent to the tool and do not assert a change on disk.
public struct ToolFileAction: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, Sendable { case read, edit, write, delete }

    public let path: String
    public let operation: Operation
    public let added: Int64?
    public let removed: Int64?

    public init(path: String, operation: Operation, added: Int64? = nil, removed: Int64? = nil) {
        self.path = path
        self.operation = operation
        self.added = added.flatMap { (0...1_048_576).contains($0) ? $0 : nil }
        self.removed = removed.flatMap { (0...1_048_576).contains($0) ? $0 : nil }
    }

    public static func validPath(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 && !value.utf8.contains(0)
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Outcome fields explicitly present in the producer record.
public struct ToolCommandCompletion: Codable, Equatable, Sendable {
    public let exitCode: Int64?
    public let durationMS: Int64?
    public let success: Bool?

    public init(exitCode: Int64? = nil, durationMS: Int64? = nil, success: Bool? = nil) {
        self.exitCode = exitCode
        self.durationMS = durationMS
        self.success = success
    }

    public var isEmpty: Bool { exitCode == nil && durationMS == nil && success == nil }
}

/// Bounded evidence attached to the normalized event, never sourced from
/// tool output prose or from the filesystem named in the event.
public struct ToolActionEvidence: Codable, Equatable, Sendable {
    public static let maximumFiles = 32
    public static let maximumCommandBytes = 8192

    public let files: [ToolFileAction]
    public let command: String?
    public let completion: ToolCommandCompletion?

    public init(files: [ToolFileAction] = [], command: String? = nil, completion: ToolCommandCompletion? = nil) {
        self.files = Array(files.lazy.filter { ToolFileAction.validPath($0.path) }.prefix(Self.maximumFiles))
        self.command = command.flatMap {
            !$0.isEmpty && $0.utf8.count <= Self.maximumCommandBytes && !$0.utf8.contains(0) ? $0 : nil
        }
        self.completion = completion.flatMap { $0.isEmpty ? nil : $0 }
    }

    public var isEmpty: Bool { files.isEmpty && command == nil && completion == nil }
}
