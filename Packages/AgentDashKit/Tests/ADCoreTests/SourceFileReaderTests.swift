import Darwin
import Dispatch
import Foundation
import Testing
import ADCore

@Suite("SEC-3 / ADP-2: read-only source descriptors")
struct SourceFileReaderTests {
    @Test("Positioned byte reads are bounded and do not advance a shared cursor")
    func positionedReads() throws {
        try withSyntheticSource { root in
            let directory = root.appendingPathComponent("目录", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([0, 1, 2, 3, 255, 10]).write(to: directory.appendingPathComponent("bytes"))
            let reader = try SourceFileReader(root: root, relativePath: "目录/bytes")

            #expect(try reader.read(upToCount: 3, offset: 2) == Data([2, 3, 255]))
            #expect(try reader.read(upToCount: 3, offset: 2) == Data([2, 3, 255]))
            #expect(try reader.read(upToCount: 20, offset: 4) == Data([255, 10]))
            #expect(try reader.read(upToCount: 1, offset: 6).isEmpty)
            #expect(try reader.read(upToCount: 1, offset: 100).isEmpty)
            #expect(try reader.read(upToCount: 0, offset: 0).isEmpty)
        }
    }

    @Test("Even an Int.max request allocates and reads at most 1 MiB")
    func boundedReads() throws {
        try withSyntheticSource { root in
            let bound = 1_048_576
            try Data(repeating: 42, count: bound + 17).write(to: root.appendingPathComponent("large"))
            let reader = try SourceFileReader(root: root, relativePath: "large")
            #expect(try reader.read(upToCount: Int.max, offset: 0) == Data(repeating: 42, count: bound))
            #expect(try reader.read(upToCount: Int.max, offset: Int64(bound)) == Data(repeating: 42, count: 17))
        }
    }

    @Test("Invalid read ranges fail without integer overflow")
    func invalidReadRanges() throws {
        try withSyntheticSource { root in
            try Data().write(to: root.appendingPathComponent("empty"))
            let reader = try SourceFileReader(root: root, relativePath: "empty")
            for (count, offset): (Int, Int64) in [(-1, 0), (Int.min, 0), (1, -1), (0, Int64.min), (1, Int64.max)] {
                #expect(throws: SourceFileReader.Failure.invalidReadRange) {
                    try reader.read(upToCount: count, offset: offset)
                }
            }
            #expect(try reader.read(upToCount: 1, offset: 0).isEmpty)
        }
    }

    @Test("Snapshot uses descriptor identity, byte size and integer nanoseconds")
    func descriptorMetadata() throws {
        try withSyntheticSource { root in
            let file = root.appendingPathComponent("metadata")
            try Data([1, 2, 3]).write(to: file)
            let times = [timespec(tv_sec: 1_700_000_000, tv_nsec: 0),
                         timespec(tv_sec: 1_700_000_001, tv_nsec: 123_456_789)]
            try #require(utimensat(AT_FDCWD, file.path, times, 0) == 0)
            var before = stat()
            try #require(lstat(file.path, &before) == 0)
            let reader = try SourceFileReader(root: root, relativePath: "metadata")
            let snapshot: SourceFileReader.Snapshot = try reader.snapshot()
            #expect(snapshot.device == Int64(before.st_dev))
            #expect(snapshot.inode == Int64(bitPattern: before.st_ino))
            #expect(snapshot.size == 3)
            #expect(snapshot.modificationTimeNS == 1_700_000_001_123_456_789)
            #expect(try reader.read(upToCount: 10, offset: 0) == Data([1, 2, 3]))

            var after = stat()
            try #require(lstat(file.path, &after) == 0)
            #expect(after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec)
            #expect(after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec)
            #expect(after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec)
            #expect(after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec)
            #expect(try reader.snapshot() == snapshot)
        }
    }

    @Test("An existing descriptor observes synthetic appends and truncation")
    func changedFileSize() throws {
        try withSyntheticSource { root in
            let file = root.appendingPathComponent("changing")
            try Data([1, 2, 3]).write(to: file)
            let reader = try SourceFileReader(root: root, relativePath: "changing")
            let initial = try reader.snapshot()
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            try writer.seekToEnd()
            try writer.write(contentsOf: Data([4, 5]))
            #expect(try reader.snapshot().size == 5)
            #expect(try reader.read(upToCount: 10, offset: 3) == Data([4, 5]))
            try writer.truncate(atOffset: 1)
            #expect(try reader.snapshot().size == 1)
            #expect(try reader.snapshot().inode == initial.inode)
            #expect(try reader.read(upToCount: 10, offset: 0) == Data([1]))
            #expect(try reader.read(upToCount: 10, offset: 3).isEmpty)
        }
    }

    @Test("Renaming directories and replacing or unlinking a path cannot retarget an open reader")
    func pinnedFile() throws {
        try withSyntheticSource { root in
            let nested = root.appendingPathComponent("nested", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data([1, 2, 3]).write(to: nested.appendingPathComponent("file"))
            let reader = try SourceFileReader(root: root, relativePath: "nested/file")
            let initial = try reader.snapshot()
            let moved = root.appendingPathComponent("moved", isDirectory: true)
            try FileManager.default.moveItem(at: nested, to: moved)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            try Data([9]).write(to: nested.appendingPathComponent("file"))
            let replacement = try SourceFileReader(root: root, relativePath: "nested/file")
            #expect(try replacement.snapshot().inode != initial.inode)
            #expect(try replacement.read(upToCount: 10, offset: 0) == Data([9]))
            try FileManager.default.removeItem(at: moved.appendingPathComponent("file"))
            #expect(try reader.snapshot() == initial)
            #expect(try reader.read(upToCount: 10, offset: 0) == Data([1, 2, 3]))
        }
    }

    @Test("Reject empty, absolute, traversal, dot and NUL components", arguments: [
        "", "/", "/file", "//file", ".", "..", "./file", "../file", "a/../file", "a/./file",
        "a//file", "a/", "a//", "file\0suffix", "a/\0/file"
    ])
    func invalidRelativePaths(_ path: String) throws {
        try withSyntheticSource { root in
            #expect(throws: SourceFileReader.Failure.invalidRelativePath) {
                try SourceFileReader(root: root, relativePath: path)
            }
        }
    }

    @Test("Reject final and intermediate symlinks, including a slash followed by a combining scalar")
    func symlinks() throws {
        try withSyntheticSource { root in
            let real = root.appendingPathComponent("real", isDirectory: true)
            try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
            try Data([1]).write(to: real.appendingPathComponent("file"))
            try Data([2]).write(to: real.appendingPathComponent("\u{301}file"))
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("linked").path,
                                                      withDestinationPath: real.path)
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("file-link").path,
                                                      withDestinationPath: real.appendingPathComponent("file").path)
            try FileManager.default.createSymbolicLink(atPath: real.appendingPathComponent("nested-link").path,
                                                      withDestinationPath: real.path)
            for path in ["file-link", "linked/file", "linked/\u{301}file", "real/nested-link/file"] {
                #expect(throws: SourceFileReader.Failure.openFailed) {
                    try SourceFileReader(root: root, relativePath: path)
                }
            }
        }
    }

    @Test("Root must be a local directory descriptor, never a symlink or regular file")
    func invalidRoots() throws {
        try withSyntheticSource { root in
            let link = root.appendingPathComponent("root-link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: root.path)
            let file = root.appendingPathComponent("file")
            try Data([1]).write(to: file)
            let directoryLink = URL(fileURLWithPath: link.path + "/", isDirectory: true)
            for invalidRoot in [link, directoryLink, file, root.appendingPathComponent("missing")] {
                #expect(throws: SourceFileReader.Failure.openFailed) {
                    try SourceFileReader(root: invalidRoot, relativePath: "file")
                }
            }
            let remoteURL = try #require(URL(string: "https://invalid.example/source"))
            let remoteFileURL = try #require(URL(string: "file://invalid.example/source"))
            let dotRoot = URL(fileURLWithPath: link.path + "/.", isDirectory: true)
            for invalidRoot in [remoteURL, remoteFileURL, dotRoot, URL(fileURLWithPath: root.path + "\0suffix")] {
                #expect(throws: SourceFileReader.Failure.invalidRoot) {
                    try SourceFileReader(root: invalidRoot, relativePath: "file")
                }
            }
        }
    }

    @Test("Reject directory leaves and non-directory intermediate components")
    func regularFilesOnly() throws {
        try withSyntheticSource { root in
            let directory = root.appendingPathComponent("directory", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([1]).write(to: root.appendingPathComponent("file"))
            #expect(throws: SourceFileReader.Failure.notRegularFile) {
                try SourceFileReader(root: root, relativePath: "directory")
            }
            #expect(throws: SourceFileReader.Failure.openFailed) {
                try SourceFileReader(root: root, relativePath: "file/child")
            }
        }
    }

    @Test("A FIFO with no writer fails promptly; a watchdog prevents a blocking-open regression from hanging")
    func fifoDoesNotHang() throws {
        try withSyntheticSource { root in
            let fifo = root.appendingPathComponent("fifo")
            try #require(mkfifo(fifo.path, 0o600) == 0)
            let rescue = DispatchWorkItem {
                let writer = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                if writer >= 0 { close(writer) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: rescue)
            defer { rescue.cancel() }
            let start = ContinuousClock.now
            #expect(throws: SourceFileReader.Failure.notRegularFile) {
                try SourceFileReader(root: root, relativePath: "fifo")
            }
            #expect(start.duration(to: .now) < .seconds(1))
            #expect(throws: SourceFileReader.Failure.openFailed) {
                try SourceFileReader(root: root, relativePath: "fifo/child")
            }
        }
    }

    @Test("Errors contain categories only, without source names, paths or underlying errors")
    func privateErrors() throws {
        try withSyntheticSource { root in
            do {
                _ = try SourceFileReader(root: root, relativePath: "synthetic-private-name")
                Issue.record("Expected opening a missing file to fail")
            } catch {
                #expect(error as? SourceFileReader.Failure == .openFailed)
                #expect(String(describing: error) == "openFailed")
                #expect(!String(reflecting: error).contains(root.path))
                #expect(!String(reflecting: error).contains("synthetic-private-name"))
                #expect(Mirror(reflecting: error).children.isEmpty)
            }
        }
    }

    @Test("Concurrent positioned reads share no mutable file cursor")
    func concurrentReads() async throws {
        let root = try makeSyntheticSource()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data((0..<256).map(UInt8.init))
        try bytes.write(to: root.appendingPathComponent("concurrent"))
        let reader = try SourceFileReader(root: root, relativePath: "concurrent")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for offset in 0..<64 {
                group.addTask {
                    let actual = try reader.read(upToCount: 16, offset: Int64(offset))
                    #expect(actual == bytes.subdata(in: offset..<(offset + 16)))
                }
            }
            try await group.waitForAll()
        }
    }
}

private func makeSyntheticSource() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SourceFileReaderTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    return root
}

private func withSyntheticSource(_ body: (URL) throws -> Void) throws {
    let root = try makeSyntheticSource()
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}
