import Darwin
import Foundation
import ADCore

enum SourceAccessStatus: Equatable, Sendable {
    case notChecked, readable(entries: Int), missing, denied, staleBookmark, wrongDirectory, pathConflict
}

/// M0 access verification reads directory entry metadata only, never file contents.
/// Top-level entry counts establish access, not session discovery or parser coverage.
enum SourceAccessProbe {
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
            Source(agent: .claudeCode, label: "Claude Code", rootURL: root.appendingPathComponent(".claude")),
            Source(agent: .codex, label: "Codex", rootURL: root.appendingPathComponent(".codex")),
            Source(agent: .copilot, label: "Copilot CLI", rootURL: root.appendingPathComponent(".copilot")),
            Source(agent: .grokBuild, label: "Grok Build", rootURL: root.appendingPathComponent(".grok"))
        ]
    }

    static func check(_ source: Source) -> SourceAccessStatus {
        do {
            switch source.access {
            case .defaultLocation: return try countEntries(at: source.rootURL)
            case .bookmark(let data):
                var stale = false
                let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                                  relativeTo: nil, bookmarkDataIsStale: &stale)
                guard !stale else { return .staleBookmark }
                guard url.startAccessingSecurityScopedResource() else { return .denied }
                defer { url.stopAccessingSecurityScopedResource() }
                return try countEntries(at: url)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .missing }
        catch { return .denied }
    }

    /// Match older rows without an identity, using only their existing
    /// access. No prompts, volume mounting, or session file reads.
    static func directoryIdentity(_ source: Source) -> SourceRootIdentity? {
        switch source.access {
        case .defaultLocation:
            return try? SourceFileReader.directoryIdentity(root: source.rootURL)
        case .bookmark(let data):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  !stale, url.startAccessingSecurityScopedResource() else { return nil }
            defer { url.stopAccessingSecurityScopedResource() }
            return try? SourceFileReader.directoryIdentity(root: url)
        }
    }

    private static func countEntries(at root: URL) throws -> SourceAccessStatus {
        let entries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                  options: [.skipsSubdirectoryDescendants])
        return .readable(entries: entries.count)
    }

    private enum AccessError: Error { case homeUnavailable }
}
