import ADCore
import GRDB

/// A durable accounting journal for coarse snapshots. Actual calls keep their
/// own sequence and timestamp; checkpoint usage fills only the missing volume.
enum CopilotAccounting {
    struct Key: Hashable {
        let sessionID: Int64
        private let modelBytes: [UInt8]
        var model: String { String(decoding: modelBytes, as: UTF8.self) }

        init(sessionID: Int64, model: String) {
            self.sessionID = sessionID
            self.modelBytes = Array(model.utf8)
        }
    }

    static func record(_ sample: CopilotUsageSnapshot, sessionID: Int64, db: Database) throws -> Key? {
        let c = sample.counts
        guard sample.session.agent == .copilot, sample.sequence >= 0, c.cacheWrite1h == 0,
              parts(c).allSatisfy({ $0 >= 0 }), c.reasoning <= c.output else { throw StoreError.invalidTokenCounts }
        try db.execute(sql: """
            INSERT INTO copilot_usage_snapshots(dedupe_key,session_id,model,seq,ts,input_fresh,cache_read,cache_write,output,reasoning)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(dedupe_key) DO NOTHING
            """, arguments: [sample.dedupeKey, sessionID, sample.model, sample.sequence, sample.timestamp,
                              c.inputFresh, c.cacheRead, c.cacheWrite, c.output, c.reasoning])
        return db.changesCount == 0 ? nil : Key(sessionID: sessionID, model: sample.model)
    }

    static func coversCall(_ key: Key, sequence: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM copilot_usage_snapshots WHERE session_id=? AND model=? AND seq>=?)
            """, arguments: [key.sessionID, key.model, sequence]) ?? false
    }

    static func snapshotKeys(sessionID: Int64, db: Database) throws -> [Key] {
        try String.fetchAll(db, sql: "SELECT DISTINCT model FROM copilot_usage_snapshots WHERE session_id=?",
                            arguments: [sessionID]).map { Key(sessionID: sessionID, model: $0) }
    }

    static func hasModelLessCalls(sessionID: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM token_events WHERE session_id=? AND model IS NULL
                          AND agent='copilot' AND precision='call' AND source_seq IS NOT NULL)
            """, arguments: [sessionID]) == true
    }

    static func reconcile(_ key: Key, touchedUsage: inout Set<String>, db: Database) throws {
        let hasAnonymous = try hasModelLessCalls(sessionID: key.sessionID, db: db)
        let snapshots = try Row.fetchCursor(db, sql: """
            SELECT * FROM copilot_usage_snapshots WHERE session_id=? AND model=? ORDER BY seq,dedupe_key
            """, arguments: [key.sessionID, key.model])
        var highWater = [Int64](repeating: 0, count: 5)
        var calls = highWater
        var checkpointed = highWater
        var lastSequence: Int64 = -1
        while let row = try snapshots.next() {
            try Task.checkCancellation()
            let counts = parts(readCounts(row))
            let dedupeKey: String = row["dedupe_key"]
            let sequence: Int64 = row["seq"]
            // A decreasing cumulative record is a rewind/stale checkpoint.
            // It cannot lower the baseline or add new usage.
            guard zip(counts, highWater).allSatisfy({ $0.0 >= $0.1 }) else {
                try removeGenerated(dedupeKey, db: db)
                continue
            }
            let callRow = try Row.fetchOne(db, sql: """
                SELECT coalesce(sum(input_fresh),0) AS input_fresh,
                       coalesce(sum(cache_read),0) AS cache_read,coalesce(sum(cache_write),0) AS cache_write,
                       coalesce(sum(output),0) AS output,coalesce(sum(reasoning),0) AS reasoning
                FROM token_events WHERE session_id=? AND model=? AND agent='copilot' AND precision='call'
                AND source_seq>? AND source_seq<=?
                """, arguments: [key.sessionID, key.model, lastSequence, sequence])
            if let callRow {
                for (index, count) in parts(readCounts(callRow)).enumerated() {
                    let (sum, overflow) = calls[index].addingReportingOverflow(count)
                    guard !overflow else { throw StoreError.invalidTokenCounts }
                    calls[index] = sum
                }
            }
            if hasAnonymous, let attributed = try Row.fetchOne(db, sql: """
                SELECT coalesce(sum(t.input_fresh),0) AS input_fresh,
                       coalesce(sum(t.cache_read),0) AS cache_read,coalesce(sum(t.cache_write),0) AS cache_write,
                       coalesce(sum(t.output),0) AS output,coalesce(sum(t.reasoning),0) AS reasoning
                FROM token_events t WHERE t.session_id=?1 AND t.model IS NULL AND t.agent='copilot'
                AND t.precision='call' AND t.source_seq>?2 AND t.source_seq<=?3
                AND (
                    SELECT CASE WHEN count(DISTINCT s.model)=1 THEN min(s.model) END
                    FROM copilot_usage_snapshots s WHERE s.session_id=t.session_id AND s.seq=(
                        SELECT min(n.seq) FROM copilot_usage_snapshots n
                        WHERE n.session_id=t.session_id AND n.seq>=t.source_seq
                    )
                )=?4 COLLATE BINARY
                """, arguments: [key.sessionID, lastSequence, sequence, key.model]) {
                // Require the single-model checkpoint to contain the known
                // calls and all candidate counters. Partial overlap does not
                // establish that an anonymous call belongs to this model.
                let values = parts(readCounts(attributed))
                if values.indices.allSatisfy({ calls[$0] <= counts[$0] && values[$0] <= counts[$0] - calls[$0] }) {
                    for index in values.indices { calls[index] += values[index] }
                }
            }
            var delta = counts.indices.map { index in
                max(0, max(0, counts[index] - calls[index]) - checkpointed[index])
            }
            delta[4] = min(delta[3], delta[4]) // reasoning is a subset of output
            for index in delta.indices {
                let (next, overflow) = checkpointed[index].addingReportingOverflow(delta[index])
                guard !overflow else { throw StoreError.invalidTokenCounts }
                checkpointed[index] = next
            }
            highWater = counts
            lastSequence = sequence
            if delta.allSatisfy({ $0 == 0 }) {
                try removeGenerated(dedupeKey, db: db)
            } else {
                let timestamp: Int64 = row["ts"]
                try db.execute(sql: """
                    INSERT INTO token_events(session_id,project_id,agent,model,ts,input_fresh,cache_read,cache_write,output,reasoning,precision,dedupe_key)
                    VALUES(?,(SELECT project_id FROM sessions WHERE id=?),'copilot',?,?,?,?,?,?,?,'checkpoint',?) ON CONFLICT(dedupe_key) DO UPDATE SET
                    project_id=excluded.project_id,
                    input_fresh=excluded.input_fresh,cache_read=excluded.cache_read,cache_write=excluded.cache_write,
                    output=excluded.output,reasoning=excluded.reasoning
                    WHERE token_events.session_id=excluded.session_id AND token_events.precision='checkpoint'
                    AND (token_events.project_id IS NOT excluded.project_id
                         OR token_events.input_fresh<>excluded.input_fresh OR token_events.cache_read<>excluded.cache_read
                         OR token_events.cache_write<>excluded.cache_write OR token_events.output<>excluded.output
                         OR token_events.reasoning<>excluded.reasoning)
                    """, arguments: [key.sessionID, key.sessionID, key.model, timestamp, delta[0], delta[1], delta[2],
                                      delta[3], delta[4], dedupeKey])
                if db.changesCount > 0 { touchedUsage.insert(dedupeKey) }
            }
        }
    }

    private static func removeGenerated(_ dedupeKey: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM token_events WHERE dedupe_key=? AND agent='copilot' AND precision='checkpoint'",
                       arguments: [dedupeKey])
    }

    private static func readCounts(_ row: Row) -> TokenCounts {
        TokenCounts(inputFresh: row["input_fresh"], cacheRead: row["cache_read"], cacheWrite: row["cache_write"],
                    output: row["output"], reasoning: row["reasoning"])
    }

    private static func parts(_ value: TokenCounts) -> [Int64] {
        [value.inputFresh, value.cacheRead, value.cacheWrite, value.output, value.reasoning]
    }
}
