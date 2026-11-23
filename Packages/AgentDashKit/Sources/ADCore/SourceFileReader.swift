import Darwin
import Foundation

/// SEC-3 / ADP-2: a pinned, read-only regular file beneath an authorized root.
/// The caller owns source authorization and record parsing. No paths or contents
/// are retained in errors, and no source locks or timestamp writes are performed.
public final class SourceFileReader: Sendable {
    /// Categories only: never attach a path, source content or underlying error.
    public enum Failure: Error, Equatable, Sendable {
        case invalidRoot, invalidRelativePath, openFailed, notRegularFile
        case invalidReadRange, readFailed, metadataFailed, rootChanged
    }

    /// Metadata from the open descriptor, even after its original path is replaced.
    public struct Snapshot: Equatable, Sendable {
        public let device: Int64
        /// Preserves the unsigned inode's bits in signed storage.
        public let inode: Int64
        public let size: Int64
        /// UTC nanoseconds since the Unix epoch.
        public let modificationTimeNS: Int64
    }

    public struct DirectoryEntry: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case file, directory }
        public let name: String
        public let kind: Kind
    }

    /// The directory actually opened for an authorized URL.
    public struct DirectoryIdentity: Equatable, Sendable {
        public let device: Int64
        public let inode: Int64
    }

    /// Read the selected root's identity without listing or reading entries.
    /// Stable local volume UUIDs survive changes to the path and device number.
    public static func registrationIdentity(root: URL) throws -> SourceRootIdentity {
        guard Source.isLocalRoot(root) else { throw Failure.invalidRoot }
        let descriptor = try openDirectory(root: root.standardizedFileURL, components: [])
        defer { close(descriptor) }
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0,
              filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw Failure.metadataFailed }
        // ATTR_VOL_UUID returns one UUID immediately after the UInt32 byte
        // count. Read it on the same descriptor as the inode and birth time.
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var buffer = [UInt8](repeating: 0, count: MemoryLayout<UInt32>.size + MemoryLayout<uuid_t>.size)
        let result = buffer.withUnsafeMutableBytes {
            fgetattrlist(descriptor, &attributes, $0.baseAddress, $0.count, 0)
        }
        guard result == 0, buffer.withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }) == UInt32(buffer.count) else {
            throw Failure.metadataFailed
        }
        let volume = UUID(uuid: buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: uuid_t.self) })
        guard buffer.dropFirst(4).contains(where: { $0 != 0 }) else { throw Failure.metadataFailed }
        let value = try status(of: descriptor)
        return .init(volume: volume, inode: Int64(bitPattern: value.st_ino),
                     birthSeconds: Int64(value.st_birthtimespec.tv_sec),
                     birthNanoseconds: Int64(value.st_birthtimespec.tv_nsec))
    }

    private static let maximumReadSize = 1_048_576
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    private let descriptor: Int32

    /// Open an explicit relative path without following any relative symlink.
    /// Each directory is pinned before opening the next component with openat.
    /// The authorized root itself must be a directory, not a symlink.
    public init(root: URL, relativePath: String, expectedRoot: DirectoryIdentity? = nil) throws {
        let components = try Self.components(relativePath)
        let directory = try Self.openDirectory(root: root, components: Array(components.dropLast()),
                                               expectedRoot: expectedRoot)
        defer { close(directory) }

        // Nonblocking open is essential: a FIFO must reach fstat without waiting
        // for a writer. Only a regular-file descriptor is retained or read.
        let file = openat(directory, components[components.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw Failure.openFailed }
        do {
            let status = try Self.status(of: file)
            guard status.st_mode & S_IFMT == S_IFREG else { throw Failure.notRegularFile }
        } catch {
            close(file)
            throw error
        }
        descriptor = file
    }

    public static func directoryIdentity(root: URL) throws -> DirectoryIdentity {
        let descriptor = try openDirectory(root: root, components: [])
        defer { close(descriptor) }
        return try directoryIdentity(descriptor: descriptor)
    }

    /// Confirm only an absent leaf under an accessible, authorized parent.
    /// Never follow a symlink or treat an unavailable directory as a deletion.
    public static func isMissing(root: URL, relativePath: String, expectedRoot: DirectoryIdentity) throws -> Bool {
        let parts = try components(relativePath)
        let parent = try openDirectory(root: root, components: Array(parts.dropLast()), expectedRoot: expectedRoot)
        defer { close(parent) }
        var value = stat()
        var result: Int32
        repeat { result = fstatat(parent, parts[parts.count - 1], &value, AT_SYMLINK_NOFOLLOW) }
        while result < 0 && errno == EINTR
        if result == 0 { return false }
        if errno == ENOENT { return true }
        throw Failure.metadataFailed
    }

    /// List direct regular files/directories by a pinned descriptor. Symlinks,
    /// devices, FIFOs and entries removed during enumeration are not returned.
    public static func directoryEntries(root: URL, in relativeDirectory: String? = nil) throws -> [DirectoryEntry] {
        let components = try relativeDirectory.map(Self.components) ?? []
        let descriptor = try openDirectory(root: root, components: components)
        guard let directory = fdopendir(descriptor) else {
            close(descriptor)
            throw Failure.openFailed
        }
        defer { closedir(directory) }
        var result: [DirectoryEntry] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                if errno == EINTR { continue }
                if errno != 0 { throw Failure.metadataFailed }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { buffer in
                String(bytes: buffer.prefix(length), encoding: .utf8)
            }
            guard let name, !name.isEmpty, name != ".", name != ".." else { continue }
            var status = stat()
            var checked: Int32
            repeat { checked = fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) }
            while checked < 0 && errno == EINTR
            if checked < 0 {
                if errno == ENOENT { continue }
                throw Failure.metadataFailed
            }
            switch status.st_mode & S_IFMT {
            case S_IFREG: result.append(.init(name: name, kind: .file))
            case S_IFDIR: result.append(.init(name: name, kind: .directory))
            default: break
            }
        }
        return result
    }

    private static func openDirectory(root: URL, components: [String],
                                      expectedRoot: DirectoryIdentity? = nil) throws -> Int32 {
        let rootPath = root.path(percentEncoded: false)
        let localHost = root.host(percentEncoded: false)?.lowercased()
        guard root.isFileURL, localHost == nil || localHost == "" || localHost == "localhost",
              rootPath.hasPrefix("/"), !rootPath.utf8.contains(0),
              !rootPath.utf8.split(separator: 0x2F).contains(where: { $0.elementsEqual([0x2E]) || $0.elementsEqual([0x2E, 0x2E]) }) else {
            throw Failure.invalidRoot
        }
        // A trailing slash can force symlink traversal before O_NOFOLLOW applies.
        var rootBytes = Array(rootPath.utf8)
        while rootBytes.count > 1 && rootBytes.last == 0x2F { rootBytes.removeLast() }
        var directory = open(String(decoding: rootBytes, as: UTF8.self), Self.directoryFlags)
        guard directory >= 0 else { throw Failure.openFailed }
        if let expectedRoot {
            do {
                guard try directoryIdentity(descriptor: directory) == expectedRoot else { throw Failure.rootChanged }
            } catch {
                close(directory)
                throw error
            }
        }
        for component in components {
            let next = openat(directory, component, Self.directoryFlags)
            close(directory)
            guard next >= 0 else { throw Failure.openFailed }
            directory = next
        }
        return directory
    }

    private static func directoryIdentity(descriptor: Int32) throws -> DirectoryIdentity {
        let value = try status(of: descriptor)
        return .init(device: Int64(value.st_dev), inode: Int64(bitPattern: value.st_ino))
    }

    private static func components(_ relativePath: String) throws -> [String] {
        // Split bytes: a combining scalar after '/' must not hide a separator.
        let pieces = relativePath.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !pieces.isEmpty,
              pieces.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw Failure.invalidRelativePath
        }
        return pieces
    }

    deinit { close(descriptor) }

    /// Read at most the requested bytes, capped at 1 MiB per call. Short reads and
    /// EOF are returned as-is. pread leaves the descriptor's shared cursor alone.
    public func read(upToCount count: Int, offset: Int64) throws -> Data {
        guard count >= 0, offset >= 0 else { throw Failure.invalidReadRange }
        let boundedCount = min(count, Self.maximumReadSize)
        guard offset <= Int64.max - Int64(boundedCount) else { throw Failure.invalidReadRange }
        guard boundedCount > 0 else { return Data() }

        var data = Data(count: boundedCount)
        var bytesRead: Int
        repeat {
            bytesRead = data.withUnsafeMutableBytes { buffer in
                pread(descriptor, buffer.baseAddress, boundedCount, offset)
            }
        } while bytesRead < 0 && errno == EINTR
        guard bytesRead >= 0 else { throw Failure.readFailed }
        data.count = bytesRead
        return data
    }

    /// Take a fresh fstat snapshot of the pinned file, never its original path.
    public func snapshot() throws -> Snapshot {
        let status = try Self.status(of: descriptor)
        let (secondsNS, secondsOverflow) = Int64(status.st_mtimespec.tv_sec)
            .multipliedReportingOverflow(by: 1_000_000_000)
        let (modificationTimeNS, sumOverflow) = secondsNS
            .addingReportingOverflow(Int64(status.st_mtimespec.tv_nsec))
        guard !secondsOverflow, !sumOverflow, status.st_size >= 0 else { throw Failure.metadataFailed }
        return Snapshot(device: Int64(status.st_dev), inode: Int64(bitPattern: status.st_ino),
                        size: status.st_size, modificationTimeNS: modificationTimeNS)
    }

    private static func status(of descriptor: Int32) throws -> stat {
        var value = stat()
        var result: Int32
        repeat { result = fstat(descriptor, &value) } while result < 0 && errno == EINTR
        guard result == 0 else { throw Failure.metadataFailed }
        return value
    }
}
