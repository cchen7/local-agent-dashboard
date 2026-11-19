import Darwin
import Foundation

/// SEC-3 / ADP-2: a pinned, read-only regular file beneath an authorized root.
/// The caller owns source authorization and record parsing. No paths or contents
/// are retained in errors, and no source locks or timestamp writes are performed.
public final class SourceFileReader: Sendable {
    /// Categories only: never attach a path, source content or underlying error.
    public enum Failure: Error, Equatable, Sendable {
        case invalidRoot, invalidRelativePath, openFailed, notRegularFile
        case invalidReadRange, readFailed, metadataFailed
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

    private static let maximumReadSize = 1_048_576
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
    private let descriptor: Int32

    /// Open an explicit relative path without following any relative symlink.
    /// Each directory is pinned before opening the next component with openat.
    /// The authorized root itself must be a directory, not a symlink.
    public init(root: URL, relativePath: String) throws {
        let rootPath = root.path(percentEncoded: false)
        let localHost = root.host(percentEncoded: false)?.lowercased()
        guard root.isFileURL, localHost == nil || localHost == "" || localHost == "localhost",
              rootPath.hasPrefix("/"), !rootPath.utf8.contains(0),
              !rootPath.utf8.split(separator: 0x2F).contains(where: { $0.elementsEqual([0x2E]) || $0.elementsEqual([0x2E, 0x2E]) }) else {
            throw Failure.invalidRoot
        }
        // Split bytes: a combining scalar after '/' must not hide a separator.
        let components = relativePath.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.utf8.contains(0) }) else {
            throw Failure.invalidRelativePath
        }

        // A trailing slash can force symlink traversal before O_NOFOLLOW applies.
        var rootBytes = Array(rootPath.utf8)
        while rootBytes.count > 1 && rootBytes.last == 0x2F { rootBytes.removeLast() }
        var directory = open(String(decoding: rootBytes, as: UTF8.self), Self.directoryFlags)
        guard directory >= 0 else { throw Failure.openFailed }
        defer { close(directory) }
        for component in components.dropLast() {
            let next = openat(directory, component, Self.directoryFlags)
            guard next >= 0 else { throw Failure.openFailed }
            close(directory)
            directory = next
        }

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
