import Foundation
import Testing
import GRDB
import ADCore
@testable import ADStore

/// Synthetic data only. Each test owns and removes only its UUID-named temp directory.
private func withStore(_ body: (AgentStore, URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("agentdash-m0-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite")), directory)
}

private func seed(_ store: AgentStore) throws -> SessionRecord {
    let sourceID = try store.upsertSource(Source(agent: .codex, label: "Synthetic",
                                                rootURL: URL(fileURLWithPath: "/synthetic/source")))
    let session = SessionRecord(key: .init(agent: .codex, nativeID: "synthetic-session"),
                                sourceID: sourceID, environment: "Test", title: "Synthetic session")
    try store.write([.session(session)])
    return session
}

@Test("M0 / ADP-2: fresh and reopened WAL database has its tables, foreign keys and tokenizer")
func freshAndReopened() throws {
    try withStore { store, directory in
        let session = try seed(store)
        try store.write([.event(.init(session: session.key, sequence: 0, timestamp: 123,
                                     kind: .user, text: "修复登录问题", dedupeKey: "synthetic:e0"))])
        let reopened = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        #expect(try reopened.events(in: session.key).count == 1)
        try reopened.databasePool.read { db throws -> Void in
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            #expect(try Int.fetchOne(db, sql: "PRAGMA foreign_keys") == 1)
            #expect(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") ==
                ["archive_retention", "context_measurement_model", "copilot_accounting", "exclusion_source_identity", "inherited_transcript", "live_topic_index", "original_tool_input", "project_pin_preferences", "project_usage_scope_edges", "running_session_activity", "saved_search_sidebar_filter", "session_exclusions", "session_record_identity", "session_titles", "session_usage_rollup", "source_removal", "source_root_identity", "status_inference", "structured_tool_actions", "tool_output_archive", "transcript_tool_pairs", "v1", "v2_jsonl_checkpoint", "v3_session_parent_hint", "v4_codex_index", "v9_token_minutes",
                 "v10_usage_readouts", "v11_token_quotes", "v12_cache_savings", "v13_usage_chart_changes",
                 "usage_cost_peak_index"].sorted())
            for name in ["sources", "source_root_identities", "source_files", "projects", "sessions", "events", "events_fts", "blobs",
                         "file_touches", "commands", "token_events", "token_minute", "rate_limit_snapshots",
                         "session_keywords", "term_df", "saved_searches", "app_meta", "copilot_usage_snapshots", "session_usage_rollup"] {
                #expect(try db.tableExists(name))
            }
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM events_fts WHERE events_fts MATCH ?", arguments: ["登录"]) == 1)
            #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }
}

@Test("ADP-2 / FR-TK: upgrading a v1 database retains its source progress and projects existing tokens")
func upgradesLegacyCheckpoint() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("jsonl-migration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("index.sqlite")
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let original = try String(contentsOf: package.appendingPathComponent("Sources/ADStore/Resources/v1.sql"),
                              encoding: .utf8)
    do {
        var config = Configuration()
        config.prepareDatabase { $0.add(tokenizer: AgentDashTokenizer.self) }
        let legacy = try DatabaseQueue(path: url.path, configuration: config)
        var migrations = DatabaseMigrator()
        migrations.registerMigration("v1") { db in try db.execute(sql: original) }
        try migrations.migrate(legacy)
        try legacy.write { db in
            try db.execute(sql: """
                INSERT INTO sources(id,agent,label,root_path,access_kind)
                VALUES(1,'codex','Synthetic','/synthetic','default_location');
                INSERT INTO source_files(id,source_id,rel_path,role,inode,size,mtime_ns,read_offset,
                                         last_seq,previous_ts,parser_version,state,unknown_records)
                VALUES(1,1,'file.jsonl','session',17,12,100,10,3,200,2,'partial',1);
                INSERT INTO sessions(id,agent,native_id,source_id,environment,status)
                VALUES(1,'codex','synthetic-legacy',1,'Test','completed');
                INSERT INTO token_events(session_id,agent,model,ts,input_fresh,cache_read,output,reasoning,
                    cost_micro_usd,price_status,price_ref,dedupe_key)
                VALUES(1,'codex','synthetic',60001,5,4,3,2,17,'priced','synthetic-legacy','legacy-usage');
                """)
        }
    }

    let upgraded = try AgentStore(databaseURL: url)
    #expect(try upgraded.checkpoint(for: 1) == Checkpoint(inode: 17, size: 12, offset: 10, parserVersion: 2,
                                                         sequence: 3, previousTimestamp: 200,
                                                         modificationTimeNS: 100, unknownRecords: 1))
    let window = try UsageWindow.make(.hour, now: 90_000, timeZone: .gmt)
    let report = try upgraded.usage(window: window)
    #expect(report.totals.counts.total == 12)
    #expect(report.totals.costMicroUSD == 17 && report.totals.unpricedTokens == 0)
    try upgraded.databasePool.read { db throws -> Void in
        let row = try #require(try Row.fetchOne(db, sql: "SELECT * FROM session_usage_rollup WHERE session_id=1"))
        let facts = IndexedSessionUsageSummary(row)
        #expect(facts.totals == report.totals && !facts.hasApproximateQuote)
    }
}

@Test("ADP-2/3: a stale batch cannot write records or overwrite the winning checkpoint")
func staleFileBatchIsAtomic() throws {
    try withStore { store, _ in
        let session = try seed(store)
        let file = SourceFile(sourceID: session.sourceID, relativePath: "synthetic.jsonl", role: .session)
        let fileID = try store.upsertFile(file, checkpoint: nil)
        let first = Checkpoint(inode: 3, size: 12, offset: 12, parserVersion: 1, sequence: 0,
                               previousTimestamp: 4, device: 2, modificationTimeNS: 5)
        try store.commitFileBatch([], for: fileID, from: nil, to: first)
        let staleEvent = EventRecord(session: session.key, sequence: 0, timestamp: 4, kind: .assistant,
                                     text: "Stale synthetic text", dedupeKey: "synthetic:stale")
        #expect(throws: StoreError.staleCheckpoint) {
            try store.commitFileBatch([.event(staleEvent)], for: fileID, from: nil, to: first)
        }
        #expect(try store.events(in: session.key).isEmpty)
        #expect(try store.checkpoint(for: fileID) == first)
    }
}

@Test("NFR-3: reused event and token statements rebind after transaction rollback")
func cachedWritesKeepSessionBindingsAfterRollback() throws {
    try withStore { store, _ in
        let first = try seed(store)
        let secondKey = SessionKey(agent: .codex, nativeID: "synthetic-second")
        try store.write([.session(.init(key: secondKey, sourceID: first.sourceID, environment: "Test"))])

        let firstEvent = EventRecord(session: first.key, sequence: 0, timestamp: 100, kind: .assistant,
                                     text: "first synthetic message", dedupeKey: "synthetic:first:event")
        let firstUsage = TokenEvent(session: first.key, timestamp: 100, model: "synthetic",
                                    counts: .init(inputFresh: 7, cacheRead: 2, cacheWrite: 1, output: 9, reasoning: 1),
                                    dedupeKey: "synthetic:first:tokens")
        try store.write([.event(firstEvent), .tokens(firstUsage)])

        let discarded = EventRecord(session: secondKey, sequence: 1, timestamp: 200, kind: .assistant,
                                     text: "discarded synthetic message", dedupeKey: "synthetic:second:attempt")
        let invalid = TokenEvent(session: secondKey, timestamp: 200, model: "synthetic", counts: .init(inputFresh: -1),
                                 dedupeKey: "synthetic:second:invalid")
        #expect(throws: StoreError.invalidTokenCounts) {
            try store.write([.event(discarded), .tokens(invalid)])
        }
        #expect(try store.events(in: secondKey).isEmpty)

        let secondEvent = EventRecord(session: secondKey, sequence: 2, timestamp: 300, kind: .user,
                                      text: "second synthetic message", dedupeKey: "synthetic:second:event")
        let secondUsage = TokenEvent(session: secondKey, timestamp: 300, model: "synthetic",
                                     counts: .init(inputFresh: 1, cacheRead: 2, output: 8),
                                     dedupeKey: "synthetic:second:tokens")
        try store.write([.event(secondEvent), .tokens(secondUsage)])
        #expect(try store.events(in: first.key) == [firstEvent])
        #expect(try store.events(in: secondKey) == [secondEvent])
        let usage = try store.databasePool.read { db -> [String: TokenCounts] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT s.native_id,t.input_fresh,t.cache_read,t.cache_write,t.cache_write_1h,t.output,t.reasoning
                FROM token_events t JOIN sessions s ON s.id=t.session_id
                """)
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                (row["native_id"] as String, TokenCounts(inputFresh: row["input_fresh"], cacheRead: row["cache_read"],
                    cacheWrite: row["cache_write"], cacheWrite1h: row["cache_write_1h"],
                    output: row["output"], reasoning: row["reasoning"]))
            })
        }
        #expect(usage == [first.key.nativeID: firstUsage.counts, secondKey.nativeID: secondUsage.counts])
    }
}

@Test("ADP-3: source/file/checkpoint and normalized writes are idempotent and preserve row identity")
func idempotentWrites() throws {
    try withStore { store, _ in
        let session = try seed(store)
        let file = SourceFile(sourceID: session.sourceID, relativePath: "synthetic.jsonl", role: .session)
        let fileID = try store.upsertFile(file, checkpoint: nil)
        let checkpoint = Checkpoint(inode: 17, size: 500, offset: 450, parserVersion: 2,
                                    sequence: 7, previousTimestamp: 1234)
        #expect(try store.upsertFile(file, checkpoint: checkpoint) == fileID)
        #expect(try store.checkpoint(for: fileID) == checkpoint)
        let event = EventRecord(session: session.key, sequence: 4, timestamp: 100,
                                kind: .assistant, text: "Synthetic response", dedupeKey: "synthetic:e1")
        let token = TokenEvent(session: session.key, timestamp: 100, model: "synthetic-model",
                               counts: .init(inputFresh: 11, cacheRead: 23, cacheWrite: 5,
                                             cacheWrite1h: 7, output: 13, reasoning: 3), dedupeKey: "synthetic:t1")
        try store.write([.session(session), .event(event), .tokens(token)])
        let original = try store.events(in: session.key)
        try store.write([.session(session), .event(event), .tokens(token)])
        #expect(try store.events(in: session.key) == original)
        try store.databasePool.read { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT input_fresh + cache_read + cache_write + cache_write_1h + output FROM token_events") == 59)
        }
    }
}

@Test("M0: a bad batch rolls back events and FTS together")
func atomicBatch() throws {
    try withStore { store, _ in
        let session = try seed(store)
        #expect(throws: (any Error).self) {
            try store.write([
                .event(.init(session: session.key, sequence: 0, timestamp: 1, kind: .user,
                             text: "rollbackneedle", dedupeKey: "synthetic:rollback")),
                .event(.init(session: .init(agent: .codex, nativeID: "missing"), sequence: 1,
                             timestamp: 2, kind: .user, text: "Synthetic", dedupeKey: "synthetic:missing"))
            ])
        }
        #expect(try store.events(in: session.key).isEmpty)
        try store.databasePool.read { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM events_fts WHERE events_fts MATCH 'rollbackneedle'") == 0)
        }
    }
}

@Test("M0: external-content FTS triggers track insert, update, delete and session cascade")
func ftsTriggers() throws {
    try withStore { store, _ in
        let session = try seed(store)
        var event = EventRecord(session: session.key, sequence: 0, timestamp: 1, kind: .toolCall,
                                toolName: "oldtoolneedle", text: "oldneedle", dedupeKey: "synthetic:fts")
        try store.write([.event(event)])
        event.text = "newneedle"
        event.toolName = "newtoolneedle"
        try store.write([.event(event)])
        try store.databasePool.write { db in
            func matches(_ text: String) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM events_fts WHERE events_fts MATCH ?", arguments: [text]) ?? -1
            }
            #expect(try matches("oldneedle") == 0)
            #expect(try matches("newneedle") == 1)
            #expect(try matches("oldtoolneedle") == 0)
            #expect(try matches("newtoolneedle") == 1)
            try db.execute(sql: "DELETE FROM events")
            #expect(try matches("newneedle") == 0)
        }
        try store.write([.event(event)])
        try store.databasePool.write { db in
            try db.execute(sql: "DELETE FROM sessions")
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM events_fts WHERE events_fts MATCH 'newneedle'") == 0)
            try db.execute(sql: "INSERT INTO events_fts(events_fts, rank) VALUES('integrity-check', 1)")
        }
    }
}

@Test("FR-SRC-1/2: source settings/bookmarks upsert without replacing child rows")
func sourceSettings() throws {
    try withStore { store, _ in
        let session = try seed(store)
        var source = try #require(store.sources().first)
        source.label = "Synthetic renamed"
        source.access = .bookmark(Data([7, 8, 9]))
        source.environmentRules = [.init(field: "model_provider", equals: "synthetic", environment: "Test")]
        source.pathMappings = [.init(from: "/workspace", to: "/synthetic")]
        #expect(try store.upsertSource(source) == session.sourceID)
        #expect(try store.sources() == [source])
        try store.databasePool.read { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM sessions") == 1)
        }
    }
}

@Test("ADP-2/3/4/5: events and durable progress commit together; metadata refresh preserves parser version")
func atomicProgress() throws {
    try withStore { store, _ in
        let session = try seed(store)
        var file = SourceFile(sourceID: session.sourceID, relativePath: "synthetic.jsonl", role: .session)
        let first = Checkpoint(inode: 1, size: 100, offset: 50, parserVersion: 1, sequence: 0, previousTimestamp: 100)
        let fileID = try store.upsertFile(file, checkpoint: first)
        file.parserVersion = 2
        try store.upsertFile(file, checkpoint: nil)
        #expect(try store.checkpoint(for: fileID) == first)
        let event = EventRecord(session: session.key, sequence: 1, timestamp: 50,
                                kind: .unknown, text: "Synthetic unknown", dedupeKey: "synthetic:progress")
        let invalid = Checkpoint(inode: 1, size: 100, offset: 101, parserVersion: 2, sequence: 1, previousTimestamp: 50)
        #expect(throws: StoreError.invalidCheckpoint) {
            try store.write([.event(event)], fileID: fileID, checkpoint: invalid)
        }
        #expect(try store.checkpoint(for: fileID) == first)
        #expect(try store.events(in: session.key).isEmpty)
        let final = Checkpoint(inode: 1, size: 100, offset: 99, parserVersion: 2, sequence: 1, previousTimestamp: 50)
        try store.write([.event(event)], fileID: fileID, checkpoint: final)
        #expect(try store.checkpoint(for: fileID) == final)
        #expect(try store.events(in: session.key) == [event])
        #expect(throws: StoreError.invalidRelativePath) {
            try store.upsertFile(.init(sourceID: session.sourceID, relativePath: "../synthetic", role: .session), checkpoint: nil)
        }
    }
}

@Test("ADP-3: copied history keeps its original owner; same-session corrections update exactly one token row")
func dedupeOwnership() throws {
    try withStore { store, _ in
        let original = try seed(store)
        var copy = original
        copy.key.nativeID = "synthetic-resumed"
        let event = EventRecord(session: original.key, sequence: 2, timestamp: 10, kind: .assistant,
                                text: "Synthetic original", dedupeKey: "synthetic:shared-event")
        var usage = TokenEvent(session: original.key, timestamp: 10, counts: .init(output: 5), dedupeKey: "synthetic:shared-usage")
        try store.write([.session(copy), .event(event), .tokens(usage)])
        var copied = event
        copied.session = copy.key
        usage.session = copy.key
        try store.write([.event(copied), .tokens(usage)])
        #expect(try store.events(in: original.key) == [event])
        #expect(try store.events(in: copy.key).isEmpty)
        usage.session = original.key
        usage.counts.output = 7
        try store.write([.tokens(usage)])
        try store.databasePool.read { db throws -> Void in
            #expect(try Int.fetchOne(db, sql: "SELECT count(*) FROM token_events") == 1)
            #expect(try Int.fetchOne(db, sql: "SELECT sum(output) FROM token_events") == 7)
        }
        usage.counts.reasoning = 8
        #expect(throws: StoreError.invalidTokenCounts) { try store.write([.tokens(usage)]) }
    }
}

@Test("ADP-5: transcript order follows sequence even when timestamps regress")
func fileOrder() throws {
    try withStore { store, _ in
        let session = try seed(store)
        let first = EventRecord(session: session.key, sequence: 0, timestamp: 200, kind: .user,
                                text: "Synthetic first", dedupeKey: "synthetic:order0")
        let last = EventRecord(session: session.key, sequence: 1, timestamp: 100, kind: .assistant,
                               text: "Synthetic last", dedupeKey: "synthetic:order1")
        try store.write([.event(last), .event(first)])
        #expect(try store.events(in: session.key) == [first, last])
    }
}
