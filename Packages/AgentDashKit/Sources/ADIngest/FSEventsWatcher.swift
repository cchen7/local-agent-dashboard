import CoreServices
import Darwin
import Dispatch
import Foundation

/// SPEC §7 / SEC-3 / SEC-8: one live FSEvents stream for one authorized root.
/// Own one watcher per root. This primitive does not discover sources, obtain
/// permission, read files, schedule work, or follow a renamed root.
public final class FSEventsWatcher: Sendable {
    /// Advisory hints for the ingest coordinator. Keep file identifiers private.
    public enum Signal: Equatable, Sendable {
        /// A file event under this root. Not authorization to open the path.
        case fileChanged(relativePath: String)
        /// Loss, coalescing or a change that cannot be attributed to one file.
        /// The coordinator must revalidate access and rescan.
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
        let state = StreamState(path: path, onChange: onChange)
        try state.start()
        self.state = state
    }

    /// Stop, invalidate and release the stream. Idempotent and safe from inside
    /// the callback. Outside a callback, waits for an in-flight delivery to finish;
    /// no new callback can begin after this returns. A cancelled watcher is final.
    public func cancel() { state.cancel() }

    deinit { state.cancel() }

    // Internal so loss/root and malformed paths can be tested without inducing
    // kernel overload or touching any real source hierarchy.
    static func signals(rootPath: String, flags: UnsafeBufferPointer<FSEventStreamEventFlags>,
                        pathAt: (Int) -> String?) -> [Signal] {
        let fileFlags = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemIsFile | kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            | kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod
            | kFSEventStreamEventFlagItemFinderInfoMod | kFSEventStreamEventFlagItemChangeOwner
            | kFSEventStreamEventFlagItemXattrMod | kFSEventStreamEventFlagItemIsHardlink
            | kFSEventStreamEventFlagItemIsLastHardlink | kFSEventStreamEventFlagOwnEvent)
        let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
        let prefix = rootPath == "/" ? rootPath.utf8 : (rootPath + "/").utf8
        var result: [Signal] = []
        var seen = Set<String>()
        for (index, flag) in flags.enumerated() {
            // Any lost/coalesced/root/directory/unknown event takes precedence
            // over precise hints in this callback.
            guard flag & file != 0, flag & ~fileFlags == 0,
                  let path = pathAt(index), path.utf8.starts(with: prefix) else {
                return [.rescanRequired]
            }
            let relative = path.utf8.dropFirst(prefix.count)
            let components = relative.split(separator: 0x2F, omittingEmptySubsequences: false)
            guard !components.isEmpty, components.allSatisfy({
                !$0.isEmpty && !$0.contains(0) && !$0.elementsEqual([0x2E]) && !$0.elementsEqual([0x2E, 0x2E])
            }) else { return [.rescanRequired] }
            let identifier = String(decoding: relative, as: UTF8.self)
            if seen.insert(identifier).inserted { result.append(.fileChanged(relativePath: identifier)) }
        }
        return result
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
        // Match the native stream's spelling when an ancestor is an alias
        // such as /var → /private/var. Never resolve a delivered event path.
        guard let resolved = realpath(directory, nil) else { throw Failure.rootUnavailable }
        defer { free(resolved) }
        guard let canonical = String(validatingCString: resolved) else { throw Failure.invalidRoot }
        return canonical
    }
}

/// All mutable state and stream operations are confined to `queue`. The C
/// context retains this state until FSEvents releases it, including late native
/// cleanup. It does not retain the public watcher; watcher deinit breaks the
/// state/stream ownership cycle. cancel also releases the client's captures.
private final class StreamState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.agentdashboard.ingest.fsevents", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let path: String
    private var stream: FSEventStreamRef?
    private var onChange: (@Sendable (FSEventsWatcher.Signal) -> Void)?

    init(path: String, onChange: @escaping @Sendable (FSEventsWatcher.Signal) -> Void) {
        self.path = path
        self.onChange = onChange
        queue.setSpecific(key: queueKey, value: true)
    }

    func start() throws {
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
                { _, info, count, paths, flags, _ in
                    guard let info else { return }
                    let state = Unmanaged<StreamState>.fromOpaque(info).takeUnretainedValue()
                    // Without UseCFTypes, paths is a callback-owned C string array.
                    let strings = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    let signals = FSEventsWatcher.signals(rootPath: state.path,
                        flags: UnsafeBufferPointer(start: flags, count: count)) {
                        strings[$0].flatMap { String(validatingCString: $0) }
                    }
                    for signal in signals { state.onChange?(signal) }
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
