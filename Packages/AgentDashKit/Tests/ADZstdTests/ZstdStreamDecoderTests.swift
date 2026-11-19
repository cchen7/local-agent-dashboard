import Foundation
import Testing
import ADZstd

private typealias Fixtures = SyntheticZstdFixtures

@Test("SEC-4/ADP-CX: compressed, raw, empty and skippable concatenated frames",
      arguments: [1, 2, 3, 7, 32, 155, 4096], [1, 31, 64 * 1024])
func concatenatedFrames(inputSize: Int, outputSize: Int) throws {
    let tail = Data("合成字节\n".utf8)
    let bytes = Fixtures.checkedFrame + Fixtures.skippable(Data([1, 2, 3]))
        + Fixtures.skippable(Data()) + Fixtures.rawFrame(Data()) + Fixtures.rawFrame(tail)
    let decoder = try ZstdStreamDecoder(outputChunkSize: outputSize)
    var output = Data()
    for offset in stride(from: 0, to: bytes.count, by: inputSize) {
        try decoder.write(bytes.subdata(in: offset..<min(offset + inputSize, bytes.count))) { chunk in
            #expect(!chunk.isEmpty && chunk.count <= outputSize)
            output.append(chunk)
        }
    }
    try decoder.finish()
    #expect(output == Fixtures.checkedText + tail)
    #expect(decoder.completedFrameCount == 5)
}

@Test("ADP-CX: every split of a checksummed compressed frame")
func everyInputSplit() throws {
    for split in 0...Fixtures.checkedFrame.count {
        let decoder = try ZstdStreamDecoder(outputChunkSize: 17)
        var output = Data()
        try decoder.write(Data(Fixtures.checkedFrame.prefix(split))) { output.append($0) }
        try decoder.write(Data(Fixtures.checkedFrame.dropFirst(split))) { output.append($0) }
        try decoder.finish()
        #expect(output == Fixtures.checkedText)
        #expect(decoder.completedFrameCount == 1)
    }
}

@Test("SEC-4: high expansion emits bounded chunks before final input; no whole-file output",
      arguments: [1023, ZstdStreamDecoder.maximumOutputChunkSize])
func highExpansionStreamsBeforeEOF(outputSize: Int) throws {
    let bytes = Fixtures.rleFrame(blocks: 16)
    let decoder = try ZstdStreamDecoder(outputChunkSize: outputSize)
    var total = 0
    var largest = 0
    let consume: (Data) -> Void = { chunk in
        #expect(!chunk.isEmpty && chunk.count <= outputSize)
        #expect(chunk.allSatisfy { $0 == 0x5a })
        total += chunk.count
        largest = max(largest, chunk.count)
    }
    try decoder.write(Data(bytes.prefix(13)), emit: consume) // Header + first non-final RLE block.
    #expect(total > 0)
    #expect(decoder.completedFrameCount == 0)
    try decoder.write(Data(bytes.dropFirst(13)), emit: consume)
    try decoder.finish()
    #expect(total == 2 * 1024 * 1024)
    #expect(largest == outputSize)
    #expect(decoder.completedFrameCount == 1)
}

@Test("ADP-CX: every strict prefix is an incomplete final frame")
func allTruncatedPrefixes() throws {
    for count in 0..<Fixtures.checkedFrame.count {
        let decoder = try ZstdStreamDecoder(outputChunkSize: 19)
        try decoder.write(Data(Fixtures.checkedFrame.prefix(count))) { _ in }
        #expect(throws: ZstdDecodingError.truncatedFrame) { try decoder.finish() }
        #expect(throws: ZstdDecodingError.streamClosed) { try decoder.finish() }
    }
}

@Test("ADP-CX: a valid first frame cannot hide a truncated second frame")
func truncatedConcatenation() throws {
    let first = Fixtures.rawFrame(Data([0x41]))
    for count in 1..<Fixtures.checkedFrame.count {
        let decoder = try ZstdStreamDecoder()
        try decoder.write(first + Fixtures.checkedFrame.prefix(count)) { _ in }
        #expect(decoder.completedFrameCount == 1)
        #expect(throws: ZstdDecodingError.truncatedFrame) { try decoder.finish() }
    }
}

@Test("ADP-CX: damaged checksum and invalid blocks are rejected")
func corruptInput() throws {
    var checksum = Fixtures.checkedFrame
    checksum[checksum.count - 1] ^= 0x01
    var block = Fixtures.rawFrame(Data([0x41]))
    block[9] = 0x0f // Reserved block type 3.
    var header = Fixtures.rawFrame(Data([0x41]))
    header[4] |= 0x08 // Reserved frame-header bit.
    for bytes in [checksum, block, header, Data([0, 1, 2, 3, 4, 5, 6, 7])] {
        let decoder = try ZstdStreamDecoder(outputChunkSize: 11)
        #expect(throws: ZstdDecodingError.corruptInput) { try decoder.write(bytes) { _ in } }
        #expect(throws: ZstdDecodingError.streamClosed) { try decoder.write(Data()) { _ in } }
    }
}

@Test("ADP-CX: unknown content size and maximum-length frame headers stream at every split")
func otherHeaderForms() throws {
    let magic = Data([0x28, 0xb5, 0x2f, 0xfd])
    let block = Data([0x09, 0, 0, 0x41]) // One final raw byte, A.
    let unknownSize = magic + Data([0, 0]) + block // Non-single segment, 1 KiB window.
    let longestHeader = magic + Data([0xe3]) + Fixtures.littleEndian(0, bytes: 4)
        + Fixtures.littleEndian(1, bytes: 8) + block // 18-byte header; dictID zero.
    for bytes in [unknownSize, longestHeader] {
        for split in 0...bytes.count {
            let decoder = try ZstdStreamDecoder(maximumWindowSize: 1024, outputChunkSize: 1)
            var output = Data()
            try decoder.write(Data(bytes.prefix(split))) { output.append($0) }
            try decoder.write(Data(bytes.dropFirst(split))) { output.append($0) }
            try decoder.finish()
            #expect(output == Data([0x41]))
            #expect(decoder.completedFrameCount == 1)
        }
    }
}

@Test("ADP-CX: trailing garbage is not silently discarded")
func trailingGarbage() throws {
    let decoder = try ZstdStreamDecoder()
    #expect(throws: ZstdDecodingError.corruptInput) {
        try decoder.write(Fixtures.checkedFrame + Data([0, 1, 2, 3, 4])) { _ in }
    }
    #expect(decoder.completedFrameCount == 1)
}

@Test("SEC-4: no external dictionary is accepted, even after another frame",
      arguments: [false, true], [1, 4096])
func dictionariesRejected(concatenated: Bool, inputSize: Int) throws {
    let decoder = try ZstdStreamDecoder()
    let bytes = (concatenated ? Fixtures.checkedFrame : Data()) + Fixtures.dictionaryFrame
    #expect(throws: ZstdDecodingError.dictionaryRequired) {
        for offset in stride(from: 0, to: bytes.count, by: inputSize) {
            try decoder.write(bytes.subdata(in: offset..<min(offset + inputSize, bytes.count))) { _ in }
        }
    }
    #expect(decoder.completedFrameCount == (concatenated ? 1 : 0))
}

@Test("SEC-4: window cap survives concatenation and the small-frame fast path",
      arguments: [false, true], [1, 4096])
func oversizedWindowsRejected(concatenated: Bool, inputSize: Int) throws {
    let decoder = try ZstdStreamDecoder(maximumWindowSize: 1024)
    let first = concatenated ? Fixtures.rawFrame(Data([0x42])) : Data()
    let bytes = first + Fixtures.largeWindowTinyFrame
    #expect(throws: ZstdDecodingError.windowLimitExceeded) {
        for offset in stride(from: 0, to: bytes.count, by: inputSize) {
            try decoder.write(bytes.subdata(in: offset..<min(offset + inputSize, bytes.count))) { _ in }
        }
    }
    #expect(decoder.completedFrameCount == (concatenated ? 1 : 0))
}

@Test("SEC-4: exact byte window limit, including single-segment content size")
func exactWindowLimit() throws {
    let decoder = try ZstdStreamDecoder(maximumWindowSize: 1025, outputChunkSize: 2048)
    var total = 0
    try decoder.write(Fixtures.rleFrame(blocks: 1, blockSize: 1025)) { total += $0.count }
    try decoder.finish()
    #expect(total == 1025)
    let oversized = try ZstdStreamDecoder(maximumWindowSize: 1025, outputChunkSize: 2048)
    #expect(throws: ZstdDecodingError.windowLimitExceeded) {
        try oversized.write(Fixtures.rleFrame(blocks: 1, blockSize: 1026)) { _ in }
    }
}

@Test("SEC-4: configuration cannot disable or expand the hard memory caps")
func invalidConfiguration() {
    for size in [Int.min, -1, 0, ZstdStreamDecoder.maximumOutputChunkSize + 1, Int.max] {
        #expect(throws: ZstdDecodingError.invalidConfiguration) {
            _ = try ZstdStreamDecoder(outputChunkSize: size)
        }
    }
    for size in [Int.min, -1, 0, 1023, ZstdStreamDecoder.windowSizeLimit + 1, Int.max] {
        #expect(throws: ZstdDecodingError.invalidConfiguration) {
            _ = try ZstdStreamDecoder(maximumWindowSize: size)
        }
    }
}

@Test("ADP-CX: empty chunks preserve frame boundaries; empty frames are valid")
func emptyChunksAndFrames() throws {
    let decoder = try ZstdStreamDecoder()
    var emitted = false
    try decoder.write(Data()) { _ in emitted = true }
    #expect(decoder.completedFrameCount == 0)
    try decoder.write(Fixtures.rawFrame(Data())) { _ in emitted = true }
    try decoder.write(Data()) { _ in emitted = true }
    try decoder.finish()
    #expect(!emitted)
    #expect(decoder.completedFrameCount == 1)
    #expect(throws: ZstdDecodingError.streamClosed) { try decoder.write(Data()) { _ in } }
    #expect(throws: ZstdDecodingError.streamClosed) { try decoder.finish() }
}

@Test("SEC-4: a huge incomplete skippable frame requires no payload allocation")
func truncatedSkippableFrame() throws {
    let decoder = try ZstdStreamDecoder()
    let header = Data([0x50, 0x2a, 0x4d, 0x18, 0xff, 0xff, 0xff, 0xff])
    try decoder.write(header) { _ in Issue.record("Skippable frames must emit no output") }
    #expect(throws: ZstdDecodingError.truncatedFrame) { try decoder.finish() }
    #expect(decoder.completedFrameCount == 0)
}

private enum ConsumerError: Error { case stopped }

@Test("SEC-4: consumer failure aborts streaming and preserves the original error")
func throwingConsumer() throws {
    let decoder = try ZstdStreamDecoder(outputChunkSize: 1)
    var calls = 0
    #expect(throws: ConsumerError.stopped) {
        try decoder.write(Fixtures.checkedFrame) { _ in
            calls += 1
            throw ConsumerError.stopped
        }
    }
    #expect(calls == 1)
    #expect(throws: ZstdDecodingError.streamClosed) { try decoder.finish() }
}

@Test("SEC-4: callbacks cannot reenter the native decoder")
func reentrantConsumer() throws {
    let decoder = try ZstdStreamDecoder()
    try decoder.write(Fixtures.checkedFrame) { _ in
        #expect(throws: ZstdDecodingError.streamClosed) {
            try decoder.write(Fixtures.checkedFrame) { _ in }
        }
        #expect(throws: ZstdDecodingError.streamClosed) { try decoder.finish() }
    }
    try decoder.finish()
    #expect(decoder.completedFrameCount == 1)
}
