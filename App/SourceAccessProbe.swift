import Darwin
import Foundation
import ADAdapters
import ADCore

enum SourceAccessStatus: Equatable, Sendable {
    case notChecked, readable(entries: Int), missing, denied, staleBookmark, wrongDirectory, pathConflict
}

enum SourceFilePreview: Equatable, Sendable {
    case available(Int), unsupported, unavailable
}

/// M0 access verification reads directory entry metadata only, never file contents.
/// Top-level entry counts establish access, not session discovery or parser coverage.
enum SourceAccessProbe {
    private static let bookmarkResolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]

    static func defaultSources() throws -> [Source] {
        // NSHomeDirectory is the container home under App Sandbox. Resolve the real
        // local account home using the read-only POSIX account lookup instead.
        var account = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let home: String = try buffer.withUnsafeMutableBufferPointer { bytes in
            guard getpwuid_r(getuid(), &account, bytes.baseAddress, bytes.count, &result) == 0,
                  result != nil, let directory = account.pw_dir else { throw AccessError.homeUnavailable }
            return String(cString: directory)
        }
        let root = URL(fileURLWithPath: home, isDirectory: true)
        return [
            Source(agent: .claudeCode, label: "Claude Code", rootURL: root.appendingPathComponent(AgentKind.claudeCode.defaultSourceDirectoryName)),
            Source(agent: .codex, label: "Codex", rootURL: root.appendingPathComponent(AgentKind.codex.defaultSourceDirectoryName)),
            Source(agent: .copilot, label: "Copilot CLI", rootURL: root.appendingPathComponent(AgentKind.copilot.defaultSourceDirectoryName)),
            Source(agent: .grokBuild, label: "Grok Build", rootURL: root.appendingPathComponent(AgentKind.grokBuild.defaultSourceDirectoryName))
        ]
    }

    static func check(_ source: Source) -> SourceAccessStatus {
        do {
            switch source.access {
            case .defaultLocation: return try countEntries(at: source.rootURL)
            case .bookmark(let data):
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: bookmarkResolutionOptions,
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { return .staleBookmark }
                guard url.standardizedFileURL == source.rootURL.standardizedFileURL else { return .wrongDirectory }
                guard url.startAccessingSecurityScopedResource() else { return .denied }
                defer { url.stopAccessingSecurityScopedResource() }
                return try countEntries(at: url)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .missing }
        catch { return .denied }
    }

    /// Keep a read-only bookmark active until scanning and watching have both stopped.
    static func withIndexingAccess<Value: Sendable>(to source: Source, _ run: @Sendable (URL) async throws -> Value)
        async throws -> Value {
        switch source.access {
        case .defaultLocation:
            return try await run(source.rootURL)
        case .bookmark(let data):
            var stale = false
            let root: URL
            do {
                root = try URL(resolvingBookmarkData: data, options: bookmarkResolutionOptions,
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            } catch {
                throw IndexAccessFailure.denied
            }
            guard !stale else { throw IndexAccessFailure.staleBookmark }
            guard root.standardizedFileURL == source.rootURL.standardizedFileURL else {
                throw IndexAccessFailure.rootChanged
            }
            guard root.startAccessingSecurityScopedResource() else { throw IndexAccessFailure.denied }
            defer { root.stopAccessingSecurityScopedResource() }
            return try await run(root)
        }
    }

    /// Count discovered session files without opening any session content.
    static func preview(_ source: Source) async -> SourceFilePreview {
        if source.agent == .grokBuild { return .unsupported }
        do {
            return try await withIndexingAccess(to: source) { root in
                try Task.checkCancellation()
                let identity = try SourceFileReader.directoryIdentity(root: root)
                let files: [SourceFile]
                switch source.agent {
                case .claudeCode: files = try ClaudeCodeAdapter().discover(in: source, authorizedRoot: root)
                case .codex: files = try CodexAdapter().discover(in: source, authorizedRoot: root)
                case .copilot: files = try CopilotAdapter().discover(in: source, authorizedRoot: root)
                case .grokBuild: return .unsupported
                }
                guard try SourceFileReader.directoryIdentity(root: root) == identity else { return .unavailable }
                return .available(files.lazy.filter { $0.role == .session || $0.role == .subagent }.count)
            }
        } catch { return .unavailable }
    }

    /// Match older rows without an identity, using only their existing
    /// access. No prompts, volume mounting, or session file reads.
    static func directoryIdentity(_ source: Source) -> SourceRootIdentity? {
        switch source.access {
        case .defaultLocation:
            return try? SourceFileReader.registrationIdentity(root: source.rootURL)
        case .bookmark(let data):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: bookmarkResolutionOptions,
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  !stale, url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            return try? SourceFileReader.registrationIdentity(root: url)
        }
    }

    private static func countEntries(at root: URL) throws -> SourceAccessStatus {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                  options: [.skipsSubdirectoryDescendants])
        return .readable(entries: entries.count)
    }

    private enum AccessError: Error { case homeUnavailable }
}
