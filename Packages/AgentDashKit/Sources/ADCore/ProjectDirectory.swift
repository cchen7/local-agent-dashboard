import Darwin
import Foundation

/// Project workspaces are indexed paths, not a source grant. Use only
/// directory metadata, never follow arbitrary symlinks, and do not open
/// paths on known remote or automounted volumes.
public enum ProjectDirectory {
    // Darwin O_SEARCH: use a search-only directory descriptor, not a
    // file-read/notification descriptor for each ancestor.
    private static let flags = O_EXEC | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC

    public static func withVerifiedLocalDirectory<Value>(_ path: String, _ use: (URL) throws -> Value) throws -> Value {
        guard path.utf8.count <= 4096, !path.utf8.contains(0), path.hasPrefix("/") else {
            throw SourceFileReader.Failure.invalidRoot
        }
        var fields = path.utf8.dropFirst().split(separator: 0x2f, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !fields.isEmpty, fields.count <= 256, fields.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw SourceFileReader.Failure.invalidRoot
        }
        if let first = fields.first, first == "tmp" || first == "var" {
            // System-controlled paths; do not expand arbitrary aliases.
            fields.insert("private", at: 0)
        }
        let mounts = try disallowedMounts()
        let pinned = try openLocal(fields, disallowed: mounts)
        defer { close(pinned) }
        let current = try openLocal(fields, disallowed: mounts)
        defer { close(current) }
        guard try identity(pinned) == identity(current) else { throw SourceFileReader.Failure.rootChanged }
        let url = URL(fileURLWithPath: "/" + fields.joined(separator: "/"), isDirectory: true)
        return try use(url)
    }

    private static func disallowedMounts() throws -> Set<Data> {
        var table: UnsafeMutablePointer<statfs>?
        // NOWAIT returns cached flags without requesting stats from the volumes.
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        guard count > 0, let table else { throw SourceFileReader.Failure.metadataFailed }
        defer { free(table) }
        var result: Set<Data> = []
        for i in 0..<Int(count) {
            var entry = table[i]
            let type = withUnsafeBytes(of: &entry.f_fstypename) { Data($0.prefix { $0 != 0 }) }
            if entry.f_flags & UInt32(MNT_LOCAL) == 0 || type == Data("autofs".utf8) {
                let name = withUnsafeBytes(of: &entry.f_mntonname) {
                    String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self)
                }
                let physical = name == "/tmp" || name.hasPrefix("/tmp/") || name == "/var" || name.hasPrefix("/var/")
                    ? "/private" + name : name
                result.insert(mountKey(physical))
            }
        }
        return result
    }

    private static func mountKey(_ raw: String) -> Data {
        // Be conservative about aliases on case-insensitive APFS volumes.
        var name = raw
        while name.utf8.count > 1 && name.hasSuffix("/") { name.removeLast() }
        let folded = name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        return Data(folded.utf8)
    }

    private static func openLocal(_ fields: [String], disallowed: Set<Data>) throws -> Int32 {
        var fd = open("/", flags)
        guard fd >= 0 else { throw SourceFileReader.Failure.openFailed }
        do {
            var prefix = ""
            try requireLocal(fd)
            for field in fields {
                prefix += "/" + field
                let dataRoot = "/System/Volumes/Data"
                // Firmlinks may give two path spellings for a mounted directory.
                let alias = prefix.hasPrefix(dataRoot + "/") ? String(prefix.dropFirst(dataRoot.count)) : dataRoot + prefix
                guard !disallowed.contains(mountKey(prefix)), !disallowed.contains(mountKey(alias)) else {
                    throw SourceFileReader.Failure.invalidRoot
                }
                let next = openat(fd, field, flags)
                guard next >= 0 else { throw SourceFileReader.Failure.openFailed }
                close(fd)
                fd = next
                try requireLocal(fd)
            }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func requireLocal(_ fd: Int32) throws {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw SourceFileReader.Failure.metadataFailed
        }
    }

    private static func identity(_ fd: Int32) throws -> SourceFileReader.DirectoryIdentity {
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw SourceFileReader.Failure.metadataFailed }
        return .init(device: Int64(value.st_dev), inode: Int64(bitPattern: value.st_ino))
    }
}
