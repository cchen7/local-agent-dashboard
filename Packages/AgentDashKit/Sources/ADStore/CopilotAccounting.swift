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
        try db.cachedStatement(sql: """
            INSERT INTO copilot_usage_snapshots(dedupe_key,session_id,model,seq,ts,input_fresh,cache_read,cache_write,output,reasoning)
            VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(dedupe_key) DO NOTHING
            """).execute(arguments: [sample.dedupeKey, sessionID, sample.model, sample.sequence, sample.timestamp,
                              c.inputFresh, c.cacheRead, c.cacheWrite, c.output, c.reasoning])
        return db.changesCount == 0 ? nil : Key(sessionID: sessionID, model: sample.model)
    }

    static func coversCall(_ key: Key, sequence: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT EXISTS(SELECT 1 FROM copilot_usage_snapshots WHERE session_id=? AND model=? AND seq>=?)
            """), arguments: [key.sessionID, key.model, sequence]) ?? false
    }

    static func snapshotKeys(sessionID: Int64, db: Database) throws -> [Key] {
        try String.fetchAll(db.cachedStatement(sql: "SELECT DISTINCT model FROM copilot_usage_snapshots WHERE session_id=?"),
                            arguments: [sessionID]).map { Key(sessionID: sessionID, model: $0) }
    }

    static func hasModelLessCalls(sessionID: Int64, db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: """
            SELECT EXISTS(SELECT 1 FROM token_events WHERE session_id=? AND model IS NULL
                          AND agent='copilot' AND precision='call' AND source_seq IS NOT NULL)
            """), arguments: [sessionID]) == true
    }

    typealias CoveredCall = (sequence: Int64, counts: [Int64])

    private struct Sample {
        let sequence: Int64
        let counts: [Int64]
        let named: [Int64]
    }

    private struct Capacity {
        var unclaimed: [Int64]
        var earlierCredits: [CoveredCall] = []

        // A call can replace fallback from its own position onward. It
        // cannot explain fallback already credited earlier in the file.
        func credit(before sequence: Int64) -> [Int64] {
            var lo = 0
            var hi = earlierCredits.count
            while lo < hi {
                let mid = lo + (hi - lo) / 2
                if earlierCredits[mid].sequence < sequence { lo = mid + 1 }
                else { hi = mid }
            }
            return lo > 0 ? earlierCredits[lo - 1].counts : CopilotAccounting.zero
        }

        func fits(_ call: CoveredCall) -> Bool {
            let floor = credit(before: call.sequence)
            return unclaimed.indices.allSatisfy { call.counts[$0] <= max(0, unclaimed[$0] - floor[$0]) }
        }
    }

    private static let zero = [Int64](repeating: 0, count: 5)

    /// Compute the free cumulative volume and preserve the time at which
    /// earlier snapshots credited fallback, using the same rules as reconcile.
    private static func capacity(through sample: Sample, history: [Sample], assigned: [CoveredCall],
                                 assignedTotal: [Int64]) throws -> Capacity {
        let accounted = try add(sample.named, assignedTotal)
        var result = Capacity(unclaimed: zip(sample.counts, accounted).map { max(0, $0.0 - $0.1) })
        guard history.first.map({ $0.sequence < sample.sequence }) == true else { return result }
        let calls = assigned.sorted { $0.sequence < $1.sequence }
        var index = 0
        var matched = zero
        var credited = zero
        for prior in history {
            guard prior.sequence < sample.sequence else { break }
            try Task.checkCancellation()
            while index < calls.count, calls[index].sequence <= prior.sequence {
                matched = try add(matched, calls[index].counts)
                index += 1
            }
            let accounted = try add(prior.named, matched)
            let delta = checkpointDelta(prior.counts, calls: accounted, checkpointed: credited)
            if delta.contains(where: { $0 > 0 }) {
                credited = try add(credited, delta)
                result.earlierCredits.append((prior.sequence, credited))
            }
        }
        return result
    }

    private static let completeBatchCallLimit = 24
    private static let completeBatchModelLimit = 8
    private static let completeBatchWorkLimit = 8_192

    private struct BatchModel {
        let key: Key
        let sample: Sample
        let history: [Sample]
        let baseline: [Int64]
        var space: Capacity
        var calls: [CoveredCall]
        var callTotal: [Int64]
    }

    /// Check for complete coverage before greedy selection. Equal aggregates
    /// alone are insufficient: each call must fit whole in a single model,
    /// with all previously credited history still accounted for. A feasible
    /// allocation here is evidence of overlap only, never evidence of price.
    private static func matchCompleteBatch(_ calls: [CoveredCall], group: [Key: Sample], history: [Key: [Sample]],
                                           remaining: [Key: Capacity], assigned: [Key: [CoveredCall]],
                                           assignedTotals: [Key: [Int64]], work: inout Int) throws -> [Key]? {
        guard work > 0, calls.count >= 2, calls.count <= completeBatchCallLimit,
              group.count >= 2, group.count <= completeBatchModelLimit, let first = calls.first else { return nil }
        var unmatched = zero
        for call in calls { unmatched = try add(unmatched, call.counts) }
        var models: [BatchModel] = []
        for (key, sample) in group {
            guard let space = remaining[key] else { return nil }
            let baseline = space.credit(before: first.sequence)
            let total = assignedTotals[key] ?? zero
            let known = try add(sample.named, total)
            for i in unmatched.indices {
                guard known[i] <= sample.counts[i], baseline[i] <= space.unclaimed[i] else { return nil }
                let available = space.unclaimed[i] - baseline[i]
                guard available <= unmatched[i] else { return nil }
                unmatched[i] -= available
            }
            models.append(.init(key: key, sample: sample, history: history[key] ?? [], baseline: baseline,
                                space: space, calls: assigned[key] ?? [], callTotal: total))
        }
        guard unmatched.allSatisfy({ $0 == 0 }) else { return nil }
        models.sort { $0.key.model.utf8.lexicographicallyPrecedes($1.key.model.utf8) }
        var choices: [Key] = []
        func search(_ index: Int) throws -> Bool {
            if index == calls.count {
                return models.allSatisfy { model in
                    model.space.unclaimed == model.baseline && model.space.credit(before: model.sample.sequence) == model.baseline
                }
            }
            let call = calls[index]
            for m in models.indices where models[m].space.fits(call) {
                try Task.checkCancellation()
                let prior = models[m]
                let rederive = prior.space.earlierCredits.last.map { $0.sequence >= call.sequence } == true
                let cost = rederive ? 1 + prior.history.count + prior.calls.count : 1
                guard cost <= work else { work = 0; return false }
                work -= cost
                models[m].calls.append(call)
                models[m].callTotal = try add(prior.callTotal, call.counts)
                if rederive {
                    models[m].space = try capacity(through: prior.sample, history: prior.history,
                                                   assigned: models[m].calls, assignedTotal: models[m].callTotal)
                } else {
                    models[m].space.unclaimed = zip(prior.space.unclaimed, call.counts).map { $0.0 - $0.1 }
                }
                choices.append(prior.key)
                if try search(index + 1) { return true }
                choices.removeLast()
                models[m] = prior
            }
            return false
        }
        return try search(0) ? choices : nil
    }

    /// Find a checkpoint where a call's coverage can be shown either by a
    /// complete batch or by a unique model's full remaining capacity.
    /// Use the result only to subtract already counted volume. Never set or
    /// price the call's model.
    static func coveredCalls(sessionID: Int64, db: Database) throws -> [Key: [CoveredCall]] {
        let anonymous: [CoveredCall] = try Row.fetchAll(db, sql: """
            SELECT source_seq,input_fresh,cache_read,cache_write,output,reasoning
            FROM token_events WHERE session_id=? AND model IS NULL AND agent='copilot'
              AND precision='call' AND source_seq IS NOT NULL AND cache_write_1h=0
            ORDER BY source_seq,dedupe_key
            """, arguments: [sessionID]).map { row in
                (sequence: row["source_seq"] as Int64, counts: parts(readCounts(row)))
            }
        guard !anonymous.isEmpty else { return [:] }
        let snapshots = try Row.fetchCursor(db, sql: """
            SELECT model,seq,input_fresh,cache_read,cache_write,output,reasoning
            FROM copilot_usage_snapshots WHERE session_id=? ORDER BY seq,dedupe_key
            """, arguments: [sessionID])
        var history: [Key: [Sample]] = [:]
        var assignedTotals: [Key: [Int64]] = [:]
        var result: [Key: [CoveredCall]] = [:]
        var matched = Set<Int>()
        var batchWork = completeBatchWorkLimit
        var next = try snapshots.next()
        while let first = next {
            try Task.checkCancellation()
            let sequence: Int64 = first["seq"]
            var group: [Key: Sample] = [:]
            var coherent = true
            while let row = next, (row["seq"] as Int64) == sequence {
                let key = Key(sessionID: sessionID, model: row["model"])
                let counts = parts(readCounts(row))
                next = try snapshots.next()
                let prior = history[key]?.last
                if prior.map({ !zip(counts, $0.counts).allSatisfy { $0.0 >= $0.1 } }) == true {
                    coherent = false
                    continue
                }
                let named = try namedCalls(key, after: prior?.sequence ?? -1, through: sequence, db: db)
                let sample = Sample(sequence: sequence, counts: counts, named: try add(prior?.named ?? zero, named))
                history[key, default: []].append(sample)
                if group.updateValue(sample, forKey: key) != nil { coherent = false }
            }
            guard coherent else { continue }
            var remaining: [Key: Capacity] = [:]
            for (key, sample) in group {
                remaining[key] = try capacity(through: sample, history: history[key] ?? [],
                                              assigned: result[key] ?? [], assignedTotal: assignedTotals[key] ?? zero)
            }
            if batchWork > 0, group.count > 1, group.count <= completeBatchModelLimit {
                let pending = Array(anonymous.indices.lazy.prefix { anonymous[$0].sequence <= sequence }
                    .filter { !matched.contains($0) && anonymous[$0].counts.contains(where: { $0 > 0 }) }
                    .prefix(completeBatchCallLimit + 1))
                if pending.count <= completeBatchCallLimit,
                   let keys = try matchCompleteBatch(pending.map { anonymous[$0] }, group: group, history: history,
                                                     remaining: remaining, assigned: result, assignedTotals: assignedTotals,
                                                     work: &batchWork) {
                    for (i, key) in zip(pending, keys) {
                        let call = anonymous[i]
                        assignedTotals[key] = try add(assignedTotals[key] ?? zero, call.counts)
                        result[key, default: []].append(call)
                        matched.insert(i)
                    }
                    if matched.count == anonymous.count { break }
                    continue
                }
            }
            // Assigning a unique match can disqualify one model for a call
            // earlier in the file. Revisit pending calls until nothing matches.
            var progressed = true
            while progressed {
                progressed = false
                for i in anonymous.indices {
                    let call = anonymous[i]
                    if call.sequence > sequence { break }
                    guard !matched.contains(i) else { continue }
                    try Task.checkCancellation()
                    var match: Key?
                    for (key, candidate) in remaining where candidate.fits(call) {
                        if match != nil { match = nil; break }
                        match = key
                    }
                    guard let key = match, let sample = group[key], var candidate = remaining[key] else { continue }
                    let total = try add(assignedTotals[key] ?? zero, call.counts)
                    assignedTotals[key] = total
                    result[key, default: []].append(call)
                    matched.insert(i)
                    progressed = true
                    if candidate.earlierCredits.last.map({ $0.sequence >= call.sequence }) == true {
                        candidate = try capacity(through: sample, history: history[key] ?? [],
                                                 assigned: result[key] ?? [], assignedTotal: total)
                    } else {
                        candidate.unclaimed = zip(candidate.unclaimed, call.counts).map { $0.0 - $0.1 }
                    }
                    remaining[key] = candidate
                }
            }
            if matched.count == anonymous.count { break }
        }
        for key in Array(result.keys) {
            result[key]?.sort { $0.sequence < $1.sequence }
        }
        return result
    }

    private static func namedCalls(_ key: Key, after: Int64, through: Int64, db: Database) throws -> [Int64] {
        let row = try Row.fetchOne(db, sql: """
            SELECT coalesce(sum(input_fresh),0) AS input_fresh,
                   coalesce(sum(cache_read),0) AS cache_read,coalesce(sum(cache_write),0) AS cache_write,
                   coalesce(sum(output),0) AS output,coalesce(sum(reasoning),0) AS reasoning
            FROM token_events WHERE session_id=? AND model=? AND agent='copilot' AND precision='call'
            AND source_seq>? AND source_seq<=?
            """, arguments: [key.sessionID, key.model, after, through])
        return row.map { parts(readCounts($0)) } ?? Array(repeating: 0, count: 5)
    }

    private static func add(_ a: [Int64], _ b: [Int64]) throws -> [Int64] {
        try zip(a, b).map {
            let (total, overflow) = $0.0.addingReportingOverflow($0.1)
            guard !overflow else { throw StoreError.invalidTokenCounts }
            return total
        }
    }

    private static func checkpointDelta(_ counts: [Int64], calls: [Int64], checkpointed: [Int64]) -> [Int64] {
        var delta = counts.indices.map { max(0, max(0, counts[$0] - calls[$0]) - checkpointed[$0]) }
        delta[4] = min(delta[3], delta[4]) // reasoning is a subset of output
        return delta
    }

    static func reconcile(_ key: Key, covered: [CoveredCall] = [], touchedUsage: inout Set<String>, db: Database) throws {
        let snapshots = try Row.fetchCursor(db, sql: """
            SELECT * FROM copilot_usage_snapshots WHERE session_id=? AND model=? ORDER BY seq,dedupe_key
            """, arguments: [key.sessionID, key.model])
        var highWater = [Int64](repeating: 0, count: 5)
        var calls = highWater
        var checkpointed = highWater
        var lastSequence: Int64 = -1
        var coveredIndex = 0
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
            calls = try add(calls, namedCalls(key, after: lastSequence, through: sequence, db: db))
            // Once a later sample establishes overlap, remove the earlier
            // partial fallback too. The exact call stays at its own timestamp.
            while coveredIndex < covered.count, covered[coveredIndex].sequence <= sequence {
                calls = try add(calls, covered[coveredIndex].counts)
                coveredIndex += 1
            }
            let delta = checkpointDelta(counts, calls: calls, checkpointed: checkpointed)
            checkpointed = try add(checkpointed, delta)
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
