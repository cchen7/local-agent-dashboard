import ADCore
import Foundation

/// Project a large JSONL record without rebuilding it. Keep only the envelope,
/// tool result identities, and one 2 KiB preview per retained result.
enum ClaudeOversizedJSON {

    static func row(from frame: JSONLFrame, textLimit: Int = 2048, onlyBlock: Int? = nil) throws -> [String: Any]? {
        guard let overflow = frame.readOverflow else { return nil }
        var input = JSONInput(prefix: frame.bytes, overflow: overflow)
        var row: [String: Any] = [:]
        do {
            try input.object(at: 0) { input, key in
                switch key {
                case "message":
                    row["message"] = try message(&input, textLimit: textLimit, onlyBlock: onlyBlock)
                case "timestamp":
                    row["timestamp"] = try input.scalar(at: 1)
                case "cwd":
                    row["cwd"] = try input.stringValue(at: 1, limit: 6 * 4096)
                case "gitBranch":
                    row["gitBranch"] = try input.stringValue(at: 1, limit: 6 * 1024)
                case "type", "uuid", "sessionId", "version":
                    if let key { row[key] = try input.stringValue(at: 1, limit: 6 * 256) }
                default:
                    try input.skip(at: 1)
                }
            }
            guard try input.finished() else { return nil }
            return row
        } catch is JSONInput.Invalid {
            return nil
        }
    }

    private static func message(_ input: inout JSONInput, textLimit: Int, onlyBlock: Int?) throws -> [String: Any]? {
        guard try input.has(0x7B) else { try input.skip(at: 1); return nil }
        var message: [String: Any] = [:]
        try input.object(at: 1) { input, key in
            switch key {
            case "model":
                message["model"] = try input.stringValue(at: 2, limit: 6 * 256)
            case "content":
                guard try input.has(0x5B) else {
                    try input.skip(at: 2)
                    message["content"] = nil
                    return
                }
                var blocks: [[String: Any]] = []
                try input.array(at: 2) { input, index in
                    // Preserve block positions for the ordinary decoder's dedupe keys.
                    if index < 240 {
                        if onlyBlock == nil || onlyBlock == index { blocks.append(try toolResult(&input, textLimit: textLimit)) }
                        else { try input.skip(at: 3); blocks.append([:]) }
                    } else { try input.skip(at: 3) }
                }
                message["content"] = blocks
            default:
                try input.skip(at: 2)
            }
        }
        return message
    }

    private static func toolResult(_ input: inout JSONInput, textLimit: Int) throws -> [String: Any] {
        guard try input.has(0x7B) else { try input.skip(at: 3); return [:] }
        var type: String?
        var fields: [String: Any] = [:]
        try input.object(at: 3) { input, key in
            switch key {
            case "type": type = try input.stringValue(at: 4, limit: 96)
            case "tool_use_id": fields["tool_use_id"] = try input.stringValue(at: 4, limit: 6 * 256)
            case "is_error": fields["is_error"] = try input.scalar(at: 4) as? Bool
            case "content": fields["content"] = try toolText(&input, textLimit: textLimit)
            default: try input.skip(at: 4)
            }
        }
        guard type == "tool_result" else { return [:] }
        fields["type"] = type
        return fields
    }

    private static func toolText(_ input: inout JSONInput, textLimit: Int) throws -> String {
        let rawPreviewLimit = 6 * textLimit + 12
        var preview = Preview(limit: textLimit)
        if try input.has(0x22) {
            if let text = try input.string(limit: rawPreviewLimit, allowPrefix: true) { preview.append(text) }
        } else if try input.has(0x5B) {
            try input.array(at: 4) { input, _ in
                guard !preview.full, try input.has(0x7B) else { try input.skip(at: 5); return }
                var type: String?
                var text: String?
                // Claude/JSON may place the text before its discriminator.
                try input.object(at: 5) { input, key in
                    switch key {
                    case "type": type = try input.stringValue(at: 6, limit: 96)
                    case "text": text = try input.stringValue(at: 6, limit: rawPreviewLimit, allowPrefix: true)
                    default: try input.skip(at: 6)
                    }
                }
                if type == "text", let text { preview.append(text) }
            }
        } else {
            try input.skip(at: 4)
        }
        return String(decoding: preview.bytes, as: UTF8.self)
    }

    private struct Preview {
        let limit: Int
        var bytes = Data()
        var full = false
        private var hasBlock = false

        mutating func append(_ text: String) {
            if hasBlock { bytes.append(0x0A) }
            hasBlock = true
            let available = limit - bytes.count
            let prefix = text.utf8.prefix(available)
            if let valid = (0...min(3, prefix.count)).lazy.compactMap({
                String(bytes: prefix.dropLast($0), encoding: .utf8)
            }).first {
                bytes.append(contentsOf: valid.utf8)
            }
            // If the next scalar straddled the limit, avoid substituting any later text.
            full = text.utf8.count > available || bytes.count == limit
        }
    }
}

/// A bounded lexical reader for the oversized fallback. Discarded values
/// still consume their JSON delimiters and escape sequences.
private struct JSONInput {
    enum Invalid: Error { case malformed }

    private var chunk: Data
    private var index: Data.Index
    private let overflow: @Sendable (Int64, Int) throws -> Data
    private var overflowOffset: Int64 = 0
    private var atEOF = false

    init(prefix: Data, overflow: @escaping @Sendable (Int64, Int) throws -> Data) {
        chunk = prefix
        index = prefix.startIndex
        self.overflow = overflow
    }

    mutating func object(at depth: Int, keepKeys: Bool = true,
                         field: (inout Self, String?) throws -> Void) throws {
        guard depth < 64 else { throw Invalid.malformed }
        try expect(0x7B)
        if try consume(0x7D) { return }
        repeat {
            let key = try string(limit: keepKeys ? 256 : 0)
            try expect(0x3A)
            try field(&self, key)
        } while try consume(0x2C)
        try expect(0x7D)
    }

    mutating func array(at depth: Int, item: (inout Self, Int) throws -> Void) throws {
        guard depth < 64 else { throw Invalid.malformed }
        try expect(0x5B)
        if try consume(0x5D) { return }
        var position = 0
        repeat {
            try item(&self, position)
            position += 1
        } while try consume(0x2C)
        try expect(0x5D)
    }

    mutating func stringValue(at depth: Int, limit: Int, allowPrefix: Bool = false) throws -> String? {
        guard try has(0x22) else { try skip(at: depth); return nil }
        return try string(limit: limit, allowPrefix: allowPrefix)
    }

    mutating func string(limit: Int, allowPrefix: Bool = false) throws -> String? {
        try expect(0x22)
        var bytes = Data()
        var clipped = false
        var escape = 0 // -1 after a backslash; 1...4 hex digits still expected.
        var continuation = 0
        var continuationRange: ClosedRange<UInt8> = 0x80...0xBF
        while let byte = try next() {
            if byte == 0x22 && escape == 0 && continuation == 0 {
                guard limit > 0, allowPrefix || !clipped else { return nil }
                // A captured prefix can end inside UTF-8 or an escaped surrogate pair.
                for drop in 0...(clipped ? min(12, bytes.count) : 0) {
                    var candidate = Data([0x5B, 0x22])
                    candidate.append(contentsOf: bytes.dropLast(drop))
                    candidate.append(contentsOf: [0x22, 0x5D])
                    if let strings = (try? JSONSerialization.jsonObject(with: candidate)) as? [String] {
                        return strings.first
                    }
                }
                throw Invalid.malformed
            }
            guard byte >= 0x20 else { throw Invalid.malformed }
            if continuation > 0 {
                guard continuationRange.contains(byte) else { throw Invalid.malformed }
                continuation -= 1
                continuationRange = 0x80...0xBF
            } else if escape == 0 && byte >= 0x80 {
                // Check UTF-8 even for fields we skip or string suffixes we discard.
                switch byte {
                case 0xC2...0xDF: continuation = 1
                case 0xE0: continuation = 2; continuationRange = 0xA0...0xBF
                case 0xE1...0xEC, 0xEE...0xEF: continuation = 2
                case 0xED: continuation = 2; continuationRange = 0x80...0x9F
                case 0xF0: continuation = 3; continuationRange = 0x90...0xBF
                case 0xF1...0xF3: continuation = 3
                case 0xF4: continuation = 3; continuationRange = 0x80...0x8F
                default: throw Invalid.malformed
                }
            } else {
                switch escape {
                case -1:
                    switch byte {
                    case 0x75: escape = 4
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74: escape = 0
                    default: throw Invalid.malformed
                    }
                case 1...4:
                    switch byte {
                    case 0x30...0x39, 0x41...0x46, 0x61...0x66: escape -= 1
                    default: throw Invalid.malformed
                    }
                default:
                    if byte == 0x5C { escape = -1 }
                }
            }
            if bytes.count < limit { bytes.append(byte) }
            else { clipped = true }
        }
        throw Invalid.malformed
    }

    mutating func skip(at depth: Int) throws {
        switch try token() {
        case 0x7B: try object(at: depth, keepKeys: false) { input, _ in try input.skip(at: depth + 1) }
        case 0x5B: try array(at: depth) { input, _ in try input.skip(at: depth + 1) }
        case 0x22: _ = try string(limit: 0)
        default: _ = try primitive(retainNumber: false)
        }
    }

    mutating func scalar(at depth: Int) throws -> Any? {
        switch try token() {
        case 0x7B, 0x5B: try skip(at: depth); return nil
        case 0x22: return try string(limit: 6 * 256)
        default: return try primitive(retainNumber: true)
        }
    }

    private mutating func primitive(retainNumber: Bool) throws -> Any? {
        guard let start = try token() else { throw Invalid.malformed }
        switch start {
        case 0x74: try literal("true"); return true
        case 0x66: try literal("false"); return false
        case 0x6E: try literal("null"); return nil
        case 0x2D, 0x30...0x39:
            // Skip long unrelated numbers with a fixed capture cap, checking their syntax.
            var number = Data()
            var tooLong = false
            func keep(_ byte: UInt8) {
                guard retainNumber else { return }
                if number.count < 64 { number.append(byte) }
                else { tooLong = true }
            }
            if try peek() == 0x2D { _ = try next(); keep(0x2D) }
            if try peek() == 0x30 { _ = try next(); keep(0x30) }
            else if try !digits(keep) { throw Invalid.malformed }
            if try peek() == 0x2E {
                _ = try next(); keep(0x2E)
                guard try digits(keep) else { throw Invalid.malformed }
            }
            if let exponent = try peek(), exponent == 0x65 || exponent == 0x45 {
                _ = try next(); keep(exponent)
                if let sign = try peek(), sign == 0x2B || sign == 0x2D { _ = try next(); keep(sign) }
                guard try digits(keep) else { throw Invalid.malformed }
            }
            return retainNumber && !tooLong
                ? try? JSONSerialization.jsonObject(with: number, options: .fragmentsAllowed) : nil
        default:
            throw Invalid.malformed
        }
    }

    private mutating func digits(_ digit: (UInt8) -> Void) throws -> Bool {
        var found = false
        while let byte = try peek(), (0x30...0x39).contains(byte) {
            index += 1
            digit(byte)
            found = true
        }
        return found
    }

    private mutating func literal(_ word: String) throws {
        for byte in word.utf8 where try next() != byte { throw Invalid.malformed }
    }

    mutating func has(_ byte: UInt8) throws -> Bool { try token() == byte }
    mutating func finished() throws -> Bool { try token() == nil }

    private mutating func consume(_ byte: UInt8) throws -> Bool {
        guard try has(byte) else { return false }
        index += 1
        return true
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard try consume(byte) else { throw Invalid.malformed }
    }

    private mutating func token() throws -> UInt8? {
        while let byte = try peek() {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return byte
            }
        }
        return nil
    }

    private mutating func next() throws -> UInt8? {
        guard let byte = try peek() else { return nil }
        index += 1
        return byte
    }

    private mutating func peek() throws -> UInt8? {
        if index == chunk.endIndex {
            guard !atEOF else { return nil }
            chunk = try overflow(overflowOffset, 64 * 1024)
            index = chunk.startIndex
            if chunk.isEmpty { atEOF = true; return nil }
            overflowOffset += Int64(chunk.count)
        }
        return chunk[index]
    }
}
