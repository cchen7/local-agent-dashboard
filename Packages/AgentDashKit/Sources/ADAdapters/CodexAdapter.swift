import ADCore
import Foundation

/// Local Codex CLI and desktop rollouts (ADP-CX).
public struct CodexAdapter: AgentAdapter {
    public static let kind: AgentKind = .codex
    public static let parserVersion = 6
    public enum Failure: Error, Equatable, Sendable { case invalidSource, unsupportedFile }

    public init() {}

    public func discover(in source: Source, authorizedRoot: URL) throws -> [SourceFile] {
        let id = try sourceID(source)
        let children = try SourceFileReader.directoryEntries(root: authorizedRoot)
        var files: [SourceFile] = []
        func add(in folder: String) throws {
            for entry in try SourceFileReader.directoryEntries(root: authorizedRoot, in: folder)
            where entry.kind == .file && Self.isRollout(entry.name) {
                files.append(.init(sourceID: id, relativePath: folder + "/" + entry.name,
                                   role: .session, parserVersion: Self.parserVersion))
            }
        }
        func dates(in folder: String, widths: ArraySlice<Int>) throws {
            try Task.checkCancellation()
            guard let width = widths.first else { try add(in: folder); return }
            for entry in try SourceFileReader.directoryEntries(root: authorizedRoot, in: folder)
            where entry.kind == .directory && entry.name.utf8.count == width &&
                entry.name.utf8.allSatisfy({ (0x30...0x39).contains($0) }) {
                try dates(in: folder + "/" + entry.name, widths: widths.dropFirst())
            }
        }
        if children.contains(where: { $0.kind == .directory && $0.name == "sessions" }) {
            try dates(in: "sessions", widths: [4, 2, 2][...])
        }
        if children.contains(where: { $0.kind == .directory && $0.name == "archived_sessions" }) {
            try add(in: "archived_sessions")
        }
        return files.sorted { $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8) }
    }

    public func makeDecoder(for file: SourceFile, in source: Source) throws -> CodexRecordDecoder {
        guard try sourceID(source) == file.sourceID else { throw Failure.invalidSource }
        let components = file.relativePath.utf8.split(separator: 0x2F, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard file.role == .session, let name = components.last, Self.isRollout(name),
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.utf8.contains(0) }),
              (components.first == "archived_sessions" && components.count == 2) ||
                  (components.first == "sessions" && components.count == 5)
        else { throw Failure.unsupportedFile }
        return .init(file: file, source: source)
    }

    public func storageEncoding(for file: SourceFile) -> JSONLStorageEncoding {
        file.relativePath.hasSuffix(".jsonl.zst") ? .zstd : .plain
    }

    /// Copyable shell text, never executed by the app.
    public func resumeCommand(for session: SessionRecord) -> String? {
        guard session.key.agent == Self.kind, let cwd = session.cwd, cwd.hasPrefix("/"),
              !cwd.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              let id = UUID(uuidString: session.key.nativeID), let directory = AdapterJSON.shellArgument(cwd)
        else { return nil }
        return "cd \(directory) && codex resume \(id.uuidString.lowercased())"
    }

    private func sourceID(_ source: Source) throws -> Int64 {
        guard source.agent == Self.kind, let id = source.id else { throw Failure.invalidSource }
        return id
    }

    private static func isRollout(_ name: String) -> Bool {
        name.hasPrefix("rollout-") && (name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"))
    }
}

public struct CodexRecordDecoder: AgentFileDecoder {
    private struct Call: Codable, Equatable, Sendable { let id: String; let name: String }
    private var session: SessionRecord?
    private var lastCumulativeCount: Int64?
    private var preferredChannel = false
    private var recentCalls: [Call] = []

    private struct Saved: Codable, Equatable {
        var session: SessionRecord?
        var lastCumulativeCount: Int64?
        var preferredChannel = false
        var recentCalls: [Call] = []
    }

    private let file: SourceFile
    private let source: Source
    private var encodedState: Data?

    init(file: SourceFile, source: Source) {
        self.file = file
        self.source = source
    }

    private var saved: Saved {
        .init(session: session, lastCumulativeCount: lastCumulativeCount,
              preferredChannel: preferredChannel, recentCalls: recentCalls)
    }

    public mutating func decode(_ frame: JSONLFrame, context: JSONLDecodeContext) -> DecodedJSONLFrame {
        if context.state != encodedState {
            let restored = context.state.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
            session = restored.session
            lastCumulativeCount = restored.lastCumulativeCount
            preferredChannel = restored.preferredChannel
            recentCalls = restored.recentCalls
            encodedState = context.state
        }
        let prior = saved
        let object = frame.isTruncated ? nil : AdapterJSON.object(frame.bytes)
        let timestamp = AdapterJSON.timestamp(object?["timestamp"])
        let time = timestamp ?? context.previousTimestamp ?? 0
        let payload = object?["payload"] as? AdapterJSON.Object ?? [:]
        let type = object?["type"] as? String
        if frame.sequence == 0 {
            guard type == "session_meta", let metadata = sessionMeta(payload, context: context, timestamp: timestamp) else {
                return .init(state: nil, isUnknown: true)
            }
            session = metadata
            return finish([.session(metadata)], timestamp: timestamp, prior: prior)
        }
        guard var metadata = session else { return .init() }
        let previous = metadata
        if let timestamp { metadata.lastEventAt = max(metadata.lastEventAt ?? timestamp, timestamp) }
        var records: [NormalizedRecord] = []
        func event(_ kind: EventKind, _ text: String?, tool: String? = nil, meta: String? = nil,
                   channel: TranscriptChannel? = nil, toolOutput: ToolOutputCapture? = nil,
                   toolInput: ToolInputCapture? = nil, toolAction: ToolActionEvidence? = nil) -> NormalizedRecord {
            .event(.init(session: previous.key, sequence: frame.sequence, timestamp: time, kind: kind,
                         toolName: tool, text: text, metadataJSON: meta,
                         dedupeKey: Self.key(previous.key, line: frame.sequence, suffix: "event"), transcriptChannel: channel,
                         toolOutput: toolOutput, toolInput: toolInput, toolAction: toolAction))
        }
        func unknown() -> NormalizedRecord {
            // Do not persist partial/unclassified model-facing payloads.
            event(.unknown, nil)
        }
        switch type {
        case "turn_context":
            metadata.model = AdapterJSON.string(payload["model"], bounded: 160) ?? metadata.model
            metadata.cwd = Self.workspace(payload["cwd"]) ?? metadata.cwd
        case "event_msg":
            switch payload["type"] as? String {
            case "user_message", "agent_message":
                if let text = AdapterJSON.string(payload["message"]) {
                    let user = payload["type"] as? String == "user_message"
                    preferredChannel = true
                    records.append(event(user ? .user : .assistant, text, channel: .preferred))
                } else { records.append(unknown()) }
            case "token_count":
                records.append(contentsOf: Self.rateLimits(payload["rate_limits"], session: metadata, time: time))
                if let info = payload["info"] as? AdapterJSON.Object {
                    let cumulative = (info["total_token_usage"] as? AdapterJSON.Object).flatMap { Self.nonnegative($0["total_tokens"]) }
                    if let counts = Self.counts(info["last_token_usage"]) {
                        let observed = Self.nonnegative(info["model_context_window"]).flatMap { $0 > 0 ? $0 : nil }
                        let sameModel: Bool
                        if let measuredModel = metadata.contextModel, let currentModel = metadata.model {
                            sameModel = measuredModel.utf8.elementsEqual(currentModel.utf8)
                        } else {
                            sameModel = metadata.contextModel == nil && metadata.model == nil
                        }
                        metadata.contextWindow = observed ?? (sameModel ? metadata.contextWindow : nil)
                        metadata.contextUsed = counts.input
                        metadata.contextModel = metadata.model
                        if cumulative == nil || cumulative != lastCumulativeCount {
                            records.append(.tokens(.init(session: metadata.key, timestamp: time, model: metadata.model, counts: counts,
                                                         dedupeKey: Self.key(metadata.key, line: frame.sequence, suffix: "usage"))))
                        }
                        if let cumulative { lastCumulativeCount = cumulative }
                    }
                }
            case "task_started": records.append(event(.system, nil, meta: AdapterJSON.json(["signal": "task_started"])))
            case "task_complete":
                var meta: AdapterJSON.Object = ["signal": "task_complete"]
                if let duration = Self.nonnegative(payload["duration_ms"]) { meta["duration_ms"] = duration }
                records.append(event(.system, AdapterJSON.string(payload["last_agent_message"], bounded: 2048), meta: AdapterJSON.json(meta)))
            case "exec_command_end", "patch_apply_end":
                var meta: AdapterJSON.Object = [:]
                for field in ["call_id", "exit_code"] { meta[field] = payload[field] }
                let outcome = payload["type"] as? String == "exec_command_end"
                    ? ToolActionDecoder.completion(exitCode: payload["exit_code"], durationMS: payload["duration_ms"], success: payload["success"])
                    : nil
                records.append(event(.system, nil, meta: AdapterJSON.json(meta), toolAction: outcome))
            case "error", "stream_error": records.append(event(.error, AdapterJSON.string(payload["message"], bounded: 2048)))
            case "agent_reasoning", "agent_reasoning_raw_content": break
            default: records.append(unknown())
            }
        case "response_item":
            switch payload["type"] as? String {
            case "message":
                if !preferredChannel, let role = payload["role"] as? String, role == "user" || role == "assistant",
                   let text = Self.responseText(payload["content"], user: role == "user") {
                    let user = role == "user"
                    records.append(event(user ? .user : .assistant, text, channel: .fallback))
                }
            case "function_call", "custom_tool_call":
                guard let name = AdapterJSON.string(payload["name"], bounded: 160) else { records.append(unknown()); break }
                let namespace = AdapterJSON.string(payload["namespace"], bounded: 128)
                let tool = AdapterJSON.prefix(namespace.map { "mcp__\($0)__\(name)" } ?? name, bytes: 160)
                let callID = AdapterJSON.string(payload["call_id"], bounded: 160)
                if let callID { remember(callID, name: tool) }
                let args = AdapterJSON.string(payload["arguments"] ?? payload["input"]) ?? ""
                records.append(event(.toolCall, AdapterJSON.prefix(args, bytes: 2048), tool: tool,
                                     meta: Self.toolMetadata(callID, tool: name, arguments: args),
                                     toolInput: args.utf8.count > ToolOutputCapture.searchableBytes ? .init(.codex) : nil,
                                     toolAction: namespace == nil || namespace == "functions" ? ToolActionDecoder.codex(name: name, arguments: args) : nil))
            case "function_call_output", "custom_tool_call_output":
                let callID = AdapterJSON.string(payload["call_id"], bounded: 160)
                let tool = recentCalls.last { $0.id == callID }?.name
                let body = ToolOutputText.codex(payload["output"])
                records.append(event(.toolResult, body.map { AdapterJSON.prefix($0, bytes: ToolOutputCapture.searchableBytes) },
                                     tool: tool, meta: callID.flatMap { AdapterJSON.json(["call_id": $0]) },
                                     toolOutput: body.flatMap { .init(format: .codex, text: $0) }))
            case "reasoning": break
            default: records.append(unknown())
            }
        case "compacted": records.append(event(.summary, AdapterJSON.string(payload["message"], bounded: 2048)))
        case "session_meta": break
        default: records.append(unknown())
        }
        session = metadata
        if metadata != previous { records.insert(.session(metadata), at: 0) }
        return finish(records, timestamp: timestamp, prior: prior)
    }

    private func sessionMeta(_ payload: AdapterJSON.Object, context: JSONLDecodeContext, timestamp: Int64?) -> SessionRecord? {
        guard let id = AdapterJSON.string(payload["id"]), id.utf8.count <= 256, !id.utf8.contains(0) else { return nil }
        let provider = AdapterJSON.string(payload["model_provider"], bounded: 160)
        let originator = AdapterJSON.string(payload["originator"], bounded: 160)
        let fields = ["model_provider": provider, "originator": originator, "source": AdapterJSON.string(payload["source"], bounded: 160)]
        let environment = source.environmentRules.first { fields[$0.field, default: nil] == $0.equals }?.environment
            ?? source.environment
        let git = payload["git"] as? AdapterJSON.Object ?? [:]
        let parentSource = (payload["source"] as? AdapterJSON.Object)?["subagent"] as? AdapterJSON.Object
        let spawn = parentSource?["thread_spawn"] as? AdapterJSON.Object
        let parent = AdapterJSON.string(spawn?["parent_thread_id"], bounded: 256)
        return SessionRecord(key: .init(agent: .codex, nativeID: id), sourceID: file.sourceID, fileID: context.fileID,
                             environment: AdapterJSON.prefix(environment, bytes: 256), cwd: Self.workspace(payload["cwd"]),
                             startedAt: timestamp, lastEventAt: timestamp, gitBranch: AdapterJSON.string(git["branch"], bounded: 256),
                             cliVersion: AdapterJSON.string(payload["cli_version"], bounded: 128),
                             parentNativeID: parent, entrypoint: originator, modelProvider: provider,
                             gitSHA: AdapterJSON.string(git["commit_hash"], bounded: 128))
    }

    private static func key(_ session: SessionKey, line: Int64, suffix: String) -> String {
        "cx:\(session.nativeID.utf8.count):\(session.nativeID):\(line):\(suffix)"
    }

    private static func nonnegative(_ value: Any?) -> Int64? {
        guard let value = AdapterJSON.integer(value), value >= 0 else { return nil }
        return value
    }

    private static func counts(_ value: Any?) -> TokenCounts? {
        guard let usage = value as? AdapterJSON.Object,
              let input = nonnegative(usage["input_tokens"]), let output = nonnegative(usage["output_tokens"]) else { return nil }
        let cached = usage["cached_input_tokens"] == nil ? 0 : nonnegative(usage["cached_input_tokens"])
        let reasoning = usage["reasoning_output_tokens"] == nil ? 0 : nonnegative(usage["reasoning_output_tokens"])
        guard let cached, let reasoning, cached <= input, reasoning <= output,
              !input.addingReportingOverflow(output).overflow else { return nil }
        return TokenCounts(inputFresh: input - cached, cacheRead: cached, output: output, reasoning: reasoning)
    }

    private static func rateLimits(_ value: Any?, session: SessionRecord, time: Int64) -> [NormalizedRecord] {
        guard let value = value as? AdapterJSON.Object else { return [] }
        let configured = AdapterJSON.string(value["limit_id"], bounded: 160) ?? "default"
        let limitID = "\(session.sourceID):\(session.modelProvider ?? "unknown"):\(configured)"
        return [RateLimitSnapshot.Window.primary, .secondary].compactMap { window in
            guard let limit = value[window.rawValue] as? AdapterJSON.Object else { return nil }
            let percent = AdapterJSON.finiteNumber(limit["used_percent"]).flatMap { $0 >= 0 ? $0 : nil }
            let reset = nonnegative(limit["resets_at"]).flatMap { value -> Int64? in
                let result = value.multipliedReportingOverflow(by: 1000)
                return result.overflow ? nil : result.partialValue
            }
            return .rateLimit(.init(agent: .codex, limitID: limitID, window: window, timestamp: time,
                                    windowMinutes: nonnegative(limit["window_minutes"]), usedPercent: percent, resetsAt: reset,
                                    planType: AdapterJSON.string(value["plan_type"], bounded: 80)))
        }
    }

    private mutating func finish(_ records: [NormalizedRecord], timestamp: Int64?,
                                 prior: Saved) -> DecodedJSONLFrame {
        if prior != saved || encodedState == nil {
            encodedState = try? JSONEncoder().encode(saved)
        }
        let unknown = records.contains {
            if case .event(let event) = $0 { return event.kind == .unknown }
            return false
        }
        return .init(records: records, timestamp: timestamp, state: encodedState, isUnknown: unknown)
    }

    private static func workspace(_ value: Any?) -> String? {
        guard let value = AdapterJSON.string(value), value.utf8.count <= 4096, !value.utf8.contains(0)
        else { return nil }
        return value
    }

    private static func responseText(_ value: Any?, user: Bool) -> String? {
        guard let content = value as? [AdapterJSON.Object] else { return nil }
        let text = content.compactMap { block -> String? in
            guard block["type"] as? String == (user ? "input_text" : "output_text"),
                  let text = AdapterJSON.string(block["text"]) else { return nil }
            if user {
                let leading = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if ["<environment_context>", "<user_instructions>", "<permissions instructions>"].contains(where: { leading.hasPrefix($0) }) {
                    return nil
                }
                if leading.hasPrefix("# AGENTS.md instructions") && leading.contains("<INSTRUCTIONS>") { return nil }
            }
            return text
        }.joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    private mutating func remember(_ id: String, name: String) {
        recentCalls.removeAll { $0.id == id }
        if recentCalls.count == 64 { recentCalls.removeFirst() }
        recentCalls.append(Call(id: id, name: name))
    }

    private static func toolMetadata(_ id: String?, tool: String, arguments: String) -> String? {
        var metadata: AdapterJSON.Object = [:]
        if let id { metadata["call_id"] = id }
        if tool == "exec_command", let args = AdapterJSON.object(Data(arguments.utf8)),
           let command = AdapterJSON.string(args["cmd"], bounded: 2048) { metadata["command"] = command }
        if tool == "apply_patch" {
            let paths = arguments.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
                for header in ["*** Add File: ", "*** Update File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(header) {
                    return AdapterJSON.prefix(String(line.dropFirst(header.count)), bytes: 256)
                }
                return nil
            }
            let files = Array(paths.prefix(16))
            if !files.isEmpty { metadata["files"] = files }
        }
        return metadata.isEmpty ? nil : AdapterJSON.json(metadata)
    }
}
