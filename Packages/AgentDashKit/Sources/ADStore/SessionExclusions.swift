import ADCore
import ADPrivacy
import CryptoKit
import Foundation
import GRDB

public struct SessionExclusionUpdate: Sendable {
    public let removedSessions: Int
    public let invalidatedFiles: Int
}

public struct FileImportPosition: Sendable {
    public let checkpoint: Checkpoint?
    public let exclusionRevision: Int64
}

public struct FileBatchCommit: Sendable {
    public let checkpoint: Checkpoint
    public let needsWorkspaceReplay: Bool
}

public extension AgentStore {
    func sessionExclusionPatterns() throws -> [String] {
        try databasePool.read { try SessionExclusionPolicy.read($0).patterns }
    }

    /// Acquire the cursor and policy version in the same read snapshot.
    func fileImportPosition(for fileID: Int64) throws -> FileImportPosition {
        try databasePool.read { db in
            .init(checkpoint: try Self.readCheckpoint(fileID, db: db),
                  exclusionRevision: try SessionExclusionPolicy.read(db).revision)
        }
    }

    /// Validate before touching the index. Recheck all indexed sessions and
    /// invalidate only affected checkpoints, atomically with the policy write.
    func replaceSessionExclusions(_ patterns: [String], hostHome: String?) throws -> SessionExclusionUpdate {
        let matcher = try PathExclusions(patterns, hostHome: hostHome)
        return try databasePool.write { db in
            let old = try SessionExclusionPolicy.read(db)
            let home = patterns.isEmpty ? nil : hostHome
            guard !old.matches(patterns: patterns, hostHome: home) else {
                return .init(removedSessions: 0, invalidatedFiles: 0)
            }
            guard old.revision < Int64.max else { throw StoreError.invalidStoredValue }
            let policy = SessionExclusionPolicy(patterns: patterns, hostHome: home, revision: old.revision + 1)
            let bytes = try JSONEncoder().encode(policy)
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('session_exclusion_policy',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [String(decoding: bytes, as: UTF8.self)])
            var gate = SessionExclusionGate(policy: policy, matcher: matcher)
            try gate.removeExistingMatches(db: db)
            let invalidated = try Int.fetchOne(db, sql: "SELECT count(DISTINCT file_id) FROM session_exclusion_inputs") ?? 0
            try db.execute(sql: """
                UPDATE source_files SET parser_version=0,decoder_state=NULL
                WHERE id IN (SELECT file_id FROM session_exclusion_inputs);
                """)
            if patterns.isEmpty {
                try db.execute(sql: "DELETE FROM session_exclusion_keys; DELETE FROM session_exclusion_inputs;")
            }
            try gate.finishRemovals(db: db)
            try UsageChartChanges.publish(db)
            return .init(removedSessions: gate.removedCount, invalidatedFiles: invalidated)
        }
    }
}

struct SessionExclusionPolicy: Codable, Sendable {
    let patterns: [String]
    let hostHome: String?
    let revision: Int64

    static func read(_ db: Database) throws -> Self {
        guard let value = try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key='session_exclusion_policy'")
        else { return .init(patterns: [], hostHome: nil, revision: 0) }
        guard let policy = try? JSONDecoder().decode(Self.self, from: Data(value.utf8)), policy.revision > 0
        else { throw StoreError.invalidStoredValue }
        return policy
    }

    func matches(patterns candidate: [String], hostHome home: String?) -> Bool {
        let sameHome = (hostHome ?? "").utf8.elementsEqual((home ?? "").utf8)
        return sameHome && patterns.count == candidate.count &&
            zip(patterns, candidate).allSatisfy { $0.0.utf8.elementsEqual($0.1.utf8) }
    }
}

/// All decisions, dispositions, and deletions belong to the current writer transaction.
struct SessionExclusionGate {
    enum Disposition: Int {
        case waitingForPath = 0, invalidPath = 1, excluded = 2
    }

    struct Screened {
        let records: [NormalizedRecord]
        let withheldInFile: Bool
        let needsWorkspaceReplay: Bool
    }

    private struct MarkedInput: Hashable {
        let fileID: Int64
        let digest: Data
        let replayOnAdmission: Bool
    }

    let policy: SessionExclusionPolicy
    let matcher: PathExclusions
    private var mappings: [Int64: [PathMapping]] = [:]
    private var touchedProjects: Set<Int64> = []
    private var markedInputs: Set<MarkedInput> = []
    private(set) var removedCount = 0

    init(policy: SessionExclusionPolicy, matcher: PathExclusions) {
        self.policy = policy
        self.matcher = matcher
    }

    init(policy: SessionExclusionPolicy) throws {
        self.init(policy: policy, matcher: try PathExclusions(policy.patterns, hostHome: policy.hostHome))
    }

    mutating func removeExistingMatches(sourceID: Int64? = nil, db: Database) throws {
        guard !policy.patterns.isEmpty else { return }
        var after: Int64 = 0
        while true {
            try Task.checkCancellation()
            let rows = try Row.fetchAll(db, sql: """
                SELECT id,agent,native_id,source_id,file_id,project_id,cwd FROM sessions
                WHERE id>?1 AND cwd IS NOT NULL AND (?2 IS NULL OR source_id=?2)
                ORDER BY id LIMIT 256
                """, arguments: [after, sourceID])
            guard let last = rows.last else { break }
            for row in rows where try decision(row["cwd"], sourceID: row["source_id"], db: db) == .excluded {
                guard let agent = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
                let digest = Self.digest(.init(agent: agent, nativeID: row["native_id"]))
                try save(.excluded, digest: digest, db: db)
                try mark(row["file_id"], digest: digest, disposition: .excluded, db: db)
                try remove(row, db: db)
            }
            after = last["id"]
        }
    }

    mutating func screen(_ records: [NormalizedRecord], fileID: Int64?, db: Database) throws -> Screened {
        guard !policy.patterns.isEmpty else { return .init(records: records, withheldInFile: false, needsWorkspaceReplay: false) }
        // A confirmed match always wins. Otherwise use the newest explicit
        // workspace in this batch; missing metadata cannot displace a known path.
        var observed: [Data: PathExclusions.Decision] = [:]
        var verifiedOwners: [Data: SessionRecord] = [:]
        for case .session(let session) in records {
            // A copied-history placeholder cannot establish the original's path.
            guard session.referenceOnly != true, let cwd = session.cwd else { continue }
            let digest = Self.digest(session.key)
            if observed[digest] != .excluded {
                let outcome = try decision(cwd, sourceID: session.sourceID, db: db)
                observed[digest] = outcome
                verifiedOwners[digest] = outcome == .notExcluded ? session : nil
            }
        }
        var allowed = Set<Data>()
        var withheld: [Data: Disposition] = [:]
        var rewind = false
        var kept: [NormalizedRecord] = []
        kept.reserveCapacity(records.count)
        for record in records {
            guard let key = Self.key(for: record) else { kept.append(record); continue }
            let digest = Self.digest(key)
            if !allowed.contains(digest) && withheld[digest] == nil {
                let saved = try prior(digest, db: db)
                let previous = try Row.fetchOne(db, sql: """
                    SELECT id,source_id,file_id,project_id,cwd FROM sessions WHERE agent=? AND native_id=?
                    """, arguments: [key.agent.rawValue, key.nativeID])
                var disposition: Disposition?
                if saved?.kind == .excluded && saved?.revision == policy.revision {
                    disposition = .excluded
                } else if let observation = observed[digest] {
                    switch observation {
                    case .excluded: disposition = .excluded
                    case .indeterminate: disposition = .invalidPath
                    case .notExcluded: disposition = nil
                    }
                } else if let saved {
                    // A previously denied key needs explicit trustworthy evidence
                    // before coming back after a rule change.
                    disposition = saved.kind == .excluded ? .waitingForPath : saved.kind
                } else if let previous, let cwd: String = previous["cwd"] {
                    switch try decision(cwd, sourceID: previous["source_id"], db: db) {
                    case .excluded: disposition = .excluded
                    case .indeterminate: disposition = .invalidPath
                    case .notExcluded: disposition = nil
                    }
                } else {
                    disposition = .waitingForPath
                }
                if let disposition {
                    withheld[digest] = disposition
                    try save(disposition, digest: digest, db: db)
                    try mark(fileID, digest: digest, disposition: disposition, db: db)
                    if disposition == .excluded, let previous {
                        try mark(previous["file_id"], digest: digest, disposition: disposition, db: db)
                        try remove(previous, db: db)
                    }
                } else {
                    allowed.insert(digest)
                    if previous == nil, let owner = verifiedOwners[digest] {
                        if case .session = record {} else { kept.append(.session(owner)) }
                    }
                    if saved != nil {
                        if try admit(digest, currentFileID: fileID, db: db) { rewind = true }
                    }
                }
            }
            if allowed.contains(digest) {
                // A malformed intermediate path is not a replacement for an
                // independently verified workspace for the same session.
                if case .session(var value) = record, let cwd = value.cwd, matcher.decision(for: cwd) == .indeterminate {
                    value.cwd = nil
                    kept.append(.session(value))
                } else {
                    kept.append(record)
                }
            } else if case .session(let value) = record, let disposition = withheld[digest] {
                try mark(value.fileID, digest: digest, disposition: disposition, db: db)
            }
        }
        let pending: Bool
        if let fileID {
            pending = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM session_exclusion_inputs WHERE file_id=?)",
                                        arguments: [fileID]) == true
        } else {
            pending = false
        }
        return .init(records: kept, withheldInFile: pending, needsWorkspaceReplay: rewind)
    }

    /// The catalog derives new projects from the remaining sessions. Remove
    /// only empty legacy rows associated with removed sessions.
    func finishRemovals(db: Database) throws {
        guard removedCount > 0 else { return }
        for projectID in touchedProjects {
            try db.execute(sql: "DELETE FROM projects WHERE id=?1 AND NOT EXISTS(SELECT 1 FROM sessions WHERE project_id=?1)",
                           arguments: [projectID])
        }
        try db.execute(sql: "DELETE FROM term_df WHERE term NOT IN (SELECT term FROM session_keywords)")
    }

    private mutating func decision(_ path: String, sourceID: Int64, db: Database) throws -> PathExclusions.Decision {
        let direct = matcher.decision(for: path)
        guard direct == .notExcluded else { return direct }
        let rules: [PathMapping]
        if let known = mappings[sourceID] { rules = known }
        else {
            guard let raw = try String.fetchOne(db, sql: "SELECT path_mappings_json FROM sources WHERE id=?", arguments: [sourceID])
            else { throw StoreError.missingSource }
            rules = try JSONDecoder().decode([PathMapping].self, from: Data(raw.utf8))
            mappings[sourceID] = rules
        }
        guard !rules.isEmpty, let mapped = try? PathMapper.map(path, using: rules, hostHome: policy.hostHome) else { return direct }
        return matcher.decision(for: mapped)
    }

    private static func key(for record: NormalizedRecord) -> SessionKey? {
        switch record {
        case .session(let value): value.key
        case .event(let value): value.session
        case .tokens(let value): value.session
        case .copilotUsageSnapshot(let value): value.session
        case .removeEmptyPlaceholder(let key, _, _, _): key
        case .rateLimit: nil // Agent-wide, no session association.
        }
    }

    private static func digest(_ key: SessionKey) -> Data {
        Data(SHA256.hash(data: Data((key.agent.rawValue + "\u{0}" + key.nativeID).utf8)))
    }

    private func prior(_ digest: Data, db: Database) throws -> (kind: Disposition, revision: Int64)? {
        guard let row = try Row.fetchOne(db, sql: "SELECT disposition,revision FROM session_exclusion_keys WHERE digest=?",
                                         arguments: [digest]) else { return nil }
        guard let kind = Disposition(rawValue: row["disposition"]) else { throw StoreError.invalidStoredValue }
        return (kind, row["revision"])
    }

    private func save(_ disposition: Disposition, digest: Data, db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO session_exclusion_keys(digest,revision,disposition) VALUES(?,?,?)
            ON CONFLICT(digest) DO UPDATE SET revision=excluded.revision,disposition=excluded.disposition
            WHERE revision<>excluded.revision OR disposition<>excluded.disposition
            """).execute(arguments: [digest, policy.revision, disposition.rawValue])
    }

    private mutating func mark(_ fileID: Int64?, digest: Data, disposition: Disposition, db: Database) throws {
        guard let fileID else { return }
        let replay = disposition != .invalidPath
        guard markedInputs.insert(.init(fileID: fileID, digest: digest, replayOnAdmission: replay)).inserted else { return }
        try db.cachedStatement(sql: """
            INSERT INTO session_exclusion_inputs(file_id,digest,replay_on_admission) VALUES(?,?,?)
            ON CONFLICT(file_id,digest) DO UPDATE SET replay_on_admission=max(replay_on_admission,excluded.replay_on_admission)
            WHERE replay_on_admission<>excluded.replay_on_admission
            """).execute(arguments: [fileID, digest, replay])
        try db.cachedStatement(sql: """
            UPDATE source_files SET decoder_state=NULL,parser_version=0
            WHERE id=? AND (parser_version<>0 OR decoder_state IS NOT NULL)
            """)
            .execute(arguments: [fileID])
    }

    private func admit(_ digest: Data, currentFileID: Int64?, db: Database) throws -> Bool {
        let needsReplay: Bool
        if let currentFileID {
            needsReplay = try Bool.fetchOne(db, sql: """
                SELECT EXISTS(SELECT 1 FROM session_exclusion_inputs WHERE digest=? AND file_id=? AND replay_on_admission=1)
                """, arguments: [digest, currentFileID]) == true
        } else {
            needsReplay = false
        }
        try db.execute(sql: """
            UPDATE source_files SET parser_version=0,decoder_state=NULL WHERE id IN (
                SELECT file_id FROM session_exclusion_inputs WHERE digest=? AND replay_on_admission=1);
            DELETE FROM session_exclusion_inputs WHERE digest=? AND replay_on_admission=1;
            DELETE FROM session_exclusion_keys WHERE digest=?;
            """, arguments: [digest, digest, digest])
        return needsReplay
    }

    private mutating func remove(_ row: Row, db: Database) throws {
        let id: Int64 = row["id"]
        if let projectID: Int64 = row["project_id"] { touchedProjects.insert(projectID) }
        let blobs = try Int64.fetchAll(db, sql: "SELECT DISTINCT blob_id FROM events WHERE session_id=? AND blob_id IS NOT NULL",
                                       arguments: [id])
        try db.execute(sql: "UPDATE sessions SET parent_session_id=NULL WHERE parent_session_id=?", arguments: [id])
        try db.execute(sql: "UPDATE sessions SET resumed_from_session_id=NULL WHERE resumed_from_session_id=?", arguments: [id])
        try db.execute(sql: "DELETE FROM sessions WHERE id=?", arguments: [id])
        removedCount += db.changesCount
        for blob in blobs {
            try db.execute(sql: "DELETE FROM blobs WHERE id=?1 AND NOT EXISTS(SELECT 1 FROM events WHERE blob_id=?1)", arguments: [blob])
        }
    }
}
