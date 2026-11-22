import ADCore
import Foundation
import GRDB

public enum SourceSettingsEditFailure: Error, Equatable, Sendable {
    case missingSource, staleEditor
}

public extension AgentStore {
    /// Record a folder re-grant without writing back the picker’s older
    /// metadata snapshot. The source must still have the same identity.
    func updateSourceBookmark(for id: Int64, agent: AgentKind, rootURL: URL, bookmark: Data) throws {
        guard rootURL.isFileURL, !bookmark.isEmpty else { throw StoreError.invalidLocation }
        try databasePool.write { db in
            try db.execute(sql: """
                UPDATE sources SET access_kind='bookmark',bookmark=?
                WHERE id=? AND agent=? AND root_path=? COLLATE BINARY AND removed=0
                """, arguments: [bookmark, id, agent.rawValue, rootURL.standardizedFileURL.path])
            guard db.changesCount == 1 else { throw SourceSettingsEditFailure.missingSource }
        }
    }

    /// Update metadata only. Compare the edited fields, not the bookmark,
    /// so re-granting access cannot be overwritten by an older editor.
    func updateSourceSettings(for id: Int64, from expected: SourceSettings, to replacement: SourceSettings,
                              hostHome: String?) throws {
        try databasePool.write { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT agent,label,environment,path_mappings_json,env_rules_json FROM sources WHERE id=? AND removed=0
                """, arguments: [id]) else { throw SourceSettingsEditFailure.missingSource }
            guard let agent = AgentKind(rawValue: row["agent"]) else { throw StoreError.invalidStoredValue }
            var current = expected
            current.label = row["label"]
            current.environment = row["environment"]
            let paths: String = row["path_mappings_json"]
            let rules: String = row["env_rules_json"]
            let decoder = JSONDecoder()
            current.pathMappings = try decoder.decode([PathMapping].self, from: Data(paths.utf8))
            current.environmentRules = try decoder.decode([EnvironmentRule].self, from: Data(rules.utf8))
            guard current == expected else { throw SourceSettingsEditFailure.staleEditor }
            let value = try replacement.validated(for: agent, previous: current, hostHome: hostHome)
            guard value != current else { return }
            let encoder = JSONEncoder()
            try db.execute(sql: """
                UPDATE sources SET label=?,environment=?,path_mappings_json=?,env_rules_json=? WHERE id=?
                """, arguments: [value.label, value.environment,
                                  String(decoding: try encoder.encode(value.pathMappings), as: UTF8.self),
                                  String(decoding: try encoder.encode(value.environmentRules), as: UTF8.self), id])
            if value.pathMappings != current.pathMappings {
                var gate = try SessionExclusionGate(policy: SessionExclusionPolicy.read(db))
                try gate.removeExistingMatches(sourceID: id, db: db)
                try gate.removeRetainedMatches(sourceID: id, db: db)
                try gate.finishRemovals(db: db)
                try UsageChartChanges.publish(db)
            }
        }
    }
}
