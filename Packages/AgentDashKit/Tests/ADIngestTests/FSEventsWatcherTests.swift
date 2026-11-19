import CoreServices
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import ADIngest

@Suite("SEC-3 / SEC-8 / SPEC §7: authorized-root FSEvents", .serialized)
struct FSEventsWatcherTests {
    @Test("Loss, coalescing and root/volume changes require a full rescan", arguments: [
        kFSEventStreamEventFlagMustScanSubDirs,
        kFSEventStreamEventFlagUserDropped,
        kFSEventStreamEventFlagKernelDropped,
        kFSEventStreamEventFlagEventIdsWrapped,
        kFSEventStreamEventFlagRootChanged,
        kFSEventStreamEventFlagMount,
        kFSEventStreamEventFlagUnmount
    ])
    func rescanFlags(_ flag: Int) {
        // Check a standalone flag as well as a mixed batch. No path is needed,
        // including for RootChanged (whose native event ID is zero).
        for flags in [[UInt32(flag)], [UInt32(kFSEventStreamEventFlagItemModified), UInt32(flag)]] {
            flags.withUnsafeBufferPointer { buffer in
                #expect(FSEventsWatcher.signal(for: buffer) == .rescanRequired)
            }
        }
    }

    @Test("All ordinary and unknown event kinds invalidate the root; empty batches do not")
    func conservativeSignals() {
        for flag in [kFSEventStreamEventFlagNone, kFSEventStreamEventFlagItemCreated,
                     kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemRemoved,
                     kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsDir,
                     Int(0x80000000)] {
            [UInt32(flag)].withUnsafeBufferPointer { buffer in
                #expect(FSEventsWatcher.signal(for: buffer) == .changed)
            }
        }
        [FSEventStreamEventFlags]().withUnsafeBufferPointer { buffer in
            #expect(FSEventsWatcher.signal(for: buffer) == nil)
        }
    }

    @Test("Only an explicit local directory root is accepted")
    func invalidRoots() throws {
        try withSyntheticRoot { root in
            let file = root.appendingPathComponent("regular-file")
            try Data([1]).write(to: file)
            let link = root.appendingPathComponent("directory-link", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            for url in [file, link, root.appendingPathComponent("missing", isDirectory: true)] {
                #expect(throws: FSEventsWatcher.Failure.rootUnavailable) {
                    try FSEventsWatcher(authorizedRoot: url) { _ in }
                }
            }
            let malformed = [
                URL(string: "https://example.invalid/synthetic")!,
                URL(string: "file://remote.invalid/synthetic")!,
                URL(fileURLWithPath: root.path + "/../escape"),
                URL(fileURLWithPath: root.path + "/./dot"),
                URL(fileURLWithPath: root.path + "/nul\0suffix")
            ]
            for url in malformed {
                #expect(throws: FSEventsWatcher.Failure.invalidRoot) {
                    try FSEventsWatcher(authorizedRoot: url) { _ in }
                }
            }
        }
    }

    @Test("A file notification wait expires without hanging")
    func boundedWait() throws {
        try withSyntheticRoot { root in
            let recorder = SignalRecorder()
            let watcher = try FSEventsWatcher(authorizedRoot: root, onChange: recorder.record)
            defer { watcher.cancel() }
            try #require(recorder.waitForQuiet())
            #expect(!recorder.wait(after: recorder.count, timeout: 0.15))
        }
    }

    @Test("Observe a real synthetic append, then cancel and observe no further callbacks")
    func appendAndCancel() throws {
        try withSyntheticRoot { root in
            let nested = root.appendingPathComponent("目录", isDirectory: true)
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
            let file = nested.appendingPathComponent("synthetic.jsonl")
            try Data("seed\n".utf8).write(to: file)
            let recorder = SignalRecorder()
            let watcher = try FSEventsWatcher(authorizedRoot: root, onChange: recorder.record)
            defer { watcher.cancel() }
            try #require(recorder.waitForQuiet())
            let baseline = recorder.count
            try append(Data("append\n".utf8), to: file)
            try #require(recorder.wait(after: baseline, timeout: 5))
            #expect(try Data(contentsOf: file) == Data("seed\nappend\n".utf8))

            let cancelled = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                watcher.cancel()
                watcher.cancel() // Idempotent.
                cancelled.signal()
            }
            try #require(cancelled.wait(timeout: .now() + 3) == .success)
            let stoppedCount = recorder.count
            try append(Data("after-cancel\n".utf8), to: file)
            #expect(!recorder.wait(after: stoppedCount, timeout: 1.2))
        }
    }

    @Test("Renaming the synthetic root emits rescanRequired")
    func rootRename() throws {
        try withSyntheticRoot { scratch in
            let root = scratch.appendingPathComponent("watched", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let recorder = SignalRecorder()
            let watcher = try FSEventsWatcher(authorizedRoot: root, onChange: recorder.record)
            defer { watcher.cancel() }
            try #require(recorder.waitForQuiet())
            let baseline = recorder.count
            try FileManager.default.moveItem(at: root, to: scratch.appendingPathComponent("renamed"))
            #expect(recorder.wait(after: baseline, matching: .rescanRequired, timeout: 5))
        }
    }

    @Test("Cancellation is safe from inside the delivery callback")
    func reentrantCancellation() throws {
        try withSyntheticRoot { root in
            let file = root.appendingPathComponent("synthetic")
            try Data([1]).write(to: file)
            let reference = Mutex<FSEventsWatcher?>(nil)
            let cancelled = DispatchSemaphore(value: 0)
            let watcher = try FSEventsWatcher(authorizedRoot: root) { _ in
                guard let watcher = reference.withLock({ $0 }) else { return }
                watcher.cancel()
                cancelled.signal()
            }
            reference.withLock { $0 = watcher }
            defer {
                watcher.cancel()
                reference.withLock { $0 = nil }
            }
            try append(Data([2]), to: file)
            #expect(cancelled.wait(timeout: .now() + 5) == .success)
        }
    }

    @Test("External cancellation waits for an in-flight callback before returning")
    func inFlightCancellation() throws {
        try withSyntheticRoot { root in
            let file = root.appendingPathComponent("synthetic")
            try Data([1]).write(to: file)
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let cancelled = DispatchSemaphore(value: 0)
            let blockOnce = Mutex(true)
            let watcher = try FSEventsWatcher(authorizedRoot: root) { _ in
                guard blockOnce.withLock({ value in
                    let shouldBlock = value
                    value = false
                    return shouldBlock
                }) else { return }
                entered.signal()
                // Bounded even if the test fails before releasing this callback.
                #expect(release.wait(timeout: .now() + 3) == .success)
            }
            defer {
                release.signal()
                watcher.cancel()
            }
            try append(Data([2]), to: file)
            try #require(entered.wait(timeout: .now() + 5) == .success)
            DispatchQueue.global().async {
                watcher.cancel()
                cancelled.signal()
            }
            #expect(cancelled.wait(timeout: .now() + 0.15) == .timedOut)
            release.signal()
            #expect(cancelled.wait(timeout: .now() + 3) == .success)
        }
    }

    @Test("Releasing the watcher tears down its stream and releases callback captures")
    func deinitTeardown() throws {
        try withSyntheticRoot { root in
            let recorder = SignalRecorder()
            let file = root.appendingPathComponent("synthetic")
            try Data([1]).write(to: file)
            var watcher: FSEventsWatcher?
            weak var releasedWatcher: FSEventsWatcher?
            weak var releasedCapture: LifetimeProbe?
            do {
                let capture = LifetimeProbe()
                releasedCapture = capture
                watcher = try FSEventsWatcher(authorizedRoot: root) { [capture] signal in
                    withExtendedLifetime(capture) { recorder.record(signal) }
                }
                releasedWatcher = watcher
            }
            try #require(releasedCapture != nil)
            watcher = nil
            #expect(releasedWatcher == nil)
            #expect(releasedCapture == nil)
            let stoppedCount = recorder.count
            try append(Data([2]), to: file)
            #expect(!recorder.wait(after: stoppedCount, timeout: 1.2))
        }
    }

    @Test("Cancelling one authorized root leaves a second root observing appends")
    func independentRoots() throws {
        try withSyntheticRoot { scratch in
            let roots = ["first", "second"].map { scratch.appendingPathComponent($0, isDirectory: true) }
            for root in roots {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
                try Data([1]).write(to: root.appendingPathComponent("synthetic"))
            }
            let first = SignalRecorder(), second = SignalRecorder()
            let firstWatcher = try FSEventsWatcher(authorizedRoot: roots[0], onChange: first.record)
            defer { firstWatcher.cancel() }
            let secondWatcher = try FSEventsWatcher(authorizedRoot: roots[1], onChange: second.record)
            defer { secondWatcher.cancel() }
            try #require(first.waitForQuiet() && second.waitForQuiet())
            firstWatcher.cancel()
            let firstCount = first.count, secondCount = second.count
            try append(Data([2]), to: roots[0].appendingPathComponent("synthetic"))
            try append(Data([2]), to: roots[1].appendingPathComponent("synthetic"))
            #expect(second.wait(after: secondCount, timeout: 5))
            #expect(!first.wait(after: firstCount, timeout: 1.2))
        }
    }
}

private final class LifetimeProbe: Sendable {}

/// Synthetic notifications only. Every wait has a deadline, including quiescence.
private final class SignalRecorder: @unchecked Sendable {
    private let condition = NSCondition()
    private var signals: [FSEventsWatcher.Signal] = []

    var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return signals.count
    }

    func record(_ signal: FSEventsWatcher.Signal) {
        condition.lock()
        defer { condition.unlock() }
        signals.append(signal)
        condition.broadcast()
    }

    func wait(after count: Int, matching: FSEventsWatcher.Signal? = nil, timeout: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !signals.dropFirst(count).contains(where: { matching == nil || $0 == matching }) {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func waitForQuiet() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(4)
        var baseline = signals.count
        var quietUntil = Date().addingTimeInterval(0.8)
        while Date() < deadline {
            _ = condition.wait(until: min(quietUntil, deadline))
            if signals.count != baseline {
                baseline = signals.count
                quietUntil = Date().addingTimeInterval(0.8)
            }
            if Date() >= quietUntil { return true }
        }
        return false
    }
}

private func withSyntheticRoot(_ body: (URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdash-watcher-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try body(root)
}

private func append(_ bytes: Data, to file: URL) throws {
    let writer = try FileHandle(forWritingTo: file)
    defer { try? writer.close() }
    try writer.seekToEnd()
    try writer.write(contentsOf: bytes)
    try writer.synchronize()
}
