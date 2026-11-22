import ADCore
import CoreFoundation
import Foundation

/// GitHub Copilot CLI's append-only event stream (ADP-CP).
public struct CopilotAdapter: AgentAdapter {
    public static let kind: AgentKind = .copilot
    public static let parserVersion = 4
    public enum Failure: Error, Equatable, Sendable { case invalidSource, unsupportedFile }

    public init() {}

    public func discover(in source: Source, authorizedRoot: URL) throws -> [SourceFile] {
        guard source.agent == Self.kind, let id = source.id else { throw Failure.invalidSource }
        let root = try SourceFileReader.directoryEntries(root: authorizedRoot)
        guard root.contains(where: { $0.kind == .directory && $0.name == "session-state" }) else { return [] }
        let folders = try SourceFileReader.directoryEntries(root: authorizedRoot, in: "session-state")
        var files: [SourceFile] = []
        for folder in folders where folder.kind == .directory && !folder.name.hasPrefix(".") {
            try Task.checkCancellation()
            let path = "session-state/" + folder.name
            let entries = try SourceFileReader.directoryEntries(root: authorizedRoot, in: path)
            if entries.contains(where: { $0.kind == .file && $0.name == "events.jsonl" }) {
                files.append(.init(sourceID: id, relativePath: path + "/events.jsonl", role: .session,
                                   parserVersion: Self.parserVersion))
            }
        }
        return files.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    public func makeDecoder(for file: SourceFile, in source: Source) throws -> CopilotRecordDecoder {
        guard source.agent == Self.kind, source.id == file.sourceID else { throw Failure.invalidSource }
        let parts = file.relativePath.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard file.role == .session, parts.count == 3, parts[0] == "session-state", parts[2] == "events.jsonl",
              !parts[1].isEmpty, !parts[1].hasPrefix("."), !parts[1].utf8.contains(0) else { throw Failure.unsupportedFile }
        return .init(file: file, environment: source.environment, folderID: parts[1])
    }

    public func resumeCommand(for session: SessionRecord) -> String? {
        guard session.key.agent == Self.kind, let cwd = session.cwd, cwd.hasPrefix("/"),
              !session.key.nativeID.hasPrefix("-"),
              !cwd.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !session.key.nativeID.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              let directory = AdapterJSON.shellArgument(cwd), let id = AdapterJSON.shellArgument(session.key.nativeID)
        else { return nil }
        return "cd \(directory) && copilot --resume \(id)"
    }
}

public struct CopilotRecordDecoder: AgentFileDecoder {
    private struct Call: Codable, Equatable, Sendable { let id: String; let name: String }
    private struct Saved: Codable, Equatable, Sendable {
        var session: SessionRecord?
        var recentCalls: [Call] = []
    }

    private let file: SourceFile
    private let environment: String
    private let folderID: String
    private var state = Saved()
    private var encodedState: Data?

    init(file: SourceFile, environment: String, folderID: String) {
        self.file = file; self.environment = environment; self.folderID = folderID
    }

    public mutating func decode(_ frame: JSONLFrame, context: JSONLDecodeContext) -> DecodedJSONLFrame {
        if context.state != encodedState {
            state = context.state.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
            recentCalls = state.recentCalls
            encodedState = context.state
        }
        let prior = state
        let object = frame.isTruncated ? nil : AdapterJSON.object(frame.bytes)
        let data = object?["data"] as? AdapterJSON.Object ?? [:]
        let type = object?["type"] as? String
        let stamp = AdapterJSON.timestamp(object?["timestamp"])
            ?? (type == "session.start" ? AdapterJSON.timestamp(data["startTime"]) : nil)
        let time = stamp ?? context.previousTimestamp ?? 0
        if state.session == nil && object == nil {
            return .init(timestamp: stamp, state: context.state, isUnknown: true)
        }
        let id = (type == "session.start" ? Self.identifier(data["sessionId"]) : nil) ?? folderID
        var metadata = state.session ?? SessionRecord(key: .init(agent: .copilot, nativeID: id),
            sourceID: file.sourceID, fileID: context.fileID, environment: environment,
            startedAt: stamp, lastEventAt: stamp)
        if let stamp { metadata.lastEventAt = max(metadata.lastEventAt ?? stamp, stamp) }
        let key = metadata.key
        let lineID = Self.identifier(object?["id"]).map { "id:\($0.utf8.count):\($0)" } ?? "pos:\(frame.sequence)"
        let eventKey = "cp:\(key.nativeID.utf8.count):\(key.nativeID):\(lineID)"
        let child = Self.identifier(object?["agentId"]) != nil
        var unknown = false
        func event(_ kind: EventKind, _ text: String? = nil, tool: String? = nil,
                   fields: AdapterJSON.Object = [:], toolOutput: ToolOutputCapture? = nil,
                   toolInput: ToolInputCapture? = nil, toolAction: ToolActionEvidence? = nil) -> NormalizedRecord {
            var hints = fields
            if child { hints["child_activity"] = true }
            return .event(.init(session: key, sequence: frame.sequence, timestamp: time, kind: kind,
                toolName: tool, text: text, metadataJSON: hints.isEmpty ? nil : AdapterJSON.json(hints),
                dedupeKey: "\(eventKey):\(kind == .unknown ? "unknown" : "event")",
                toolOutput: toolOutput, toolInput: toolInput, toolAction: toolAction))
        }
        var records: [NormalizedRecord] = []
        switch type {
        case "session.start", "session.context_changed", "session.resume":
            if !child {
                let settings = data["context"] as? AdapterJSON.Object ?? [:]
                metadata.cwd = AdapterJSON.string(settings["cwd"] ?? data["cwd"], bounded: 4096) ?? metadata.cwd
                metadata.gitBranch = AdapterJSON.string(settings["branch"] ?? settings["gitBranch"], bounded: 256) ?? metadata.gitBranch
                metadata.entrypoint = AdapterJSON.string(data["producer"], bounded: 160) ?? metadata.entrypoint
                metadata.cliVersion = AdapterJSON.string(data["copilotVersion"], bounded: 128) ?? metadata.cliVersion
                metadata.model = Self.model(in: data) ?? metadata.model
            }
            if let type { records.append(event(.system, fields: ["signal": type])) }
        case "session.model_change":
            if !child {
                metadata.model = AdapterJSON.string(data["newModel"], bounded: 160) ?? Self.model(in: data) ?? metadata.model
            }
        case "user.message", "assistant.message":
            if let text = AdapterJSON.string(data["content"]) {
                let user = type == "user.message"
                if user && metadata.title == nil && !child {
                    metadata.title = AdapterJSON.prefix(text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text, bytes: 320)
                }
                records.append(event(user ? .user : .assistant, text))
            } else { unknown = true }
        case "tool.execution_start":
            if let name = AdapterJSON.string(data["toolName"], bounded: 160) {
                let id = Self.identifier(data["toolCallId"])
                if let id { remember(id, name: name) }
                let arguments = AdapterJSON.string(data["arguments"])
                    ?? (data["arguments"] as? AdapterJSON.Object).flatMap(AdapterJSON.json)
                let preview = arguments.map { AdapterJSON.prefix($0, bytes: ToolOutputCapture.searchableBytes) }
                let long = (arguments?.utf8.count ?? 0) > ToolOutputCapture.searchableBytes
                records.append(event(.toolCall, preview, tool: name, fields: id.map { ["call_id": $0] } ?? [:],
                                     toolInput: long ? .init(.copilot) : nil,
                                     toolAction: (data["arguments"] as? AdapterJSON.Object).flatMap {
                                         ToolActionDecoder.copilot(name: name, arguments: $0)
                                     }))
            } else { unknown = true }
        case "tool.execution_complete":
            let id = Self.identifier(data["toolCallId"])
            let body = ToolOutputText.copilot(data["result"])
            let text = body.map { AdapterJSON.prefix($0, bytes: ToolOutputCapture.searchableBytes) }
            let tool = recentCalls.last { $0.id == id }?.name
            var fields: AdapterJSON.Object = [:]
            if let success = Self.boolean(data["success"]) { fields["success"] = success }
            if let id { fields["call_id"] = id }
            records.append(event(.toolResult, text, tool: tool, fields: fields,
                                 toolOutput: body.flatMap { .init(format: .copilot, text: $0) },
                                 toolAction: ToolActionDecoder.completion(success: data["success"])))
        case "session.task_complete", "session.compaction_complete":
            var fields: AdapterJSON.Object = ["signal": type ?? ""]
            if let success = Self.boolean(data["success"]) { fields["success"] = success }
            records.append(event(.summary, AdapterJSON.string(data["summary"], bounded: 2048), fields: fields))
        case "session.usage_record":
            if !child {
                let usage = data["usage"] as? AdapterJSON.Object ?? data
                if let counts = Self.counts(usage), let model = Self.model(in: data) ?? metadata.model {
                    records.append(.tokens(.init(session: key, timestamp: time, model: model, counts: counts,
                        dedupeKey: "\(eventKey):call", sourceSequence: frame.sequence)))
                } else { unknown = true }
            }
        case "session.shutdown", "session.usage_checkpoint":
            if type == "session.shutdown" { records.append(event(.system, fields: ["signal": "session.shutdown"])) }
            if !child, let metrics = data["modelMetrics"] as? AdapterJSON.Object {
                // Bound the number of generated rows below the importer's
                // per-frame maximum. Retain no unrecognized raw fields.
                if metrics.count > 256 { unknown = true }
                for (model, value) in metrics.sorted(by: { $0.key < $1.key }).prefix(256) {
                    guard Self.identifier(model) != nil, model.utf8.count <= 160,
                          let item = value as? AdapterJSON.Object, let usage = item["usage"] as? AdapterJSON.Object,
                          let counts = Self.counts(usage) else { unknown = true; continue }
                    records.append(.copilotUsageSnapshot(.init(session: key, model: model,
                        sequence: frame.sequence, timestamp: time, counts: counts, dedupeKey: "\(eventKey):checkpoint:\(model)")))
                }
            }
        case "assistant.turn_start", "assistant.turn_end", "subagent.started", "subagent.completed", "skill.invoked":
            if let type { records.append(event(.system, fields: ["signal": type])) }
        default: unknown = true
        }
        if unknown { records.append(event(.unknown, fields: ["unrecognized": true])) }
        state.session = metadata
        state.recentCalls = recentCalls
        if metadata != prior.session { records.insert(.session(metadata), at: 0) }
        if state != prior {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encodedState = try? encoder.encode(state)
        }
        return .init(records: records, timestamp: stamp, state: encodedState, isUnknown: unknown)
    }

    private var recentCalls: [Call] = []

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let id = AdapterJSON.string(value), id.utf8.count <= 256, !id.utf8.contains(0) else { return nil }
        return id
    }

    private static func model(in data: AdapterJSON.Object) -> String? {
        AdapterJSON.string(data["modelId"] ?? data["model"], bounded: 160)
    }

    private mutating func remember(_ id: String, name: String) {
        recentCalls.removeAll { $0.id == id }
        if recentCalls.count == 64 { recentCalls.removeFirst() }
        recentCalls.append(.init(id: id, name: name))
    }

    private static func counts(_ usage: AdapterJSON.Object) -> TokenCounts? {
        func numeric(_ key: String, default fallback: Int64? = nil) -> Int64? {
            let value = usage[key] == nil ? fallback : AdapterJSON.integer(usage[key])
            return value.flatMap { $0 >= 0 ? $0 : nil }
        }
        guard let input = numeric("inputTokens"), let read = numeric("cacheReadTokens", default: 0),
              let write = numeric("cacheWriteTokens", default: 0), let output = numeric("outputTokens"),
              let reasoning = numeric("reasoningTokens", default: 0), read <= input, write <= input - read,
              reasoning <= output, !input.addingReportingOverflow(output).overflow else { return nil }
        return TokenCounts(inputFresh: input - read - write, cacheRead: read, cacheWrite: write, output: output, reasoning: reasoning)
    }
}
