import ADCore
import Foundation

/// Frozen v2 projection used only during an in-place v2 replay. Prove that
/// the old decoder lost this record before removing a path-based placeholder:
/// the same path and sequence can also have a retained row from a prior rewrite.
struct ClaudeV2OversizedJSON {
    private static let stringLimit = 16 * 1024 // Enough for 2 KiB even with JSON escapes.
    private static let structureLimit = 1024 * 1024
    private static let previewKeys = [Array("content".utf8), Array("text".utf8)]

    private var compact = Data()
    private var stringBytes: [UInt8] = []
    private var inString = false
    private var allowsPreview = false
    private var clipped = false
    private var escape = 0 // -1 after a backslash; 1...4 hex digits still expected.
    private var previewKey = false
    private var previewValue = false

    static func lostRecord(from frame: JSONLFrame) throws -> Bool {
        guard let readOverflow = frame.readOverflow else { return false }
        var scanner = Self()
        guard scanner.append(frame.bytes) else { return true }
        var offset: Int64 = 0
        while true {
            let chunk = try readOverflow(offset, 64 * 1024)
            if chunk.isEmpty { break }
            guard scanner.append(chunk) else { return true }
            offset += Int64(chunk.count)
        }
        guard !scanner.inString else { return true }
        return (try? JSONSerialization.jsonObject(with: scanner.compact)) as? [String: Any] == nil
    }

    private mutating func append(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            for byte in bytes {
                if inString {
                    if escape == 0 && byte == 0x22 {
                        guard closeString() else { return false }
                        continue
                    }
                    guard byte >= 0x20 else { return false }
                    switch escape {
                    case -1:
                        switch byte {
                        case 0x75: escape = 4 // u
                        case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: escape = 0
                        default: return false
                        }
                    case 1...4:
                        switch byte {
                        case 0x30...0x39, 0x41...0x46, 0x61...0x66: escape -= 1
                        default: return false
                        }
                    default:
                        if byte == 0x5C { escape = -1 }
                    }
                    if stringBytes.count < Self.stringLimit {
                        stringBytes.append(byte)
                    } else {
                        guard allowsPreview else { return false }
                        clipped = true
                    }
                    continue
                }

                if byte == 0x22 {
                    inString = true
                    allowsPreview = previewValue
                    previewKey = false
                    previewValue = false
                } else {
                    if byte != 0x20 && byte != 0x09 && byte != 0x0D && byte != 0x0A {
                        previewValue = byte == 0x3A && previewKey // colon after a known key
                        previewKey = false
                    }
                    guard compact.count < Self.structureLimit else { return false }
                    compact.append(byte)
                }
            }
            return true
        }
    }

    private mutating func closeString() -> Bool {
        if clipped {
            // The retained raw bytes can end inside UTF-8 or an escaped
            // surrogate pair. Remove only that incomplete suffix.
            guard let length = Self.completeStringPrefix(stringBytes) else { return false }
            stringBytes.removeLast(stringBytes.count - length)
        }
        guard compact.count + stringBytes.count + 2 <= Self.structureLimit else { return false }
        compact.append(0x22)
        compact.append(contentsOf: stringBytes)
        compact.append(0x22)
        previewKey = !clipped && Self.previewKeys.contains(stringBytes)
        stringBytes.removeAll(keepingCapacity: true)
        inString = false
        clipped = false
        return true
    }

    private static func completeStringPrefix(_ bytes: [UInt8]) -> Int? {
        // The longest JSON encoding of one scalar is two six-byte escapes.
        for drop in 0...min(12, bytes.count) {
            var candidate = Data([0x5B, 0x22])
            candidate.append(contentsOf: bytes.dropLast(drop))
            candidate.append(contentsOf: [0x22, 0x5D])
            if (try? JSONSerialization.jsonObject(with: candidate)) != nil { return bytes.count - drop }
        }
        return nil
    }
}
