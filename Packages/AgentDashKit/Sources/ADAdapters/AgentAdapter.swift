import Foundation
import ADCore

/// A per-file decoder consumes only the complete frames supplied by ingestion.
public protocol AgentFileDecoder {
    mutating func decode(_ frame: JSONLFrame, context: JSONLDecodeContext) throws -> DecodedJSONLFrame
}

/// Normalize local JSONL without opening or writing the app-owned index.
public protocol AgentAdapter: Sendable {
    associatedtype Decoder: AgentFileDecoder
    static var kind: AgentKind { get }
    static var parserVersion: Int { get }
    /// The caller has already authorized the root and owns its access lifetime.
    func discover(in source: Source, authorizedRoot: URL) throws -> [SourceFile]
    func makeDecoder(for file: SourceFile, in source: Source) throws -> Decoder
    func storageEncoding(for file: SourceFile) -> JSONLStorageEncoding
    /// Return text for copying only; never execute the command.
    func resumeCommand(for session: SessionRecord) -> String?
}

public extension AgentAdapter {
    func storageEncoding(for file: SourceFile) -> JSONLStorageEncoding { .plain }
}
