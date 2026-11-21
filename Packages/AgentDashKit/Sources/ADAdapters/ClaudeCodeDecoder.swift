import ADCore
import CoreFoundation
import Foundation

/// ADP-CC: preserve per-file metadata while global record keys deduplicate copied history.
public struct ClaudeCodeDecoder: AgentFileDecoder {
    private struct Metadata: Codable, Equatable {
        var cwd: String?
        var branch: String?
        var version: String?
        var model: String?
        var started: Int64?
        var last: Int64?
        var legacyV2EndOffset: Int64?
    }

    private let file: SourceFile
    private let environment: String
    private let input: ClaudeInput
    private let fractionalDate = ISO8601DateFormatter()
    private let plainDate = ISO8601DateFormatter()
    private var cachedMetadata: (Data, Metadata)?

    init(file: SourceFile, environment: String, input: ClaudeInput) {
        self.file = file
        self.environment = environment
        self.input = input
        fractionalDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plainDate.formatOptions = [.withInternetDateTime]
    }

    public mutating func decode(_ frame: JSONLFrame, context: JSONLDecodeContext) throws -> DecodedJSONLFrame {
        let prior = load(context.state)
        var metadata = prior
        let legacyEnd = context.replayedPrefix.flatMap { $0.parserVersion == 2 ? $0.endOffset : nil }
            ?? prior.legacyV2EndOffset
        // Carry the old committed boundary through batch commits and a restart.
        // On rewrite, ingestion starts without the old decoder state or prefix.
        metadata.legacyV2EndOffset = legacyEnd.flatMap { frame.endOffset < $0 ? $0 : nil }
        if Self.isEarlySnapshot(frame.bytes) {
            return .init(state: encodedState(metadata, prior: prior, preserving: context.state))
        }
        let object = frame.isTruncated ? nil : (try? JSONSerialization.jsonObject(with: frame.bytes)) as? [String: Any]
        if case .history = input { return history(frame, row: object, context: context) }

        let key: SessionKey
        let parent: String?
        switch input {
        case .session(let id): (key, parent) = (.init(agent: .claudeCode, nativeID: id), nil)
        case .subagent(let id):
            (key, parent) = (.init(agent: .claudeCode, nativeID: "child:\(file.sourceID):\(file.relativePath)"), id)
        case .history: return .init(state: context.state, isUnknown: true)
        }

        let row = frame.isTruncated ? try ClaudeOversizedJSON.row(from: frame) ?? [:] : object ?? [:]
        let type = row["type"] as? String
        let parsedTime = timestamp(row["timestamp"])
        let time = parsedTime ?? context.previousTimestamp
        if type == "file-history-snapshot" || type == "queue-operation" || type == "attachment" {
            return .init(timestamp: parsedTime, state: encodedState(metadata, prior: prior, preserving: context.state))
        }
        let message = row["message"] as? [String: Any] ?? [:]
        // A subagent's sessionId identifies its parent; only a primary
        // transcript can inherit rows from another primary session.
        let recordedID = file.role == .session
            ? Self.id(row["sessionId"]).flatMap(UUID.init(uuidString:))?.uuidString.lowercased() : nil
        let owner = recordedID.map { SessionKey(agent: .claudeCode, nativeID: $0) } ?? key
        let ownership: RecordedSessionOwnership? = recordedID.map { $0 == key.nativeID ? .original : .inherited }
        if ownership != .inherited {
            metadata.cwd = Self.metadata(row["cwd"], maximum: 4096) ?? metadata.cwd
            metadata.branch = Self.metadata(row["gitBranch"], maximum: 1024) ?? metadata.branch
            metadata.version = Self.metadata(row["version"], maximum: 128) ?? metadata.version
            metadata.model = Self.metadata(message["model"], maximum: 256) ?? metadata.model
        }
        if let time {
            metadata.started = min(metadata.started ?? time, time)
            metadata.last = max(metadata.last ?? time, time)
        }

        func fileEventID() -> String { "file:\(file.sourceID):\(file.relativePath):\(frame.sequence)" }
        let eventID = Self.id(row["uuid"]) ?? fileEventID()
        var records: [NormalizedRecord] = [
            .session(.init(key: key, sourceID: file.sourceID, fileID: context.fileID, environment: environment,
                           cwd: metadata.cwd, startedAt: metadata.started, lastEventAt: metadata.last,
                           gitBranch: metadata.branch, cliVersion: metadata.version, model: metadata.model,
                           parentNativeID: parent))
        ]
        if ownership == .inherited {
            records.append(.session(.init(key: owner, sourceID: file.sourceID, environment: environment,
                                          referenceOnly: true)))
        }
        func event(_ kind: EventKind, _ body: String, index: Int = 0, tool: String? = nil,
                   metadata: String? = nil) -> NormalizedRecord {
            .event(.init(session: owner, sequence: frame.sequence, timestamp: time ?? 0, kind: kind,
                         toolName: tool, text: body, metadataJSON: metadata,
                         dedupeKey: "claude:event:\(eventID):\(index)", recordedOwnership: ownership))
        }

        var unknown = false
        var recoveredToolResult = false
        switch type {
        case "user", "assistant":
            let isUser = type == "user"
            let isMeta = (row["isMeta"] as? Bool) == true
            if !frame.isTruncated, let text = message["content"] as? String {
                if !isUser || !isMeta { records.append(event(isUser ? .user : .assistant, text)) }
            } else if let blocks = message["content"] as? [[String: Any]] {
                for (index, block) in blocks.prefix(240).enumerated() {
                    let blockType = block["type"] as? String
                    if frame.isTruncated && blockType != "tool_result" { continue }
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String, !isUser || !isMeta {
                            records.append(event(isUser ? .user : .assistant, text, index: index))
                        }
                    case "tool_use":
                        let input = block["input"] as? [String: Any] ?? [:]
                        let text = (input["command"] as? String) ?? (input["file_path"] as? String) ?? ""
                        records.append(event(.toolCall, Self.bounded(text, bytes: 2048), index: index,
                                             tool: Self.metadata(block["name"], maximum: 128),
                                             metadata: Self.toolMetadata(block["id"])))
                    case "tool_result":
                        recoveredToolResult = true
                        records.append(event(.toolResult, Self.bounded(Self.contentText(block["content"]), bytes: 2048),
                                             index: index, metadata: Self.toolMetadata(block["tool_use_id"],
                                                 isError: (block["is_error"] as? Bool) == true)))
                    case "thinking", "redacted_thinking":
                        break
                    default:
                        unknown = true
                    }
                }
                if blocks.count > 240 { unknown = true }
            } else {
                unknown = true
            }
            if !frame.isTruncated, !isUser, let usage = message["usage"] as? [String: Any], let counts = Self.counts(usage),
               let id = Self.id(message["id"]) ?? Self.id(row["requestId"]) ?? Self.id(row["uuid"]) {
                records.append(.tokens(.init(session: owner, timestamp: time ?? 0,
                                             model: Self.metadata(message["model"], maximum: 256),
                                             counts: counts, dedupeKey: "claude:response:\(id)", recordedOwnership: ownership)))
            }
        case "summary":
            if !frame.isTruncated, let text = row["summary"] as? String { records.append(event(.summary, text)) }
            else { unknown = true }
        case "system":
            if !frame.isTruncated {
                let text = Self.contentText(row["content"])
                if !text.isEmpty {
                    records.append(event(row["subtype"] as? String == "error" ? .error : .system, text))
                }
            }
        default:
            unknown = true
        }
        if frame.isTruncated && !recoveredToolResult { unknown = true }
        if unknown {
            let prefix = String(decoding: frame.bytes.prefix(2048), as: UTF8.self)
            // A partial or partially understood message can still contain thinking.
            // Keep the marker without indexing the unclassified message body.
            let safePrefix = object != nil && type != "assistant" && type != "user" &&
                !prefix.contains("\"thinking\"") && !prefix.contains("\"redacted_thinking\"") ? prefix : ""
            records.append(event(.unknown, Self.bounded(safePrefix, bytes: 2048), index: 240))
        }
        if frame.isTruncated, recoveredToolResult, let legacyEnd, frame.endOffset <= legacyEnd,
           try ClaudeV2OversizedJSON.lostRecord(from: frame) {
            // v2 could not read the recorded owner or UUID in this case. It
            // indexed an empty marker under this physical file's session.
            records.append(.removeEmptyPlaceholder(session: key, fileID: context.fileID, sequence: frame.sequence,
                                                   dedupeKey: "claude:event:\(fileEventID()):240"))
        }
        let state = encodedState(metadata, prior: prior, preserving: context.state)
        return .init(records: records, timestamp: parsedTime, state: state, isUnknown: unknown,
                     recoveredOversizedRecord: frame.isTruncated && recoveredToolResult)
    }

    private func history(_ frame: JSONLFrame, row: [String: Any]?,
                         context: JSONLDecodeContext) -> DecodedJSONLFrame {
        guard let row, let text = row["display"] as? String else {
            return .init(state: context.state, isUnknown: true)
        }
        let parsed = timestamp(row["timestamp"])
        let time = parsed ?? context.previousTimestamp
        let project = Self.metadata(row["project"], maximum: 4096)
        let key = SessionKey(agent: .claudeCode, nativeID: "history:\(file.sourceID):\(project ?? "")")
        return .init(records: [
            .session(.init(key: key, sourceID: file.sourceID, fileID: context.fileID,
                           environment: environment, cwd: project, startedAt: time, lastEventAt: time)),
            .event(.init(session: key, sequence: frame.sequence, timestamp: time ?? 0, kind: .promptHistory,
                         text: text, dedupeKey: "claude:history:\(file.sourceID):\(frame.sequence)")),
        ], timestamp: parsed)
    }

    private func load(_ state: Data?) -> Metadata {
        guard let state else { return Metadata() }
        if let cachedMetadata, cachedMetadata.0 == state { return cachedMetadata.1 }
        return (try? JSONDecoder().decode(Metadata.self, from: state)) ?? Metadata()
    }

    private mutating func encodedState(_ metadata: Metadata, prior: Metadata, preserving state: Data?) -> Data? {
        metadata == prior && state != nil ? state : encode(metadata)
    }

    private mutating func encode(_ metadata: Metadata) -> Data? {
        guard let state = try? JSONEncoder().encode(metadata) else { return nil }
        cachedMetadata = (state, metadata)
        return state
    }

    private func timestamp(_ raw: Any?) -> Int64? {
        if let text = raw as? String, let date = fractionalDate.date(from: text) ?? plainDate.date(from: text) {
            return Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded())
        }
        return Self.integer(raw)
    }

    private static func counts(_ usage: [String: Any]) -> TokenCounts? {
        guard let input = integer(usage["input_tokens"]), input >= 0,
              let output = integer(usage["output_tokens"]), output >= 0,
              let read = count(usage["cache_read_input_tokens"]),
              let aggregate = count(usage["cache_creation_input_tokens"])
        else { return nil }
        if let split = usage["cache_creation"] as? [String: Any],
           let short = count(split["ephemeral_5m_input_tokens"]),
           let long = count(split["ephemeral_1h_input_tokens"]) {
            let (total, overflow) = short.addingReportingOverflow(long)
            if !overflow, usage["cache_creation_input_tokens"] == nil || total == aggregate {
                return .init(inputFresh: input, cacheRead: read, cacheWrite: short, cacheWrite1h: long, output: output)
            }
        }
        return .init(inputFresh: input, cacheRead: read, cacheWrite: aggregate, output: output)
    }

    private static func count(_ raw: Any?) -> Int64? {
        guard raw != nil else { return 0 }
        guard let value = integer(raw), value >= 0 else { return nil }
        return value
    }

    private static func integer(_ raw: Any?) -> Int64? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return Int64(number.stringValue)
    }

    private static func contentText(_ raw: Any?) -> String {
        if let text = raw as? String { return text }
        return (raw as? [[String: Any]] ?? []).compactMap {
            $0["type"] as? String == "text" ? $0["text"] as? String : nil
        }.joined(separator: "\n")
    }

    private static func toolMetadata(_ id: Any?, isError: Bool = false) -> String? {
        var fields: [String: Any] = [:]
        if let id = Self.id(id) { fields["tool_use_id"] = id }
        if isError { fields["is_error"] = true }
        guard !fields.isEmpty, let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func id(_ raw: Any?) -> String? {
        guard let value = raw as? String, !value.isEmpty, value.utf8.count <= 256, !value.utf8.contains(0)
        else { return nil }
        return value
    }

    private static func metadata(_ raw: Any?, maximum: Int) -> String? {
        guard let text = raw as? String, !text.isEmpty, !text.utf8.contains(0) else { return nil }
        // Never clip a path or identifier into a different actionable value.
        return text.utf8.count <= maximum ? text : nil
    }

    private static func bounded(_ value: String, bytes: Int) -> String {
        let piece = value.utf8.prefix(bytes)
        for drop in 0...min(3, piece.count) {
            if let text = String(bytes: piece.dropLast(drop), encoding: .utf8) { return text }
        }
        return ""
    }

    private static func isEarlySnapshot(_ data: Data) -> Bool {
        data.starts(with: #"{ "type": "file-history-snapshot","#.utf8) ||
            data.starts(with: #"{"type":"file-history-snapshot","#.utf8)
    }
}
