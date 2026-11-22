import ADCore
import Foundation

/// ADP-CC: local Claude Code JSONL. Discovery uses only read-only directory entries.
public struct ClaudeCodeAdapter: AgentAdapter {
    public enum Failure: Error, Equatable, Sendable {
        case invalidSource, unsupportedFile
    }

    public static let kind: AgentKind = .claudeCode
    public static let parserVersion = 9

    private let includeThinking: Bool

    public init(includeThinking: Bool = false) { self.includeThinking = includeThinking }

    public func discover(in source: Source, authorizedRoot: URL) throws -> [SourceFile] {
        let id = try sourceID(source)
        let rootEntries = try SourceFileReader.directoryEntries(root: authorizedRoot)
        var files: [SourceFile] = []
        func add(_ path: String, role: SourceFile.Role) {
            if ClaudeInput(relativePath: path, role: role) != nil {
                files.append(.init(sourceID: id, relativePath: path, role: role, parserVersion: Self.parserVersion))
            }
        }
        if rootEntries.contains(where: { $0.kind == .file && $0.name == "history.jsonl" }) {
            add("history.jsonl", role: .promptHistory)
        }
        if rootEntries.contains(where: { $0.kind == .directory && $0.name == "projects" }) {
            let projects = try SourceFileReader.directoryEntries(root: authorizedRoot, in: "projects")
            for project in projects where project.kind == .directory {
                try Task.checkCancellation()
                let path = "projects/\(project.name)"
                let children = try SourceFileReader.directoryEntries(root: authorizedRoot, in: path)
                for entry in children {
                    if entry.kind == .file && entry.name.hasSuffix(".jsonl") {
                        add(path + "/" + entry.name, role: entry.name.hasPrefix("agent-") ? .subagent : .session)
                    }
                    guard entry.kind == .directory, UUID(uuidString: entry.name) != nil else { continue }
                    let sessionPath = path + "/" + entry.name
                    let sessionEntries = try SourceFileReader.directoryEntries(root: authorizedRoot, in: sessionPath)
                    guard sessionEntries.contains(where: { $0.kind == .directory && $0.name == "subagents" }) else { continue }
                    let subagents = sessionPath + "/subagents"
                    for child in try SourceFileReader.directoryEntries(root: authorizedRoot, in: subagents)
                    where child.kind == .file {
                        add(subagents + "/" + child.name, role: .subagent)
                    }
                }
            }
        }
        return files.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    public func makeDecoder(for file: SourceFile, in source: Source) throws -> ClaudeCodeDecoder {
        guard try sourceID(source) == file.sourceID else { throw Failure.invalidSource }
        guard let input = ClaudeInput(relativePath: file.relativePath, role: file.role)
        else { throw Failure.unsupportedFile }
        return ClaudeCodeDecoder(file: file, environment: source.environment, input: input,
                                 includeThinking: includeThinking)
    }

    /// Generate text for the Copy Resume Command action only.
    public func resumeCommand(for session: SessionRecord) -> String? {
        guard session.key.agent == .claudeCode, let id = UUID(uuidString: session.key.nativeID),
              let path = session.cwd, path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else { return nil }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && claude --resume \(id.uuidString.lowercased())"
    }

    private func sourceID(_ source: Source) throws -> Int64 {
        guard source.agent == Self.kind, let id = source.id else { throw Failure.invalidSource }
        return id
    }
}

enum ClaudeInput {
    case session(id: String)
    case subagent(parent: String?)
    case history

    init?(relativePath: String, role: SourceFile.Role) {
        if relativePath == "history.jsonl", role == .promptHistory {
            self = .history
            return
        }
        let parts = relativePath.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard parts.first == "projects", !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.contains(0) }),
              let name = parts.last, name.hasSuffix(".jsonl") else { return nil }
        let stem = String(name.dropLast(6))
        if role == .session, parts.count == 3, let id = UUID(uuidString: stem) {
            self = .session(id: id.uuidString.lowercased())
        } else if role == .subagent, stem.hasPrefix("agent-"), stem.utf8.count > 6 {
            if parts.count == 5, parts[3] == "subagents", let parent = UUID(uuidString: parts[2]) {
                self = .subagent(parent: parent.uuidString.lowercased())
            } else if parts.count == 3 {
                self = .subagent(parent: nil)
            } else { return nil }
        } else { return nil }
    }
}
