import ADAdapters
import ADCore
import ADStore
import Foundation

/// ADP-1…5. Categories only; never carry source paths or record bytes.
public enum JSONLImportFailure: Error, Equatable, Sendable {
    case invalidParserVersion, positionOverflow, sourceChanged, recordLimit, stateLimit
}

public struct JSONLImportResult: Equatable, Sendable {
    public let fileID: Int64
    public let checkpoint: Checkpoint
    public let completeLines: Int64
    public let bytesRead: Int64
}

public enum JSONLFileImporter {
    private static let chunkSize = 64 * 1024
    private static let prefixLimit = 1024 * 1024
    private static let batchLimit = 500
    private static let batchInterval: Duration = .milliseconds(200)

    /// Connect a discovered file to its adapter and the transactional store.
    @discardableResult
    public static func importFile<A: AgentAdapter>(_ file: SourceFile, from source: Source,
                                                   authorizedRoot: URL, store: AgentStore, adapter: A)
    throws -> JSONLImportResult {
        var versioned = file
        versioned.parserVersion = A.parserVersion
        var decoder = try adapter.makeDecoder(for: versioned, in: source)
        return try importFile(versioned, authorizedRoot: authorizedRoot, store: store) {
            try decoder.decode($0, context: $1)
        }
    }

    /// Import one discovered file beneath a root the caller already authorized.
    /// Run off the UI actor. Never pass an unverified watcher hint as a file.
    /// A decoder can mark malformed/truncated input unknown and continue.
    /// Files are assumed append-only between scans unless metadata shows a
    /// replacement, shrink, same-size rewrite or parser-version change.
    @discardableResult
    public static func importFile(_ file: SourceFile, authorizedRoot: URL, store: AgentStore,
                                  decode: (JSONLFrame, JSONLDecodeContext) throws -> DecodedJSONLFrame)
    throws -> JSONLImportResult {
        try importFile(file, authorizedRoot: authorizedRoot, store: store,
                       snapshot: { try $0.snapshot() }, decode: decode)
    }

    static func importFile(_ file: SourceFile, authorizedRoot: URL, store: AgentStore,
                           snapshot: (SourceFileReader) throws -> SourceFileReader.Snapshot,
                           decode: (JSONLFrame, JSONLDecodeContext) throws -> DecodedJSONLFrame)
    throws -> JSONLImportResult {
        guard file.parserVersion > 0 else { throw JSONLImportFailure.invalidParserVersion }
        try Task.checkCancellation()
        // The expected checkpoint must precede the source snapshot. Otherwise a
        // concurrent append can make older bytes look like a legitimate shrink.
        let fileID = try store.upsertFile(file, checkpoint: nil)
        var saved = try store.checkpoint(for: fileID)
        let reader = try SourceFileReader(root: authorizedRoot, relativePath: file.relativePath)
        let initial = try snapshot(reader)
        let sameFile = saved.flatMap { canReusePrefix($0, snapshot: initial) ? $0 : nil }
        let resume = sameFile.flatMap { $0.parserVersion == file.parserVersion ? $0 : nil }
        let replayedPrefix: JSONLDecodeContext.ReplayedPrefix? = sameFile.flatMap {
            guard $0.parserVersion < file.parserVersion, $0.offset > 0 else { return nil }
            return .init(parserVersion: $0.parserVersion, endOffset: $0.offset)
        }
        var next = Checkpoint(inode: initial.inode, size: initial.size, offset: resume?.offset ?? 0,
                              parserVersion: file.parserVersion, sequence: resume?.sequence ?? -1,
                              previousTimestamp: resume?.previousTimestamp, device: initial.device,
                              modificationTimeNS: initial.modificationTimeNS, decoderState: resume?.decoderState,
                              unknownRecords: resume?.unknownRecords ?? 0)
        var framer = JSONLFramer(offset: next.offset, sequence: next.sequence, prefixLimit: prefixLimit)
        let startingOffset = next.offset
        var readOffset = next.offset
        var lineStart = next.offset
        var lines: Int64 = 0
        var batchLines = 0
        var batch: [NormalizedRecord] = []
        var batchStarted = ContinuousClock.now

        func commit() throws {
            try Task.checkCancellation()
            guard next != saved || !batch.isEmpty else { return }
            let latest = try reader.snapshot()
            guard latest.size >= initial.size,
                  latest.size != initial.size || latest.modificationTimeNS == initial.modificationTimeNS
            else { throw JSONLImportFailure.sourceChanged }
            try store.commitFileBatch(batch, for: fileID, from: saved, to: next)
            saved = next
            batch.removeAll(keepingCapacity: true)
            batchLines = 0
            batchStarted = .now
        }

        while readOffset < initial.size {
            try Task.checkCancellation()
            let target = Int(min(Int64(chunkSize), initial.size - readOffset))
            let chunk = try reader.read(upToCount: target, offset: readOffset)
            guard chunk.count == target else { throw JSONLImportFailure.sourceChanged }
            try framer.push(chunk) { framed in
                try Task.checkCancellation()
                let line = framed.isTruncated ? withOverflow(framed, start: lineStart, reader: reader) : framed
                lineStart = line.endOffset
                let decoded = try decode(line, .init(fileID: fileID, previousTimestamp: next.previousTimestamp,
                                                     state: next.decoderState, replayedPrefix: replayedPrefix))
                guard decoded.records.count <= batchLimit else { throw JSONLImportFailure.recordLimit }
                guard (decoded.state?.count ?? 0) <= Checkpoint.maximumDecoderStateBytes
                else { throw JSONLImportFailure.stateLimit }
                if batch.count + decoded.records.count > batchLimit { try commit() }
                batch.append(contentsOf: decoded.records)
                next.offset = line.endOffset
                next.sequence = line.sequence
                next.previousTimestamp = decoded.timestamp ?? next.previousTimestamp
                next.decoderState = decoded.state
                if decoded.isUnknown || (line.isTruncated && !decoded.recoveredOversizedRecord) {
                    let (unknown, overflow) = next.unknownRecords.addingReportingOverflow(1)
                    guard !overflow else { throw JSONLImportFailure.positionOverflow }
                    next.unknownRecords = unknown
                }
                lines += 1
                batchLines += 1
                if batch.count >= batchLimit || batchLines >= batchLimit ||
                    batchStarted.duration(to: .now) >= batchInterval {
                    try commit()
                }
            }
            readOffset += Int64(chunk.count)
        }
        try commit()
        return .init(fileID: fileID, checkpoint: next, completeLines: lines, bytesRead: readOffset - startingOffset)
    }

    private static func withOverflow(_ frame: JSONLFrame, start: Int64, reader: SourceFileReader) -> JSONLFrame {
        let overflowStart = start + Int64(frame.bytes.count)
        let length = frame.endOffset - 1 - overflowStart // excludes LF
        return .init(bytes: frame.bytes, isTruncated: true, endOffset: frame.endOffset, sequence: frame.sequence) {
            offset, count in
            try Task.checkCancellation()
            guard offset >= 0, count >= 0 else { throw SourceFileReader.Failure.invalidReadRange }
            guard offset < length else { return Data() }
            let size = Int(min(Int64(count), Int64(chunkSize), length - offset))
            let data = try reader.read(upToCount: size, offset: overflowStart + offset)
            guard data.count == size else { throw JSONLImportFailure.sourceChanged }
            return data
        }
    }

    private static func canReusePrefix(_ checkpoint: Checkpoint, snapshot: SourceFileReader.Snapshot) -> Bool {
        checkpoint.device == snapshot.device && checkpoint.inode == snapshot.inode &&
            checkpoint.size <= snapshot.size &&
            checkpoint.offset >= 0 && checkpoint.offset <= checkpoint.size &&
            checkpoint.sequence >= -1 && checkpoint.unknownRecords >= 0 &&
            (checkpoint.decoderState?.count ?? 0) <= Checkpoint.maximumDecoderStateBytes &&
            (checkpoint.size != snapshot.size || checkpoint.modificationTimeNS == snapshot.modificationTimeNS)
    }
}
