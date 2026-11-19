import Foundation
import CZstd

/// Content-free failures from the SEC-4/ADP-CX decoder primitive.
public enum ZstdDecodingError: Error, Equatable, Sendable {
    case invalidConfiguration
    case allocationFailed
    case windowLimitExceeded
    case dictionaryRequired
    case corruptInput
    case truncatedFrame
    case streamClosed
}

/// Incremental, serial-use decoder. Supply compressed chunks with `write`, then
/// call `finish` at EOF. It does no I/O and retains no caller input or output.
///
/// Concatenated standard and skippable frames are accepted and counted. External
/// dictionaries are unsupported (zero dictionary bytes loaded); each frame's
/// window/history is limited to at most 8 MiB. Internal zstd block buffers add
/// bounded overhead beyond that window; this is not a total-allocation limit.
///
/// Output is provisional until `finish` succeeds: checksum or truncation errors
/// can follow already-emitted bytes. Consumers must handle partial output. This
/// type is intentionally not Sendable; use from one task, without reentrancy.
public final class ZstdStreamDecoder {
    /// Hard ceiling for the per-frame history window, in bytes.
    public static let windowSizeLimit = Int(ADZSTD_WINDOW_LIMIT)
    /// Hard ceiling for each emitted output chunk, in bytes.
    public static let maximumOutputChunkSize = Int(ADZSTD_OUTPUT_LIMIT)
    /// Completed frame boundaries, including empty and skippable frames.
    public private(set) var completedFrameCount = 0

    private enum State { case open, writing, closed }
    private let context: OpaquePointer
    private var output: [UInt8]
    private var state = State.open
    private var atFrameBoundary = false

    /// Creates a decoder with a window cap in 1024...8 MiB and an output chunk
    /// size in 1...128 KiB. No dictionary can be supplied or loaded.
    public init(maximumWindowSize: Int = windowSizeLimit, outputChunkSize: Int = 64 * 1024) throws {
        guard (1024...Self.windowSizeLimit).contains(maximumWindowSize),
              (1...Self.maximumOutputChunkSize).contains(outputChunkSize) else {
            throw ZstdDecodingError.invalidConfiguration
        }
        guard let context = ADZSTD_create(maximumWindowSize) else {
            throw ZstdDecodingError.allocationFailed
        }
        self.context = context
        self.output = [UInt8](repeating: 0, count: outputChunkSize)
    }

    deinit { ADZSTD_destroy(context) }

    /// Consumes the supplied chunk synchronously, invoking `emit` with nonempty
    /// owned chunks no larger than the configured output size. Empty input is a
    /// no-op. No queue or whole-file buffer is built; the callback applies back
    /// pressure. A native or consumer error closes the decoder permanently and
    /// is rethrown. Calls to `write` or `finish` inside `emit` are rejected.
    public func write(_ compressedChunk: Data, emit: (Data) throws -> Void) throws {
        guard state == .open else { throw ZstdDecodingError.streamClosed }
        state = .writing
        do {
            if !compressedChunk.isEmpty {
                try compressedChunk.withUnsafeBytes { source in
                    var offset = 0
                    var drain = false
                    repeat {
                        var consumed = 0
                        var produced = 0
                        let status = output.withUnsafeMutableBytes { destination in
                            ADZSTD_step(context, source.baseAddress?.advanced(by: offset),
                                        source.count - offset, &consumed,
                                        destination.baseAddress, destination.count, &produced)
                        }
                        switch status {
                        case ADZSTD_more, ADZSTD_frameComplete: break
                        case ADZSTD_windowLimitExceeded: throw ZstdDecodingError.windowLimitExceeded
                        case ADZSTD_dictionaryRequired: throw ZstdDecodingError.dictionaryRequired
                        case ADZSTD_allocationFailed: throw ZstdDecodingError.allocationFailed
                        default: throw ZstdDecodingError.corruptInput
                        }
                        offset += consumed
                        if status == ADZSTD_frameComplete {
                            completedFrameCount += 1
                            atFrameBoundary = true
                        } else if consumed > 0 || produced > 0 {
                            atFrameBoundary = false
                        }
                        if produced > 0 { try emit(Data(output.prefix(produced))) }

                        if status != ADZSTD_frameComplete && consumed == 0 && produced == 0 {
                            guard offset == source.count else { throw ZstdDecodingError.corruptInput }
                            break // Needs more input; don't spin on an incomplete frame.
                        }
                        drain = status != ADZSTD_frameComplete && produced == output.count
                    } while offset < source.count || drain
                }
            }
            state = .open
        } catch {
            state = .closed
            throw error
        }
    }

    /// Verifies EOF falls on a complete frame boundary and closes the decoder.
    /// Empty input, partial headers/payloads/checksums and a partial concatenated
    /// final frame all throw `truncatedFrame`. Cannot be called more than once.
    public func finish() throws {
        guard state == .open else { throw ZstdDecodingError.streamClosed }
        state = .closed
        guard atFrameBoundary && completedFrameCount > 0 else {
            throw ZstdDecodingError.truncatedFrame
        }
    }
}
