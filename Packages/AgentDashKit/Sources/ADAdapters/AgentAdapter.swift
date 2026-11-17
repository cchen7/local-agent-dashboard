import Foundation
import ADCore

/// Future vendor adapters; M0 implements no parser and reads no agent data.
public protocol AgentAdapter: Sendable {
    static var kind: AgentKind { get }
    static var parserVersion: Int { get }
    /// Discover local files without modifying or locking sources.
    func discover(root: URL) async throws -> [SourceFile]
    /// Resume parsing at a complete-record checkpoint and emit deterministic identities.
    func parse(_ file: SourceFile, from checkpoint: Checkpoint?) -> AsyncThrowingStream<NormalizedRecord, Error>
    /// Return text for copying only; never execute the command.
    func resumeCommand(for session: SessionRecord) -> String?
}
