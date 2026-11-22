import Foundation

/// Stable cross-file identity; adapters never need database session row IDs.
public struct SessionKey: Codable, Equatable, Hashable, Sendable {
    public var agent: AgentKind
    public var nativeID: String
    /// Create a normalized value without performing file access.
    public init(agent: AgentKind, nativeID: String) { self.agent = agent; self.nativeID = nativeID }
}

/// A conservative normalized status. Status inference is implemented in M3.
public enum SessionStatus: String, Codable, Sendable {
    case running, waiting, completed, failed, unknown
}

/// Minimal session metadata. All times are UTC epoch milliseconds.
public struct SessionRecord: Codable, Equatable, Sendable {
    public var key: SessionKey
    public var sourceID: Int64
    public var fileID: Int64?
    public var environment: String
    public var cwd: String?
    public var title: String?
    public var startedAt: Int64?
    public var lastEventAt: Int64?
    public var status: SessionStatus
    public var gitBranch: String?
    public var cliVersion: String?
    public var model: String?
    public var parentNativeID: String?
    /// An inherited transcript can establish an owner before its own file is found.
    /// Does not replace metadata already written by that session.
    public var referenceOnly: Bool?
    public var entrypoint: String?
    public var modelProvider: String?
    public var gitSHA: String?
    public var contextWindow: Int64?
    public var contextUsed: Int64?
    /// Model ID attached to the input measurement, independent of the next turn.
    public var contextModel: String?
    /// Create a normalized value without performing file access.
    public init(key: SessionKey, sourceID: Int64, fileID: Int64? = nil, environment: String,
                cwd: String? = nil, title: String? = nil, startedAt: Int64? = nil,
                lastEventAt: Int64? = nil, status: SessionStatus = .unknown, gitBranch: String? = nil,
                cliVersion: String? = nil, model: String? = nil, parentNativeID: String? = nil,
                referenceOnly: Bool? = nil,
                entrypoint: String? = nil, modelProvider: String? = nil, gitSHA: String? = nil,
                contextWindow: Int64? = nil, contextUsed: Int64? = nil, contextModel: String? = nil) {
        self.key = key; self.sourceID = sourceID; self.fileID = fileID; self.environment = environment
        self.cwd = cwd; self.title = title; self.startedAt = startedAt; self.lastEventAt = lastEventAt
        self.status = status
        self.gitBranch = gitBranch; self.cliVersion = cliVersion; self.model = model; self.parentNativeID = parentNativeID
        self.referenceOnly = referenceOnly
        self.entrypoint = entrypoint; self.modelProvider = modelProvider; self.gitSHA = gitSHA
        self.contextWindow = contextWindow; self.contextUsed = contextUsed; self.contextModel = contextModel
    }
}

/// Unknown records are retained by adapters as truncated metadata, never silently dropped.
public enum EventKind: String, Codable, Sendable {
    case user, assistant, toolCall = "tool_call", toolResult = "tool_result", summary, system, error
    case promptHistory = "prompt_history", unknown
}

/// A producer-supplied session identity, separate from the file being scanned.
/// A copy can fill absent records, but its physical order is provisional.
public enum RecordedSessionOwnership: String, Codable, Sendable { case original, inherited }

/// Transcript channel arbitration applies only to normalized user and assistant messages.
public enum TranscriptChannel: String, Codable, Sendable { case preferred, fallback }

/// Searchable normalized event. The adapter owns truncation and the globally deterministic dedupe key.
public struct EventRecord: Codable, Equatable, Sendable {
    public var session: SessionKey
    public var sequence: Int64
    public var timestamp: Int64
    public var kind: EventKind
    public var toolName: String?
    public var text: String?
    public var metadataJSON: String?
    public var dedupeKey: String
    public var recordedOwnership: RecordedSessionOwnership?
    public var transcriptChannel: TranscriptChannel?
    /// Create a normalized value without performing file access.
    public init(session: SessionKey, sequence: Int64, timestamp: Int64, kind: EventKind,
                toolName: String? = nil, text: String? = nil, metadataJSON: String? = nil, dedupeKey: String,
                recordedOwnership: RecordedSessionOwnership? = nil, transcriptChannel: TranscriptChannel? = nil) {
        self.session = session; self.sequence = sequence; self.timestamp = timestamp; self.kind = kind
        self.toolName = toolName; self.text = text; self.metadataJSON = metadataJSON; self.dedupeKey = dedupeKey
        self.recordedOwnership = recordedOwnership; self.transcriptChannel = transcriptChannel
    }
}

/// Cache-inclusive token components. Reasoning is already included in output (SPEC §8.1).
public struct TokenCounts: Codable, Equatable, Sendable {
    public var inputFresh: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var cacheWrite1h: Int64
    public var output: Int64
    public var reasoning: Int64
    public var input: Int64 { inputFresh + cacheRead + cacheWrite + cacheWrite1h }
    public var total: Int64 { input + output }
    /// Create a normalized value without performing file access.
    public init(inputFresh: Int64 = 0, cacheRead: Int64 = 0, cacheWrite: Int64 = 0,
                cacheWrite1h: Int64 = 0, output: Int64 = 0, reasoning: Int64 = 0) {
        self.inputFresh = inputFresh; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.cacheWrite1h = cacheWrite1h; self.output = output; self.reasoning = reasoning
    }
}

/// Normalized usage precision; coarse snapshots must not be used for peak calculations.
public enum TokenPrecision: String, Codable, Sendable { case call, snapshot, checkpoint }

/// Unpriced normalized token usage. Pricing and rollup calculation arrive with M4.
public struct TokenEvent: Codable, Equatable, Sendable {
    public var session: SessionKey
    public var timestamp: Int64
    public var model: String?
    public var counts: TokenCounts
    public var precision: TokenPrecision
    public var dedupeKey: String
    public var recordedOwnership: RecordedSessionOwnership?
    /// Physical file order for Copilot per-call reconciliation.
    public var sourceSequence: Int64?
    /// Create a normalized value without performing file access.
    public init(session: SessionKey, timestamp: Int64, model: String? = nil, counts: TokenCounts,
                precision: TokenPrecision = .call, dedupeKey: String, recordedOwnership: RecordedSessionOwnership? = nil,
                sourceSequence: Int64? = nil) {
        self.session = session; self.timestamp = timestamp; self.model = model
        self.counts = counts; self.precision = precision; self.dedupeKey = dedupeKey
        self.recordedOwnership = recordedOwnership
        self.sourceSequence = sourceSequence
    }
}

/// A durable per-model cumulative sample, never counted as a call.
public struct CopilotUsageSnapshot: Equatable, Sendable {
    public let session: SessionKey
    public let model: String
    public let sequence: Int64
    public let timestamp: Int64
    public let counts: TokenCounts
    public let dedupeKey: String

    public init(session: SessionKey, model: String, sequence: Int64, timestamp: Int64,
                counts: TokenCounts, dedupeKey: String) {
        self.session = session; self.model = model; self.sequence = sequence
        self.timestamp = timestamp; self.counts = counts; self.dedupeKey = dedupeKey
    }
}

/// A reported rate-limit window; not a token event and never added to usage.
public struct RateLimitSnapshot: Equatable, Sendable {
    public enum Window: String, Sendable { case primary, secondary }

    public let agent: AgentKind
    public let limitID: String
    public let window: Window
    public let timestamp: Int64
    public let windowMinutes: Int64?
    public let usedPercent: Double?
    public let resetsAt: Int64?
    public let planType: String?

    public init(agent: AgentKind, limitID: String, window: Window, timestamp: Int64, windowMinutes: Int64? = nil,
                usedPercent: Double? = nil, resetsAt: Int64? = nil, planType: String? = nil) {
        self.agent = agent; self.limitID = limitID; self.window = window; self.timestamp = timestamp
        self.windowMinutes = windowMinutes; self.usedPercent = usedPercent; self.resetsAt = resetsAt; self.planType = planType
    }
}

/// Adapter output. Sessions precede their events/tokens in a transaction.
public enum NormalizedRecord: Equatable, Sendable {
    case session(SessionRecord)
    case event(EventRecord)
    case tokens(TokenEvent)
    case copilotUsageSnapshot(CopilotUsageSnapshot)
    /// Reconcile an empty legacy marker in the app-owned index during replay.
    case removeEmptyPlaceholder(session: SessionKey, fileID: Int64, sequence: Int64, dedupeKey: String)
    case rateLimit(RateLimitSnapshot)
}
