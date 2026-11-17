import Foundation
import GRDB
import ADCore

/// Store owns registration (DEV-004). unicode61 supplies Unicode word boundaries;
/// original byte slices preserve camelCase before unicode61's case folding loses it.
final class AgentDashTokenizer: FTS5WrapperTokenizer {
    static let name = "agentdash"
    let wrappedTokenizer: any FTS5Tokenizer

    init(db: Database, arguments: [String]) throws {
        wrappedTokenizer = try db.makeTokenizer(.unicode61(tokenCharacters: ["_", "-", "."]))
    }

    func accept(token: String, flags: FTS5TokenFlags, for tokenization: FTS5Tokenization,
                tokenCallback: FTS5WrapperTokenCallback) throws {
        for group in SearchTokenization.groups(in: token) {
            for (index, term) in group.terms.enumerated() {
                try tokenCallback(term, index == 0 ? flags : flags.union(.colocated))
            }
        }
    }

    // GRDB's wrapper default passes already-lowercased tokens to accept(). Override
    // only the bridge so the same pure splitter sees original case and byte offsets.
    func tokenize(context: UnsafeMutableRawPointer?, tokenization: FTS5Tokenization,
                  pText: UnsafePointer<CChar>?, nText: CInt,
                  tokenCallback: @escaping FTS5TokenCallback) -> CInt {
        guard let pText, nText > 0 else { return 0 }
        var bridge = Bridge(text: pText, byteCount: nText, context: context, callback: tokenCallback)
        return withUnsafeMutablePointer(to: &bridge) { pointer in
            wrappedTokenizer.tokenize(context: UnsafeMutableRawPointer(pointer), tokenization: tokenization,
                                      pText: pText, nText: nText) { raw, flags, _, _, start, end in
                guard let raw else { return 1 }
                let bridge = raw.assumingMemoryBound(to: Bridge.self).pointee
                guard start >= 0, end >= start, end <= bridge.byteCount else { return 1 }
                let bytes = UnsafeRawBufferPointer(start: bridge.text.advanced(by: Int(start)), count: Int(end - start))
                let original = String(decoding: bytes, as: UTF8.self)
                for group in SearchTokenization.groups(in: original) {
                    for (index, term) in group.terms.enumerated() {
                        let termFlags = index == 0 ? flags : flags | FTS5TokenFlags.colocated.rawValue
                        let code = term.withCString {
                            bridge.callback(bridge.context, termFlags, $0, CInt(term.utf8.count),
                                            start + CInt(group.start), start + CInt(group.end))
                        }
                        if code != 0 { return code }
                    }
                }
                return 0
            }
        }
    }

    private struct Bridge {
        let text: UnsafePointer<CChar>
        let byteCount: CInt
        let context: UnsafeMutableRawPointer?
        let callback: FTS5TokenCallback
    }
}
