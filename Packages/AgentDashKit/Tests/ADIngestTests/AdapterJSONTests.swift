@testable import ADAdapters
import Foundation
import Testing

@Test("ADP-6: blank-string check matches the previous trimming result")
func adapterStringBlankCheckMatchesTrimming() {
    let samples = ["", " ", "\n\t\r", "\u{00A0}\u{2028}\u{3000}\u{0085}", "\u{FEFF}", " a ", "登录",
                   "\u{200B}", " \u{1F600} ", " \u{0301}", "\u{0301}", "\n\u{20DD}\t", String(repeating: " ", count: 200_000) + "x",
                   String(repeating: "\n", count: 200_000)]
    for sample in samples {
        let trimmed = !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        #expect((AdapterJSON.string(sample) != nil) == trimmed)
    }
    #expect(AdapterJSON.string(1) == nil)
    #expect(AdapterJSON.string("é你好", bounded: 4) == "é")
}

@Test("ADP-5: ISO 8601 and numeric timestamps parse to UTC milliseconds")
func adapterTimestampsParseRepeatably() {
    for _ in 0..<2 {
        #expect(AdapterJSON.timestamp("2026-11-17T08:09:10.123Z") == 1_794_902_950_123)
        #expect(AdapterJSON.timestamp("2026-11-17T08:09:10Z") == 1_794_902_950_000)
        #expect(AdapterJSON.timestamp("2026-11-17T16:09:10+08:00") == 1_794_902_950_000)
        #expect(AdapterJSON.timestamp(1_794_902_950_123) == 1_794_902_950_123)
        #expect(AdapterJSON.timestamp("not a date") == nil)
        #expect(AdapterJSON.timestamp(true) == nil)
    }
}

@Test("ADP-7: byte prefixes never split a scalar")
func adapterPrefixKeepsWholeScalars() {
    let text = "a登🙂"  // 1 + 3 + 4 UTF-8 bytes
    let expected = ["", "a", "a", "a", "a登", "a登", "a登", "a登", "a登🙂", "a登🙂"]
    for (bytes, value) in expected.enumerated() {
        #expect(AdapterJSON.prefix(text, bytes: bytes) == value)
    }
}
