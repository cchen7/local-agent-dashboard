#if AGENTDASH_SYNTHETIC_ONLY
import ADCore
import ADPricing
import ADStore
import Foundation

/// Preview data for the isolated SyntheticQA bundle only. Debug and Release
/// builds compile none of it and refuse `--synthetic` (DEV-083, DEV-107).
extension DashboardModel {
    nonisolated static func installSyntheticFixtures(in directory: URL, store: AgentStore,
                                                              previewUsage: Bool) throws {
        let args = CommandLine.arguments
        let env = ProcessInfo.processInfo.environment
        if previewUsage { try prepareUsageFixture(in: directory, store: store) }
        if args.contains("--synthetic-indexing-source") || env["AGENTDASH_SYNTHETIC_INDEXING_SOURCE"] == "1" {
            try prepareIndexingFixture(in: directory, store: store)
        }
        if args.contains("--synthetic-indexing-codex") || env["AGENTDASH_SYNTHETIC_CODEX_SOURCE"] == "1" {
            try prepareCodexIndexingFixture(in: directory, store: store)
        }
        if args.contains("--synthetic-indexing-copilot") {
            try prepareCopilotIndexingFixture(in: directory, store: store)
        }
        if syntheticActivity {
            try seedSessionActivity(store, in: directory)
        } else if env["AGENTDASH_SYNTHETIC_TOOL_PAIR"] == "1" {
            try seedTranscriptToolPair(store, in: directory)
        } else if args.contains("--synthetic-projects") {
            try seedProjects(store, fixtureRoot: directory)
        } else if args.contains("--synthetic-sessions") {
            try seedSessions(store, in: directory)
        }
        if args.contains("--synthetic-index-status") || env["AGENTDASH_SYNTHETIC_INDEX_STATUS"] == "1" {
            try seedIndexStatus(store, in: directory)
        }
        if env["AGENTDASH_SYNTHETIC_SEARCH_FILTERS"] == "1" {
            try store.saveSessionSearch(name: "Synthetic filtered group", query: #" 登录 role:"assistant" agent:codex "#,
                                        order: .recent, libraryFilter: .agent(.codex))
        }
    }

    nonisolated private static func seedIndexStatus(_ store: AgentStore, in directory: URL) throws {
        let sourceID = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic indexed source",
            rootURL: directory.appendingPathComponent("unused-status-root"), environment: "Synthetic"))
        let fileID = try store.upsertFile(.init(sourceID: sourceID, relativePath: "projects/synthetic.jsonl", role: .session),
                                         checkpoint: nil)
        _ = try store.upsertFile(.init(sourceID: sourceID, relativePath: "projects/pending.jsonl", role: .session),
                                 checkpoint: nil)
        let session = SessionKey(agent: .claudeCode, nativeID: "preview-source-status")
        try store.commitFileBatch([
            .session(.init(key: session, sourceID: sourceID, fileID: fileID, environment: "Synthetic")),
        ], for: fileID, from: nil, to: .init(inode: 11, size: 20, offset: 15, parserVersion: 1,
                                             sequence: 3, previousTimestamp: nil, unknownRecords: 3))
    }

    nonisolated private static func seedTranscriptToolPair(_ store: AgentStore, in directory: URL) throws {
        let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic tool pair",
            rootURL: directory.appendingPathComponent("unused-source")))
        let key = SessionKey(agent: .codex, nativeID: "preview-tool-pair")
        let time = Int64(Date().timeIntervalSince1970 * 1000)
        let preview = "Synthetic tool returned a result\nfoldedresult"
        let full = preview + "\nPAIR_TOKEN=synthetic-pair-secret\n" +
            "Synthetic archived output. " + String(repeating: "Archived detail. ", count: 170)
        var records: [NormalizedRecord] = [
            .session(.init(key: key, sourceID: source, environment: "Synthetic", cwd: "/synthetic/tool-pair",
                           title: "Synthetic folded tool", startedAt: time, lastEventAt: time)),
            .event(.init(session: key, sequence: 0, timestamp: time, kind: .toolCall, toolName: "exec_command",
                         text: #"{"cmd":"npm test -- auth","API_TOKEN":"synthetic-pair-input"}"#,
                         metadataJSON: #"{"call_id":"synthetic-pair"}"#,
                         dedupeKey: "preview:pair:call")),
        ]
        records += (1...130).map {
            .event(.init(session: key, sequence: Int64($0), timestamp: time, kind: .assistant,
                         text: "Synthetic interleaved message \($0)", dedupeKey: "preview:pair:filler:\($0)"))
        }
        records.append(.event(.init(session: key, sequence: 131, timestamp: time, kind: .toolResult,
            toolName: "exec_command", text: preview, metadataJSON: #"{"call_id":"synthetic-pair"}"#,
            dedupeKey: "preview:pair:result", toolOutput: .init(format: .codex, text: full))))
        try store.write(records)
    }

    nonisolated private static func seedSessionActivity(_ store: AgentStore, in directory: URL) throws {
        let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic activity",
            rootURL: directory.appendingPathComponent("unused-source")))
        let key = SessionKey(agent: .codex, nativeID: "preview-activity")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try store.write([
            .session(.init(key: key, sourceID: source, environment: "Synthetic", cwd: "/synthetic/live",
                           title: "Synthetic live activity", startedAt: now - 10_000, lastEventAt: now)),
            .event(.init(session: key, sequence: 1, timestamp: now, kind: .toolCall, toolName: "exec_command",
                         metadataJSON: #"{"call_id":"synthetic-call","command":"API_TOKEN='synthetic-activity-secret' npm test -- auth"}"#,
                         dedupeKey: "preview:activity:call")),
        ])
    }

    nonisolated private static func seedSessions(_ store: AgentStore, in directory: URL) throws {
        let sourceID = try store.upsertSource(.init(agent: .codex, label: "Synthetic",
            rootURL: directory.appendingPathComponent("unused-source"), environment: "Synthetic"))
        let primary = SessionKey(agent: .codex, nativeID: "preview-import")
        let other = SessionKey(agent: .codex, nativeID: "preview-docs")
        let realNow = Int64(Date().timeIntervalSince1970 * 1000)
        #if AGENTDASH_SYNTHETIC_ONLY
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_DETAIL_FACTS"] == "1" {
            try store.write([
                .session(.init(key: primary, sourceID: sourceID, environment: "Synthetic",
                               cwd: "/synthetic/detail", title: "Synthetic detail values",
                               startedAt: realNow, lastEventAt: realNow, status: .completed,
                               contextWindow: 999_999, contextUsed: 654_321)),
                .event(.init(session: primary, sequence: 0, timestamp: realNow,
                             kind: .user, text: "Review synthetic detail metrics", dedupeKey: "preview:detail:prompt")),
                .tokens(.init(session: primary, timestamp: 1_795_260_000_000, model: "gpt-6.1-sol",
                              counts: .init(inputFresh: 250_000_000, cacheRead: 210_000_000, output: 98_000),
                              dedupeKey: "preview:detail:usage")),
            ])
            return
        }
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_SESSION_TITLE"] == "1" {
            try store.write([
                .session(.init(key: primary, sourceID: sourceID, environment: "Synthetic",
                               cwd: "/synthetic/title", startedAt: realNow, lastEventAt: realNow)),
                .event(.init(session: primary, sequence: 0, timestamp: realNow, kind: .user,
                             text: "/clear", dedupeKey: "preview:title:command")),
                .event(.init(session: primary, sequence: 1, timestamp: realNow, kind: .user,
                             text: "排查合成会话的问题", dedupeKey: "preview:title:prompt")),
            ])
            return
        }
        #endif
        let knownClock = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_PRESENTATION_ID"] != nil
            ? Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 17, minute: 4)) : nil
        let now = knownClock.map { Int64($0.timeIntervalSince1970 * 1000) + 900_000 } ?? realNow
        var records: [NormalizedRecord] = [
            .session(.init(key: primary, sourceID: sourceID, environment: "Synthetic",
                           cwd: "/synthetic/projects/client", title: "Verify synthetic import",
                           startedAt: now - 900_000, lastEventAt: now, status: .completed)),
            .session(.init(key: other, sourceID: sourceID, environment: "Synthetic",
                           cwd: "/synthetic/projects/docs", title: "Review synthetic documentation",
                           startedAt: now - 3_600_000, status: .waiting)),
            .event(.init(session: other, sequence: 0, timestamp: now - 3_600_000, kind: .assistant,
                         text: "Documentation preview", dedupeKey: "preview:docs")),
        ]
        for i in 0..<400 {
            let text: String
            switch i {
            case 0: text = "API_TOKEN=synthetic-preview-only"
            case 12 where ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_NATIVE_CHINESE"] == "1":
                text = "中文输入 · Synthetic typing target"
            case 130: text = "修复登录问题 · Synthetic search target"
            case 260: text = "验证登录配置 · Second synthetic search target"
            case 395: text = "完成登录修复 · Final synthetic search target"
            default: text = "合成转录 · Synthetic message \(i)"
            }
            records.append(.event(.init(session: primary, sequence: Int64(i), timestamp: now - 60_000 + Int64(i),
                                       kind: i.isMultiple(of: 2) ? .user : .assistant,
                                       text: text, dedupeKey: "preview:import:\(i)")))
        }
        if let knownClock {
            // One known clock time and a separate live, cache-inclusive rate.
            records.append(.tokens(.init(session: primary, timestamp: realNow - 1_000, model: "fixture",
                                         counts: .init(inputFresh: 28, cacheRead: 10, output: 10),
                                         dedupeKey: "preview:presentation-rate")))
            records.append(.event(.init(session: primary, sequence: 401,
                                       timestamp: Int64(knownClock.timeIntervalSince1970 * 1000), kind: .user,
                                       text: "Fixed time example", dedupeKey: "preview:presentation-time")))
        }
        if CommandLine.arguments.contains("--synthetic-overview") ||
            ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_OVERVIEW"] == "1" {
            records.append(contentsOf: [
                .event(.init(session: primary, sequence: 1000, timestamp: now - 60_000, kind: .summary,
                             text: "Synthetic checkpoint verified", dedupeKey: "preview:overview:summary")),
                .event(.init(session: primary, sequence: 1001, timestamp: now - 4_000, kind: .toolResult,
                             toolName: "Synthetic check", text: "OVERVIEW_TOKEN=synthetic-overview-only",
                             dedupeKey: "preview:overview:tool")),
            ])
        }
        try store.write(records)
    }

    nonisolated private static func prepareUsageFixture(in directory: URL, store: AgentStore) throws {
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var records: [NormalizedRecord] = []
        for (index, agent, model) in [(0, AgentKind.claudeCode, "claude-haiku-5-5"), (1, .codex, "gpt-6.2-sol")] {
            let sourceID = try store.upsertSource(.init(agent: agent, label: "Synthetic usage",
                rootURL: directory.appendingPathComponent("synthetic-usage-\(index)"), environment: "Synthetic"))
            let key = SessionKey(agent: agent, nativeID: "preview-usage-\(index)")
            records.append(.session(.init(key: key, sourceID: sourceID, environment: "Synthetic")))
            for sample in 0..<90 {
                let timestamp = now - Int64(90 - sample) * 300_000 + Int64(index) * 10_000
                let spike = (sample % 18) * (index + 2)
                let fresh = 100 + spike * 40
                let counts = TokenCounts(inputFresh: Int64(fresh), cacheRead: Int64(fresh * 2),
                                         cacheWrite: Int64(25 + spike), output: Int64(50 + spike * 12))
                records.append(.tokens(.init(session: key, timestamp: timestamp,
                    model: sample == 0 ? "synthetic-unpriced" : model, counts: counts,
                    dedupeKey: "preview-usage:\(index):\(sample)")))
            }
        }
        #if AGENTDASH_SYNTHETIC_ONLY
        let resetAfter: Int64 = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_LIMIT_EXPIRY"] == "1"
            ? 16_000 : 3_600_000
        #else
        let resetAfter: Int64 = 3_600_000
        #endif
        records.append(.rateLimit(.init(agent: .codex, limitID: "synthetic-preview", window: .primary,
                                        timestamp: now - 60_000, windowMinutes: 300, usedPercent: 42,
                                        resetsAt: now + resetAfter, planType: "Synthetic")))
        try store.write(records)
    }

    nonisolated private static func seedProjects(_ store: AgentStore, fixtureRoot: URL) throws {
        let home = URL(fileURLWithPath: "/synthetic")
        let codex = try store.upsertSource(.init(agent: .codex, label: "Synthetic Codex",
            rootURL: home.appendingPathComponent(AgentKind.codex.defaultSourceDirectoryName)))
        let claude = try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic Claude",
            rootURL: home.appendingPathComponent(AgentKind.claudeCode.defaultSourceDirectoryName)))
        let client: String
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_PROJECT_DIRECTORY"] == "1" {
            let folder = fixtureRoot.appendingPathComponent("synthetic-project")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            client = folder.resolvingSymlinksInPath().path
        } else { client = "/synthetic/work/client" }
        let primary = SessionKey(agent: .codex, nativeID: "preview-project-client")
        let peer = SessionKey(agent: .claudeCode, nativeID: "preview-project-worktree")
        let docs = SessionKey(agent: .codex, nativeID: "preview-project-docs")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let grouping = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_SESSION_GROUPING"] == "1"
        let groupingSearch = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_GROUPING_SEARCH"] == "1"
        let docsActivity = now - (grouping ? 10_000 : 120_000)
        var records: [NormalizedRecord] = [
            .session(.init(key: primary, sourceID: codex, environment: "Local",
                           cwd: client, title: "Verify synthetic checkout",
                           startedAt: now - 900_000, lastEventAt: now, status: .completed, gitBranch: "main")),
            .session(.init(key: peer, sourceID: claude, environment: "Local",
                           cwd: client + "/.claude/worktrees/demo", title: "Validate synthetic integration",
                           startedAt: now - 800_000, lastEventAt: now - 30_000, status: .running, gitBranch: "demo")),
            .session(.init(key: docs, sourceID: codex, environment: "Local",
                           cwd: "/synthetic/work/docs", title: "Review synthetic documentation",
                           startedAt: now - 2_000_000, lastEventAt: docsActivity, status: .waiting)),
            .event(.init(session: primary, sequence: 0, timestamp: now, kind: .assistant,
                         text: "Synthetic checkout verified", dedupeKey: "preview:project:checkout")),
            .event(.init(session: peer, sequence: 0, timestamp: now - 30_000, kind: .toolResult,
                         toolName: "Synthetic check", text: "PROJECT_TOKEN=synthetic-project-secret",
                         dedupeKey: "preview:project:worktree")),
            .event(.init(session: docs, sequence: 0, timestamp: docsActivity, kind: .assistant,
                         text: "Synthetic documentation reviewed", dedupeKey: "preview:project:docs")),
        ]
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_PROJECT_ACTIONS"] == "1" {
            let call = #"{"tool_use_id":"synthetic-project-call"}"#
            records += [
                .event(.init(session: peer, sequence: 1, timestamp: now + 1, kind: .toolCall, toolName: "Bash",
                             text: "Synthetic command preview", metadataJSON: call, dedupeKey: "preview:project:command",
                             toolAction: .init(command: "API_TOKEN='synthetic-project-action-secret' synthetic diagnostic"))),
                .event(.init(session: peer, sequence: 2, timestamp: now + 3, kind: .toolResult,
                             metadataJSON: call, dedupeKey: "preview:project:completion",
                             toolAction: .init(completion: .init(exitCode: 2, durationMS: 967, success: false)))),
                .event(.init(session: primary, sequence: 1, timestamp: now + 2, kind: .toolCall, toolName: "apply_patch",
                             text: "Synthetic patch preview", dedupeKey: "preview:project:patch",
                             toolAction: .init(files: [
                                 .init(path: "/synthetic/edited.swift", operation: .edit, added: 4, removed: 3)
                             ]))),
            ]
        }
        let listUsage = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_LIST_USAGE"] == "1"
        if listUsage || ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_PROJECT_USAGE"] == "1" {
            let price = try PriceTable.decode(Data(#"{"schemaVersion":1,"currency":"USD","unit":"per_million_tokens","updatedAt":"2026-01-01","models":[{"id":"project-fixture-priced","vendor":"fixture","displayName":"Synthetic","prices":[{"effectiveFrom":"2020-01-01","input":4,"output":2,"cacheRead":1,"source":"https://example.invalid/","checkedAt":"2020-01-01"}]}]}"#.utf8))
            _ = try store.activatePricing(TokenQuoteEngine.make(table: price))
            records += [
                .tokens(.init(session: primary, timestamp: now - 60_000, model: "project-fixture-priced",
                              counts: .init(inputFresh: 12, cacheRead: 3, output: 5), dedupeKey: "preview:project:day")),
                .tokens(.init(session: peer, timestamp: now - 172_800_000, model: nil,
                              counts: .init(output: 13), precision: .snapshot, dedupeKey: "preview:project:week")),
                .tokens(.init(session: docs, timestamp: now - 60_000, model: "project-fixture-priced",
                              counts: .init(output: 1000), dedupeKey: "preview:project:other")),
            ]
        }
        if listUsage {
            records += [
                .tokens(.init(session: primary, timestamp: 0, model: nil,
                              counts: .init(output: 7), dedupeKey: "preview:session:unknown-rate")),
                .event(.init(session: primary, sequence: 1, timestamp: now - 1, kind: .user,
                             text: "会话用量检查", dedupeKey: "preview:session:usage-query")),
                .event(.init(session: peer, sequence: 1, timestamp: now - 30_000, kind: .user,
                             text: "会话用量检查", dedupeKey: "preview:session:peer-usage-query")),
            ]
        }
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_TOPICS"] == "1" {
            records.append(.event(.init(session: primary, sequence: 2, timestamp: now + 1, kind: .user,
                                        text: "harmonic", dedupeKey: "preview:project:topic")))
        }
        if grouping {
            let ungrouped = SessionKey(agent: .codex, nativeID: "preview-session-ungrouped")
            records.append(.session(.init(key: ungrouped, sourceID: codex, environment: "Local",
                                          title: "Synthetic without a project", lastEventAt: now - 40_000)))
        }
        if groupingSearch {
            for number in 1...53 {
                let key = SessionKey(agent: .codex, nativeID: "preview-grouped-search-\(number)")
                let time = now - Int64(number) * 1000
                let path = number.isMultiple(of: 2) ? client : "/synthetic/work/docs"
                records.append(.session(.init(key: key, sourceID: codex, environment: "Local",
                    cwd: path, title: "Synthetic search result \(number)", lastEventAt: time)))
                records.append(.event(.init(session: key, sequence: 0, timestamp: time, kind: .user,
                    text: "分组搜索命中", dedupeKey: "preview:grouped-search:\(number)")))
            }
        }
        try store.write(records)
    }

    nonisolated private static func prepareIndexingFixture(in directory: URL, store: AgentStore) throws {
        let root = directory.appendingPathComponent("synthetic-claude-source")
        let project = root.appendingPathComponent("projects/synthetic")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("00000000-0000-0000-0000-000000000033.jsonl")
        var lines = [#"{"type":"user","uuid":"synthetic-index-selection","cwd":"/synthetic/test","message":{"content":"Selected source 索引验证"}}"#]
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_ORIGINAL_INPUT"] == "1" {
            lines.append(#"{"type":"assistant","uuid":"synthetic-index-original-input","message":{"content":[{"type":"tool_use","name":"Bash","id":"synthetic-input","input":{"command":"synthetic diagnostic","detail":"syntheticinputonly","API_TOKEN":"synthetic-input-secret"}}]}}"#)
        }
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_STRUCTURED_ACTIONS"] == "1" {
            lines += [
                #"{"type":"assistant","uuid":"synthetic-index-action-file","message":{"content":[{"type":"tool_use","name":"Edit","id":"synthetic-edit","input":{"file_path":"/synthetic/test/working.swift","old_string":"stay\nremove\n","new_string":"stay\nadd\nextra\n"}}]}}"#,
                #"{"type":"assistant","uuid":"synthetic-index-action-command","message":{"content":[{"type":"tool_use","name":"Bash","id":"synthetic-command","input":{"command":"API_TOKEN='synthetic-actions-secret' synthetic checks"}}]}}"#,
                #"{"type":"user","uuid":"synthetic-index-action-completion","toolUseResult":{"durationMs":713},"message":{"content":[{"type":"tool_result","tool_use_id":"synthetic-command","is_error":false,"content":"synthetic done"}]}}"#,
            ]
        }
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_TOPICS"] == "1" {
            lines.append(#"{"type":"user","uuid":"synthetic-index-livetopic","message":{"content":"harmonic"}}"#)
        }
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_INHERITED_TRANSCRIPT"] == "1" {
            let copied = #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000301","sessionId":"00000000-0000-0000-0000-000000000033","timestamp":1000,"cwd":"/synthetic/inherited-original","message":{"content":"Confirmed inherited message"}} "#
            let redacted = #"{"type":"assistant","uuid":"00000000-0000-4000-8000-000000000302","sessionId":"00000000-0000-0000-0000-000000000033","timestamp":2000,"message":{"content":"API_TOKEN=synthetic-inherited-secret"}} "#
            lines = [copied, redacted,
                #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000303","sessionId":"00000000-0000-0000-0000-000000000033","timestamp":3000,"message":{"content":"Later original message not copied"}} "#]
            let continuation = [copied, redacted,
                #"{"type":"user","uuid":"00000000-0000-4000-8000-000000000304","sessionId":"00000000-0000-0000-0000-000000000032","timestamp":4000,"cwd":"/synthetic/continued-preview","message":{"content":"Own continuation message"}} "#]
            let child = project.appendingPathComponent("00000000-0000-0000-0000-000000000032.jsonl")
            try Data((continuation.joined(separator: "\n") + "\n").utf8).write(to: child)
        }
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        try store.upsertSource(.init(agent: .claudeCode, label: "Synthetic Claude source", rootURL: root,
                                     environment: "Synthetic"))
    }

    nonisolated private static func prepareCodexIndexingFixture(in directory: URL, store: AgentStore) throws {
        let root = directory.appendingPathComponent("synthetic-codex-source")
        let day = root.appendingPathComponent("sessions/2026/01/01")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let lines = [
            #"{"timestamp":"2026-01-01T00:00:00Z","type":"session_meta","payload":{"id":"00000000-0000-0000-0000-000000000034","cwd":"/synthetic/test"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Selected Codex source 索引验证"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: day.appendingPathComponent("rollout-synthetic.jsonl"))
        try store.upsertSource(.init(agent: .codex, label: "Synthetic Codex source", rootURL: root, environment: "Synthetic"))
    }

    nonisolated private static func prepareCopilotIndexingFixture(in directory: URL, store: AgentStore) throws {
        let root = directory.appendingPathComponent("synthetic-copilot-source")
        let session = root.appendingPathComponent("session-state/synthetic-copilot")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"session.start","id":"start","data":{"sessionId":"synthetic-copilot","producer":"synthetic-cli","context":{"cwd":"/synthetic/test"}}}"#,
            #"{"type":"user.message","id":"prompt","data":{"content":"Copilot 合成索引验证","transformedContent":"Synthetic injected text"}}"#,
        ]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: session.appendingPathComponent("events.jsonl"))
        try store.upsertSource(.init(agent: .copilot, label: "Synthetic Copilot source", rootURL: root,
                                     environment: "Synthetic"))
    }
}
#endif
