import Foundation

/// Supported local agent families; entrypoints and providers are separate metadata.
public enum AgentKind: String, Codable, CaseIterable, Sendable {
    case claudeCode = "claude_code", codex, copilot, grokBuild = "grok_build"
}

/// An in-environment → host-path rule for display and future copy-resume use.
/// `PathMapper` applies it without authorizing or opening a source path.
public struct PathMapping: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    /// Preserve the configured strings without normalization or file access.
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// An exact metadata-field match that labels an environment without asserting routing.
public struct EnvironmentRule: Codable, Equatable, Sendable {
    public var field: String
    public var equals: String
    public var environment: String
    /// Create a normalized value without performing file access.
    public init(field: String, equals: String, environment: String) {
        self.field = field; self.equals = equals; self.environment = environment
    }
}

/// Source permission. Bookmark data is private and is persisted only in the app database.
public enum AccessKind: Codable, Equatable, Sendable {
    case defaultLocation
    case bookmark(Data)
}

/// Stable identity supplied after an authorized metadata lookup of a directory.
public struct SourceRootIdentity: Equatable, Sendable {
    public let volume: UUID
    public let inode: Int64
    public let birthSeconds: Int64
    public let birthNanoseconds: Int64

    public init(volume: UUID, inode: Int64, birthSeconds: Int64, birthNanoseconds: Int64) {
        self.volume = volume
        self.inode = inode
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }
}

/// One agent family, local root, and environment. New sources have no database ID.
public struct Source: Codable, Equatable, Sendable, Identifiable {
    public var id: Int64?
    public var agent: AgentKind
    public var label: String
    public var rootURL: URL
    public var environment: String
    public var pathMappings: [PathMapping]
    public var environmentRules: [EnvironmentRule]
    public var access: AccessKind
    public var enabled: Bool

    /// Validate URL metadata without resolving or opening a directory.
    public static func isLocalRoot(_ url: URL) -> Bool {
        let host = url.host(percentEncoded: false)?.lowercased()
        return url.isFileURL && (host == nil || host == "" || host == "localhost") &&
            url.path.hasPrefix("/") && !url.path.utf8.contains(0)
    }

    /// Create a normalized value without performing file access.
    public init(id: Int64? = nil, agent: AgentKind, label: String, rootURL: URL,
                environment: String = "Local", pathMappings: [PathMapping] = [],
                environmentRules: [EnvironmentRule] = [], access: AccessKind = .defaultLocation,
                enabled: Bool = true) {
        self.id = id; self.agent = agent; self.label = label; self.rootURL = rootURL
        self.environment = environment; self.pathMappings = pathMappings
        self.environmentRules = environmentRules; self.access = access; self.enabled = enabled
    }
}

/// An adapter-discovered file relative to an already-authorized source root.
public struct SourceFile: Codable, Equatable, Sendable, Identifiable {
    /// File responsibilities, independent of vendor-specific record formats.
    public enum Role: String, Codable, Sendable {
        case session, subagent, promptHistory = "prompt_history", sidecar, metadataDB = "metadata_db"
    }
    public var id: Int64?
    public var sourceID: Int64
    public var relativePath: String
    public var role: Role
    public var parserVersion: Int
    /// Create a normalized value without performing file access.
    public init(id: Int64? = nil, sourceID: Int64, relativePath: String, role: Role, parserVersion: Int = 1) {
        self.id = id; self.sourceID = sourceID; self.relativePath = relativePath
        self.role = role; self.parserVersion = parserVersion
    }
}

/// Resume position after the last complete record, never after a partial trailing line.
/// Timestamp is UTC epoch milliseconds; sequence is file order, independent of timestamp.
public struct Checkpoint: Codable, Equatable, Sendable {
    public static let maximumDecoderStateBytes = 65_536

    public var device: Int64?
    public var inode: Int64?
    public var size: Int64
    public var modificationTimeNS: Int64?
    public var offset: Int64
    public var parserVersion: Int
    public var sequence: Int64
    public var previousTimestamp: Int64?
    public var decoderState: Data?
    public var unknownRecords: Int64

    /// Create a normalized value without performing file access.
    public init(inode: Int64?, size: Int64, offset: Int64, parserVersion: Int,
                sequence: Int64, previousTimestamp: Int64?, device: Int64? = nil,
                modificationTimeNS: Int64? = nil, decoderState: Data? = nil, unknownRecords: Int64 = 0) {
        self.device = device
        self.inode = inode; self.size = size; self.offset = offset; self.parserVersion = parserVersion
        self.sequence = sequence; self.previousTimestamp = previousTimestamp
        self.modificationTimeNS = modificationTimeNS
        self.decoderState = decoderState
        self.unknownRecords = unknownRecords
    }

    private enum CodingKeys: String, CodingKey {
        case device, inode, size, modificationTimeNS, offset, parserVersion, sequence, previousTimestamp
        case decoderState, unknownRecords
    }

    /// Old checkpoints still decode; an importer replays once if device information is missing.
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(inode: fields.decodeIfPresent(Int64.self, forKey: .inode),
                      size: fields.decode(Int64.self, forKey: .size),
                      offset: fields.decode(Int64.self, forKey: .offset),
                      parserVersion: fields.decode(Int.self, forKey: .parserVersion),
                      sequence: fields.decode(Int64.self, forKey: .sequence),
                      previousTimestamp: fields.decodeIfPresent(Int64.self, forKey: .previousTimestamp),
                      device: fields.decodeIfPresent(Int64.self, forKey: .device),
                      modificationTimeNS: fields.decodeIfPresent(Int64.self, forKey: .modificationTimeNS),
                      decoderState: fields.decodeIfPresent(Data.self, forKey: .decoderState),
                      unknownRecords: fields.decodeIfPresent(Int64.self, forKey: .unknownRecords) ?? 0)
    }
}
