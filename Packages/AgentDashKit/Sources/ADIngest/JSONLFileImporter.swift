import ADAdapters
import ADCore
import ADStore
import ADZstd
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
                                                   authorizedRoot: URL, expectedRoot: SourceFileReader.DirectoryIdentity? = nil,
                                                   replay: Bool = false, store: AgentStore, adapter: A)
    throws -> JSONLImportResult {
        var versioned = file
        versioned.parserVersion = A.parserVersion
        return try retrying(replay: replay) { reread in
            var decoder = try adapter.makeDecoder(for: versioned, in: source)
            return try importAttempt(versioned, authorizedRoot: authorizedRoot, expectedRoot: expectedRoot,
                                     encoding: adapter.storageEncoding(for: versioned), replay: reread, store: store,
                                     snapshot: { try $0.snapshot() }) {
                try decoder.decode($0, context: $1)
            }
        }
    }

    /// Import one discovered file beneath a root the caller already authorized.
    /// Run off the UI actor. Never pass an unverified watcher hint as a file.
    /// A decoder can mark malformed/truncated input unknown and continue.
    /// Plain JSONL is append-only. A compressed file is an immutable snapshot:
    /// validate it fully before publishing any batches, and skip it after EOF
    /// only while its physical identity, size, mtime and parser match.
    @discardableResult
    public static func importFile(_ file: SourceFile, authorizedRoot: URL,
                                  expectedRoot: SourceFileReader.DirectoryIdentity? = nil,
                                  encoding: JSONLStorageEncoding = .plain, replay: Bool = false, store: AgentStore,
                                  decode: (JSONLFrame, JSONLDecodeContext) throws -> DecodedJSONLFrame)
    throws -> JSONLImportResult {
        try importFile(file, authorizedRoot: authorizedRoot, expectedRoot: expectedRoot, encoding: encoding,
                       replay: replay, store: store, snapshot: { try $0.snapshot() }, decode: decode)
    }

    static func importFile(_ file: SourceFile, authorizedRoot: URL,
                           expectedRoot: SourceFileReader.DirectoryIdentity? = nil,
                           encoding: JSONLStorageEncoding = .plain, replay: Bool = false, store: AgentStore,
                           snapshot: (SourceFileReader) throws -> SourceFileReader.Snapshot,
                           decode: (JSONLFrame, JSONLDecodeContext) throws -> DecodedJSONLFrame)
    throws -> JSONLImportResult {
        try retrying(replay: replay) { reread in
            try importAttempt(file, authorizedRoot: authorizedRoot, expectedRoot: expectedRoot, encoding: encoding,
                              replay: reread, store: store, snapshot: snapshot, decode: decode)
        }
    }

    private enum ImportControl: Error { case workspaceReplay }

    private static func retrying(replay: Bool, _ body: (Bool) throws -> JSONLImportResult) throws -> JSONLImportResult {
        var reread = replay
        while true {
            try Task.checkCancellation()
            do { return try body(reread) }
            catch ImportControl.workspaceReplay {
                // The writer committed a newly trusted workspace and removed
                // its deferred marker. Begin with a clean decoder on replay.
                reread = true
            }
        }
    }

    private static func importAttempt(_ file: SourceFile, authorizedRoot: URL,
                                      expectedRoot: SourceFileReader.DirectoryIdentity?, encoding: JSONLStorageEncoding,
                                      replay: Bool, store: AgentStore, snapshot: (SourceFileReader) throws -> SourceFileReader.Snapshot,
                                      decode: (JSONLFrame, JSONLDecodeContext) throws -> DecodedJSONLFrame) throws -> JSONLImportResult {
        guard file.parserVersion > 0 else { throw JSONLImportFailure.invalidParserVersion }
        try Task.checkCancellation()
        // The expected checkpoint must precede the source snapshot. Otherwise a
        // concurrent append can make older bytes look like a legitimate shrink.
        let fileID = try store.upsertFile(file, checkpoint: nil)
        let position = try store.fileImportPosition(for: fileID)
        var saved = position.checkpoint
        let reader = try SourceFileReader(root: authorizedRoot, relativePath: file.relativePath, expectedRoot: expectedRoot)
        let initial = try snapshot(reader)
        let sameFile = saved.flatMap { canReusePrefix($0, snapshot: initial) ? $0 : nil }
        let matched = replay ? nil : sameFile.flatMap {
            !$0.sourceFileWasMissing && $0.parserVersion == file.parserVersion ? $0 : nil
        }
        if encoding == .zstd {
            if let matched, matched.size == initial.size, matched.offset == initial.size {
                return .init(fileID: fileID, checkpoint: matched, completeLines: 0, bytesRead: 0)
            }
            // A corrupt frame can be discovered after provisional output.
            // Preflight the pinned descriptor without handing any records to the writer.
            try inflate(reader, size: initial.size) { _ in }
            guard try reader.snapshot() == initial else { throw JSONLImportFailure.sourceChanged }
        }
        let resume = encoding == .plain ? matched : nil
        // Compressed checkpoint offsets are physical bytes, not frame positions.
        // Never use them to reconcile a logical prefix or read a JSONL tail.
        let replayedPrefix: JSONLDecodeContext.ReplayedPrefix? = sameFile.flatMap {
            guard encoding == .plain, $0.parserVersion < file.parserVersion, $0.offset > 0 else { return nil }
            return .init(parserVersion: $0.parserVersion, endOffset: $0.offset)
        }
        var next = Checkpoint(inode: initial.inode, size: initial.size, offset: resume?.offset ?? 0,
                              parserVersion: file.parserVersion, sequence: resume?.sequence ?? -1,
                              previousTimestamp: resume?.previousTimestamp, device: initial.device,
                              modificationTimeNS: initial.modificationTimeNS, decoderState: resume?.decoderState,
                              unknownRecords: resume?.unknownRecords ?? 0)
        var framer = JSONLFramer(offset: next.offset, sequence: next.sequence, prefixLimit: prefixLimit)
        let startingOffset = next.offset
        var lineStart = startingOffset
        var lines: Int64 = 0
        var batchLines = 0
        var batch: [NormalizedRecord] = []
        var batchStarted = ContinuousClock.now

        func commit() throws {
            try Task.checkCancellation()
            guard next != saved || !batch.isEmpty else { return }
            let latest = try reader.snapshot()
            let unchanged = encoding == .zstd ? latest == initial :
                latest.size >= initial.size &&
                    (latest.size != initial.size || latest.modificationTimeNS == initial.modificationTimeNS)
            guard unchanged
            else { throw JSONLImportFailure.sourceChanged }
            let receipt = try store.commitFileBatch(batch, for: fileID, from: saved, to: next,
                                                    exclusionRevision: position.exclusionRevision)
            if receipt.needsWorkspaceReplay { throw ImportControl.workspaceReplay }
            saved = receipt.checkpoint
            batch.removeAll(keepingCapacity: true)
            batchLines = 0
            batchStarted = .now
        }

        func consume(_ chunk: Data) throws {
            try framer.push(chunk) { framed in
                try Task.checkCancellation()
                let line = encoding == .plain && framed.isTruncated
                    ? withOverflow(framed, start: lineStart, reader: reader) : framed
                lineStart = line.endOffset
                let decoded = try decode(line, .init(fileID: fileID, previousTimestamp: next.previousTimestamp,
                                                     state: next.decoderState, replayedPrefix: replayedPrefix))
                guard decoded.records.count <= batchLimit else { throw JSONLImportFailure.recordLimit }
                guard (decoded.state?.count ?? 0) <= Checkpoint.maximumDecoderStateBytes
                else { throw JSONLImportFailure.stateLimit }
                if batch.count + decoded.records.count > batchLimit { try commit() }
                batch.append(contentsOf: decoded.records)
                if encoding == .plain { next.offset = line.endOffset }
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
        }
        let bytesRead: Int64
        if encoding == .zstd {
            // Replay from the beginning after interruption; dedupe keys are stable.
            // Keep the physical cursor at zero until the immutable snapshot is complete.
            try inflate(reader, size: initial.size, emit: consume)
            next.offset = initial.size
            let (total, overflow) = initial.size.multipliedReportingOverflow(by: 2)
            bytesRead = overflow ? Int64.max : total
        } else {
            try readChunks(reader, size: initial.size, from: startingOffset, emit: consume)
            bytesRead = initial.size - startingOffset
        }
        try commit()
        return .init(fileID: fileID, checkpoint: saved ?? next, completeLines: lines, bytesRead: bytesRead)
    }

    private static func readChunks(_ reader: SourceFileReader, size: Int64, from start: Int64,
                                   emit: (Data) throws -> Void) throws {
        var offset = start
        while offset < size {
            try Task.checkCancellation()
            let target = Int(min(Int64(chunkSize), size - offset))
            let chunk = try reader.read(upToCount: target, offset: offset)
            guard chunk.count == target else { throw JSONLImportFailure.sourceChanged }
            try emit(chunk)
            offset += Int64(chunk.count)
        }
    }

    private static func inflate(_ reader: SourceFileReader, size: Int64,
                                emit: (Data) throws -> Void) throws {
        let decoder = try ZstdStreamDecoder()
        try readChunks(reader, size: size, from: 0) { compressed in
            try decoder.write(compressed) { plain in
                try Task.checkCancellation()
                try emit(plain)
            }
        }
        try decoder.finish()
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
