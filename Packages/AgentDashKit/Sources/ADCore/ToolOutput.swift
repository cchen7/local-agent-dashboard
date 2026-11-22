import Foundation

public enum ToolOutputFormat: Codable, Equatable, Sendable {
    case claude(block: Int)
    case codex
    case copilot
}

/// Transient data between an adapter and the index writer. Search never sees
/// the archive payload. A large result may carry a locator without a payload.
public struct ToolOutputCapture: Codable, Equatable, Sendable {
    public static let searchableBytes = 2 * 1024
    public static let decodedArchiveBytes = 256 * 1024
    public static let maximumSourceLineBytes: Int64 = 16 * 1024 * 1024

    public let format: ToolOutputFormat
    public var archiveText: String?
    public var origin: ToolOutputOrigin?

    public init?(format: ToolOutputFormat, text: String, complete: Bool = true) {
        guard !complete || text.utf8.count > Self.searchableBytes || text.hasPrefix("<persisted-output>") else { return nil }
        self.format = format
        archiveText = complete && text.utf8.count <= Self.decodedArchiveBytes && !text.hasPrefix("<persisted-output>") ? text : nil
    }
}

/// Coordinates are advisory until they match a pinned file and the recorded
/// line digest. Path components come from the registered file row, never here.
public struct ToolRecordOrigin<Format: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let fileID: Int64
    public let device: Int64
    public let inode: Int64
    public let size: Int64
    public let modificationTimeNS: Int64
    public let byteStart: Int64?
    public let byteLength: Int64
    public let sequence: Int64
    public let digest: Data
    public let format: Format

    public init(fileID: Int64, snapshot: SourceFileReader.Snapshot, byteStart: Int64?, byteLength: Int64,
                sequence: Int64, digest: Data, format: Format) {
        self.fileID = fileID
        device = snapshot.device
        inode = snapshot.inode
        size = snapshot.size
        modificationTimeNS = snapshot.modificationTimeNS
        self.byteStart = byteStart
        self.byteLength = byteLength
        self.sequence = sequence
        self.digest = digest
        self.format = format
    }
}

public typealias ToolOutputOrigin = ToolRecordOrigin<ToolOutputFormat>

public enum ToolInputFormat: Codable, Equatable, Sendable {
    case claude(block: Int)
    case codex
    case copilot

    public var agent: AgentKind {
        switch self {
        case .claude: .claudeCode
        case .codex: .codex
        case .copilot: .copilot
        }
    }
}

public typealias ToolInputOrigin = ToolRecordOrigin<ToolInputFormat>

/// Only the format and verified line address travel with the indexed preview.
public struct ToolInputCapture: Codable, Equatable, Sendable {
    public let format: ToolInputFormat
    public var origin: ToolInputOrigin?

    public init(_ format: ToolInputFormat) { self.format = format }
}

public struct OriginalToolOutput: Sendable {
    public let text: String
    public let truncated: Bool

    public init(text: String, truncated: Bool) {
        self.text = text
        self.truncated = truncated
    }
}
