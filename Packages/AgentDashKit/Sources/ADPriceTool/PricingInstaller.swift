import ADPricing
import Darwin
import Foundation

enum PricingInstaller {
    enum Failure: Error { case invalidDestination, unreadableInstalledTable, stagingFailed, destinationChanged }

    static func install(_ bytes: Data, preserving baseline: PriceTable, at destination: URL) throws {
        let candidate = try PriceTable.decode(bytes)
        try preservePrices(in: baseline, with: candidate)
        guard destination.isFileURL, destination.lastPathComponent == "pricing.json" else { throw Failure.invalidDestination }
        let directory = destination.deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent()
        // In normal use this is the allowed .config directory. Do not follow
        // a symlink at either of the user-controlled installation directories.
        try requireDirectoryOrMissing(parent)
        try requireDirectoryOrMissing(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidDestination }
        defer { close(fd) }
        let name = destination.lastPathComponent
        let before = try fileIdentity(at: fd, name: name)
        switch PriceFileReader.read(destination) {
        case .missing:
            guard before == nil else { throw Failure.destinationChanged }
        case .unreadable:
            throw Failure.unreadableInstalledTable
        case .bytes(let existing):
            guard before != nil else { throw Failure.destinationChanged }
            try preservePrices(in: PriceTable.decode(existing), with: candidate)
        }
        let staging = ".pricing-" + UUID().uuidString
        let file = openat(fd, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard file >= 0 else { throw Failure.stagingFailed }
        defer { _ = unlinkat(fd, staging, 0) }
        let writer = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        defer { try? writer.close() }
        try writer.write(contentsOf: bytes)
        try writer.synchronize()
        guard try fileIdentity(at: fd, name: name) == before else { throw Failure.destinationChanged }
        guard renameat(fd, staging, fd, name) == 0 else { throw Failure.stagingFailed }
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let seconds: Int
        let nanos: Int
    }

    private static func fileIdentity(at fd: Int32, name: String) throws -> Identity? {
        var value = stat()
        if fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw Failure.invalidDestination
        }
        guard value.st_mode & S_IFMT == S_IFREG else { throw Failure.invalidDestination }
        return .init(device: value.st_dev, inode: value.st_ino, size: value.st_size,
                     seconds: value.st_mtimespec.tv_sec, nanos: value.st_mtimespec.tv_nsec)
    }

    private static func requireDirectoryOrMissing(_ url: URL) throws {
        var value = stat()
        if lstat(url.path(percentEncoded: false), &value) == 0 {
            guard value.st_mode & S_IFMT == S_IFDIR else { throw Failure.invalidDestination }
        } else if errno != ENOENT {
            throw Failure.invalidDestination
        }
    }
}
