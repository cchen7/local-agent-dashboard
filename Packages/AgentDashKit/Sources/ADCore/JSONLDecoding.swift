import Foundation

/// One complete physical line. Offsets include its LF (or CRLF), while bytes
/// exclude the terminator. Oversized lines carry a bounded prefix.
public struct JSONLFrame: Sendable {
    public let bytes: Data
    public let isTruncated: Bool
    public let endOffset: Int64
    public let sequence: Int64

    public init(bytes: Data, isTruncated: Bool, endOffset: Int64, sequence: Int64) {
        self.bytes = bytes
        self.isTruncated = isTruncated
        self.endOffset = endOffset
        self.sequence = sequence
    }
}

public struct JSONLDecodeContext: Sendable {
    public let fileID: Int64
    public let previousTimestamp: Int64?
    public let state: Data?

    public init(fileID: Int64, previousTimestamp: Int64?, state: Data?) {
        self.fileID = fileID
        self.previousTimestamp = previousTimestamp
        self.state = state
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

    public init(records: [NormalizedRecord] = [], timestamp: Int64? = nil,
                state: Data? = nil, isUnknown: Bool = false) {
        self.records = records
        self.timestamp = timestamp
        self.state = state
        self.isUnknown = isUnknown
    }
}
