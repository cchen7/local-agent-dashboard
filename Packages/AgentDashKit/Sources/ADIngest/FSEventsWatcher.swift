import CoreServices
import Darwin
import Dispatch
import Foundation

/// SPEC §7 / SEC-3 / SEC-8: one live FSEvents stream for one authorized root.
/// Own one watcher per root. This primitive does not discover sources, obtain
/// permission, read files, schedule work, or follow a renamed root.
public final class FSEventsWatcher: Sendable {
    /// Root-level hints only. Native callback paths and event IDs are discarded.
    public enum Signal: Equatable, Sendable {
        /// Something changed; file-level flags are advisory, so nothing is filtered.
        case changed
        /// Events were lost/coalesced, or the root/volume changed. The coordinator
        /// must revalidate access and rescan; this watcher never restarts itself.
        case rescanRequired
    }

    /// Categories only: no path, source content or underlying error is attached.
    public enum Failure: Error, Equatable, Sendable {
        case invalidRoot, rootUnavailable, streamCreationFailed, streamStartFailed
    }

    private let state: StreamState

    /// Start watching an explicit, already-authorized local directory, from now.
    /// The caller owns any security-scoped access and must keep it alive until
    /// cancellation. The root must exist and must not itself be a symbolic link.
    /// Start the watcher before the initial scan to avoid a scan/watch gap.
    ///
    /// Delivery is serial on a private utility queue, with 0.4 s native latency
    /// (not a delivery deadline). Return promptly and keep the signal private.
    /// Capture the watcher weakly if the callback needs to refer to its owner.
    public init(authorizedRoot: URL, onChange: @escaping @Sendable (Signal) -> Void) throws {
        let path = try Self.validatedPath(authorizedRoot)
        let state = StreamState(onChange: onChange)
        try state.start(path: path)
        self.state = state
    }

    /// Stop, invalidate and release the stream. Idempotent and safe from inside
    /// the callback. Outside a callback, waits for an in-flight delivery to finish;
    /// no new callback can begin after this returns. A cancelled watcher is final.
    public func cancel() { state.cancel() }

    deinit { state.cancel() }

    // Internal so the rare loss/root flags can be tested without inducing actual
    // kernel overload, changing mounts, or touching any real source hierarchy.
    static func signal(for flags: UnsafeBufferPointer<FSEventStreamEventFlags>) -> Signal? {
        guard !flags.isEmpty else { return nil }
        let rescanMask = FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagMount
            | kFSEventStreamEventFlagUnmount)
        return flags.contains(where: { $0 & rescanMask != 0 }) ? .rescanRequired : .changed
    }

    private static func validatedPath(_ root: URL) throws -> String {
        let path = root.path(percentEncoded: false)
        let host = root.host(percentEncoded: false)?.lowercased()
        guard root.isFileURL, host == nil || host == "" || host == "localhost",
              path.hasPrefix("/"), !path.utf8.contains(0),
              !path.utf8.split(separator: 0x2F).contains(where: {
                  $0.elementsEqual([0x2E]) || $0.elementsEqual([0x2E, 0x2E])
              }) else { throw Failure.invalidRoot }

        // A trailing slash can force traversal of a final symlink before lstat.
        var bytes = Array(path.utf8)
        while bytes.count > 1 && bytes.last == 0x2F { bytes.removeLast() }
        let directory = String(decoding: bytes, as: UTF8.self)
        var status = stat()
        guard lstat(directory, &status) == 0, status.st_mode & S_IFMT == S_IFDIR else {
            throw Failure.rootUnavailable
        }
        return directory
    }
}

/// All mutable state and stream operations are confined to `queue`. The C
/// context retains this state until FSEvents releases it, including late native
/// cleanup. It does not retain the public watcher; watcher deinit breaks the
/// state/stream ownership cycle. cancel also releases the client's captures.
private final class StreamState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agentdashboard.ingest.fsevents", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var stream: FSEventStreamRef?
    private var onChange: (@Sendable (FSEventsWatcher.Signal) -> Void)?

    init(onChange: @escaping @Sendable (FSEventsWatcher.Signal) -> Void) {
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    func start(path: String) throws {
        try queue.sync {
            var context = FSEventStreamContext(
                version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                retain: { info in
                    guard let info else { return nil }
                    _ = Unmanaged<StreamState>.fromOpaque(info).retain()
                    return info
                },
                release: { info in
                    guard let info else { return }
                    Unmanaged<StreamState>.fromOpaque(info).release()
                }, copyDescription: nil)
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, _, flags, _ in
                    guard let info else { return }
                    let state = Unmanaged<StreamState>.fromOpaque(info).takeUnretainedValue()
                    // Never inspect or retain the native path/content arguments.
                    if let signal = FSEventsWatcher.signal(for: UnsafeBufferPointer(start: flags, count: count)) {
                        state.onChange?(signal)
                    }
                },
                &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.4, flags) else { throw FSEventsWatcher.Failure.streamCreationFailed }
            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                // Stop is only valid for a successfully started stream.
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                throw FSEventsWatcher.Failure.streamStartFailed
            }
            stream = created
        }
    }

    func cancel() {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            tearDown()
        } else {
            queue.sync { tearDown() }
        }
    }

    private func tearDown() {
        onChange = nil
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
