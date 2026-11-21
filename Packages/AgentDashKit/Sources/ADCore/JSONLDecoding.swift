import Foundation

/// One complete physical line. Offsets include its LF (or CRLF), while bytes
/// exclude the terminator. Oversized lines carry a bounded prefix.
public struct JSONLFrame: Sendable {
    public let bytes: Data
    public let isTruncated: Bool
    public let endOffset: Int64
    public let sequence: Int64
    /// Optional access to the rest of this physical line, relative to the
    /// end of `bytes` and excluding LF. Reads never cross into the next line.
    public let readOverflow: (@Sendable (_ offset: Int64, _ count: Int) throws -> Data)?

    public init(bytes: Data, isTruncated: Bool, endOffset: Int64, sequence: Int64,
                readOverflow: (@Sendable (Int64, Int) throws -> Data)? = nil) {
        self.bytes = bytes
        self.isTruncated = isTruncated
        self.endOffset = endOffset
        self.sequence = sequence
        self.readOverflow = readOverflow
    }
}

public struct JSONLDecodeContext: Sendable {
    /// Previously committed bytes of the same source, now replayed with a newer parser.
    public struct ReplayedPrefix: Sendable {
        public let parserVersion: Int
        public let endOffset: Int64

        public init(parserVersion: Int, endOffset: Int64) {
            self.parserVersion = parserVersion
            self.endOffset = endOffset
        }
    }

    public let fileID: Int64
    public let previousTimestamp: Int64?
    public let state: Data?

    public let replayedPrefix: ReplayedPrefix?

    public init(fileID: Int64, previousTimestamp: Int64?, state: Data?, replayedPrefix: ReplayedPrefix? = nil) {
        self.fileID = fileID
        self.previousTimestamp = previousTimestamp
        self.state = state
        self.replayedPrefix = replayedPrefix
    }
}

/// The adapter owns normalized record identities and tolerant decoding.
/// A nil timestamp keeps the prior timestamp. Forward the state in the
/// input context when the resume data remains unchanged.
public struct DecodedJSONLFrame: Sendable {
    public let records: [NormalizedRecord]
    public let timestamp: Int64?
    public let state: Data?
    public let isUnknown: Bool
    /// A recognized record was recovered from a frame that exceeded the prefix limit.
    public let recoveredOversizedRecord: Bool

    public init(records: [NormalizedRecord] = [], timestamp: Int64? = nil,
                state: Data? = nil, isUnknown: Bool = false, recoveredOversizedRecord: Bool = false) {
        self.records = records
        self.timestamp = timestamp
        self.state = state
        self.isUnknown = isUnknown
        self.recoveredOversizedRecord = recoveredOversizedRecord
    }
}
