import ADCore
import Foundation
import GRDB

public struct IndexedRecordLocation: Equatable, Sendable {
    public let relativePath: String
    public let device: Int64
    public let inode: Int64
    public let rootIdentity: SourceRootIdentity?
}

/// The raw normalized workspace and authorized record, separate from the
/// privacy-projected labels on screen. Never expose this snapshot in logs.
public struct IndexedSessionActions: Equatable, Sendable {
    public let key: SessionKey
    public let source: Source
    public let workspace: String?
    public let environment: String
    public let canResume: Bool
    public let record: IndexedRecordLocation?
}

public extension AgentStore {
    func indexedSessionActions(_ session: SessionKey) throws -> IndexedSessionActions? {
        try databasePool.read { try Self.readSessionActions(session, db: $0) }
    }

    func indexedSessionActionUpdates(_ session: SessionKey) -> some AsyncSequence<IndexedSessionActions?, any Error> & Sendable {
        ValueObservation.tracking { db in try Self.readSessionActions(session, db: db) }
            .removeDuplicates()
            .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    private static func readSessionActions(_ session: SessionKey, db: Database) throws -> IndexedSessionActions? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT s.source_id,s.cwd,s.environment,s.source_deleted_at,f.role,f.state,f.rel_path,
                   CASE WHEN f.device=s.record_device AND f.inode=s.record_inode THEN f.device END AS device,
                   CASE WHEN f.device=s.record_device AND f.inode=s.record_inode THEN f.inode END AS inode
            FROM sessions s LEFT JOIN source_files f ON f.id=s.file_id AND f.source_id=s.source_id
            WHERE s.agent=? AND s.native_id=?
            """, arguments: [session.agent.rawValue, session.nativeID]),
            let sourceRow = try Row.fetchOne(db, sql: """
                SELECT s.*,r.volume AS root_volume,r.inode AS root_inode,r.birth_seconds AS root_birth_seconds,
                       r.birth_nanoseconds AS root_birth_nanoseconds
                FROM sources s LEFT JOIN source_root_identities r ON r.source_id=s.id
                WHERE s.id=? AND s.removed=0
                """, arguments: [row["source_id"] as Int64]) else { return nil }
        let source = try decodeSource(sourceRow)
        guard source.agent == session.agent else { return nil }
        let role: String? = row["role"]
        let live = (row["source_deleted_at"] as Int64?) == nil && (row["state"] as String?) != "gone"
        let record: IndexedRecordLocation?
        if live, role == SourceFile.Role.session.rawValue || role == SourceFile.Role.subagent.rawValue,
           let path: String = row["rel_path"], let device: Int64 = row["device"], let inode: Int64 = row["inode"] {
            let rootIdentity: SourceRootIdentity?
            if let stored: String = sourceRow["root_volume"] {
                guard let volume = UUID(uuidString: stored) else { throw StoreError.invalidStoredValue }
                rootIdentity = .init(volume: volume, inode: sourceRow["root_inode"],
                                     birthSeconds: sourceRow["root_birth_seconds"], birthNanoseconds: sourceRow["root_birth_nanoseconds"])
            } else { rootIdentity = nil }
            record = .init(relativePath: path, device: device, inode: inode, rootIdentity: rootIdentity)
        } else { record = nil }
        return .init(key: session, source: source, workspace: row["cwd"], environment: row["environment"],
                     canResume: record != nil && role == SourceFile.Role.session.rawValue, record: record)
    }
}
