import CryptoKit
import Foundation
import GRDB

/// Snapshot identity for a pin action. A reused catalog row number is not the
/// same target when the actual repository key changed.
public struct IndexedProjectPinTarget: Equatable, Sendable {
    public let id: IndexedProject.ID
    let key: Data
}

public struct IndexedProjectDirectoryTarget: Equatable, Sendable {
    public let path: String
    let identity: IndexedProjectPinTarget
}

public extension AgentStore {
    func setProjectPinned(_ target: IndexedProjectPinTarget, pinned: Bool, hostHome: String? = nil) throws {
        try databasePool.write { db in
            let projects = try ProjectUsageRead.catalog(db, hostHome: hostHome)
            guard projects.contains(where: { $0.pinTarget == target }) else {
                throw IndexedProjectFailure.selectionChanged
            }
            if pinned {
                try db.execute(sql: "INSERT OR IGNORE INTO project_pins VALUES(?)", arguments: [target.key])
            } else {
                try db.execute(sql: "DELETE FROM project_pins WHERE project_key=?", arguments: [target.key])
            }
            if let id = target.id.catalogRowID {
                try db.execute(sql: "UPDATE projects SET pinned=? WHERE id=?", arguments: [pinned, id])
            }
        }
    }

    /// Re-read the live project catalog on click. Retained-only and unproven
    /// environment paths never produce a Finder target.
    func projectDirectoryTarget(_ target: IndexedProjectPinTarget, hostHome: String? = nil) throws -> IndexedProjectDirectoryTarget? {
        try databasePool.read { db in
            guard let project = try Self.projectCatalog(db, hostHome: hostHome).first(where: { $0.pinTarget == target }),
                  let path = project.revealPath else { return nil }
            return .init(path: path, identity: project.pinTarget)
        }
    }
}

enum ProjectPinPreferences {
    static func catalogKey(_ key: String) -> Data {
        // Domain 3 is distinct from the existing host/environment/archive
        // identity hashes. A cleared catalog may get new integer row IDs.
        Data(SHA256.hash(data: Data([3]) + Data(key.utf8)))
    }

    static func migrate(_ db: Database) throws {
        // ValueObservation relies on the SQLite row update hook, which
        // does not fire for WITHOUT ROWID tables.
        try db.execute(sql: "CREATE TABLE project_pins(project_key BLOB PRIMARY KEY NOT NULL)")
        let legacy = try String.fetchAll(db, sql: "SELECT key FROM projects WHERE pinned<>0")
        for key in legacy {
            try db.execute(sql: "INSERT OR IGNORE INTO project_pins VALUES(?)", arguments: [catalogKey(key)])
        }
    }

    static func keys(_ db: Database) throws -> Set<Data> {
        Set(try Data.fetchAll(db, sql: "SELECT project_key FROM project_pins"))
    }

    static func ordered(_ projects: [IndexedProject]) -> [IndexedProject] {
        projects.filter(\.pinned) + projects.filter { !$0.pinned }
    }

    static func catalogKeysForArchives(_ db: Database) throws -> [Data: Data] {
        let entries = try Row.fetchAll(db, sql: "SELECT id,key FROM projects")
        var keys: [Data: Data] = [:]
        for row in entries {
            let id = IndexedProject.catalogRetentionKey(for: row["id"])
            keys[id] = catalogKey(row["key"])
        }
        return keys
    }
}
