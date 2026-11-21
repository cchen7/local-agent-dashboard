import ADCore
import Foundation

struct JSONLFramer {
    private let prefixLimit: Int
    private var offset: Int64
    private var sequence: Int64
    private var prefix = Data()
    private var truncated = false

    init(offset: Int64, sequence: Int64, prefixLimit: Int) {
        self.offset = offset
        self.sequence = sequence
        self.prefixLimit = prefixLimit
    }

    mutating func push(_ data: Data, yield: (JSONLFrame) throws -> Void) throws {
        let (end, overflow) = offset.addingReportingOverflow(Int64(data.count))
        guard !overflow else { throw JSONLImportFailure.positionOverflow }
        try data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            var start = 0
            for position in bytes.indices where bytes[position] == 0x0A {
                retain(bytes[start..<position])
                let (next, sequenceOverflow) = sequence.addingReportingOverflow(1)
                guard !sequenceOverflow else { throw JSONLImportFailure.positionOverflow }
                sequence = next
                if !truncated && prefix.last == 0x0D { prefix.removeLast() }
                try yield(.init(bytes: prefix, isTruncated: truncated,
                                endOffset: offset + Int64(position + 1), sequence: sequence))
                prefix.removeAll(keepingCapacity: true)
                truncated = false
                start = position + 1
            }
            retain(bytes[start..<bytes.count])
        }
        offset = end
    }

    private mutating func retain(_ bytes: UnsafeRawBufferPointer.SubSequence) {
        let count = min(bytes.count, prefixLimit - prefix.count)
        if count > 0 { prefix.append(contentsOf: bytes.prefix(count)) }
        if count < bytes.count { truncated = true }
    }
}
