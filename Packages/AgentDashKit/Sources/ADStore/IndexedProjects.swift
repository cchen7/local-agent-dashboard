import ADCore
import CryptoKit
import Foundation
import GRDB

/// A catalog project if already resolved by the index, otherwise a workspace
/// identified without consulting a filesystem or resolving repository URLs.
public struct IndexedProject: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        fileprivate enum Key: Hashable, Sendable {
            case catalog(Int64)
            case host(Data)
            case environment(source: Int64, name: Data, path: Data)
            case retained(Data)
        }
        fileprivate let key: Key

        static func retained(_ fingerprint: Data) -> Self { .init(key: .retained(fingerprint)) }

        var catalogRowID: Int64? {
            if case .catalog(let id) = key { return id }
            return nil
        }

        var retentionKey: Data {
            var bytes = Data()
            func integer(_ value: Int64) {
                var big = value.bigEndian
                withUnsafeBytes(of: &big) { bytes.append(contentsOf: $0) }
            }
            func segment(_ data: Data) { integer(Int64(data.count)); bytes.append(data) }
            switch key {
            case .catalog(let id): bytes.append(0); integer(id)
            case .host(let path): bytes.append(1); segment(path)
            case let .environment(source, name, path):
                bytes.append(2); integer(source); segment(name); segment(path)
            case .retained(let fingerprint): return fingerprint
            }
            return Data(SHA256.hash(data: bytes))
        }

    }

    public let id: ID
    public let name: String
    public let path: String?
    public let repositoryURL: String?
    public let location: String?
    public let agents: [AgentKind]
    public let branches: [String]
    /// Stable activity order, newest first. Transcript text is read separately.
    public let sessions: [IndexedProjectSession]
    public let activityScope: IndexedProjectActivityScope
    public let pinTarget: IndexedProjectPinTarget
    public let pinned: Bool
    let revealPath: String?
    public var retainedOnly: Bool { sessions.isEmpty }

    static func catalogRetentionKey(for rowID: Int64) -> Data {
        ID(key: .catalog(rowID)).retentionKey
    }
    public var canRevealDirectory: Bool { revealPath != nil }
}

public struct IndexedProjectSession: Identifiable, Equatable, Sendable {
    public var id: SessionKey { session.id }
    public let session: IndexedSession
    public let worktree: String?
}

/// Stable membership keys from an index snapshot. The App cannot construct
/// arbitrary row IDs or read project events outside the store.
public struct IndexedProjectActivityScope: Equatable, Sendable {
    let sessionIDs: [Int64]
}

public enum IndexedProjectToolAction: Equatable, Sendable {
    case command(IndexedOverviewCommand)
    case files([IndexedOverviewFile], total: Int)
}

public struct IndexedProjectActivity: Identifiable, Equatable, Sendable {
    public let id: String
    public let session: SessionKey
    public let sessionTitle: String?
    public let timestamp: Int64
    public let kind: EventKind
    public let toolName: String?
    public let text: String?
    public let action: IndexedProjectToolAction?
}

public enum IndexedProjectFailure: Error, Equatable, Sendable {
    case invalidLimit
    case selectionChanged
}

public extension AgentStore {
    /// Observe only app-owned metadata. Paths are data for grouping and display.
    func indexedProjectUpdates(hostHome: String? = nil)
    -> some AsyncSequence<[IndexedProject], any Error> & Sendable {
        ValueObservation.tracking { db in
            try Self.projectCatalog(db, hostHome: hostHome)
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    /// At most 50 recent actions from the selected project, newest first.
    /// Rank IDs before reading text so a large project never loads its transcripts.
    func indexedProjectActivityUpdates(_ scope: IndexedProjectActivityScope, limit: Int = 20)
    throws -> some AsyncSequence<[IndexedProjectActivity], any Error> & Sendable {
        guard (1...50).contains(limit) else { throw IndexedProjectFailure.invalidLimit }
        return ValueObservation.tracking { db in
            try Self.projectActivity(db, members: scope.sessionIDs, limit: limit)
        }
        .removeDuplicates()
        .values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    internal static func projectCatalog(_ db: Database, hostHome: String?) throws -> [IndexedProject] {
        let catalog = try Row.fetchAll(db, sql: """
            SELECT id,key,display_name,root_path,repo_url FROM projects
            """).map(CatalogProject.init)
        let catalogByID = Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) })
        let pins = try ProjectPinPreferences.keys(db)
        let rootClaims = Dictionary(grouping: catalog.compactMap { project -> (Data, CatalogProject)? in
            guard let root = project.hostRootKey else { return nil }
            return (root, project)
        }, by: { $0.0 }).compactMapValues { claims in claims.count == 1 ? claims.first?.1 : nil }

        let rows = try Row.fetchCursor(db, sql: """
            SELECT s.id,s.agent,s.native_id,s.display_title AS title,s.display_title_source AS title_source,
                   s.cwd,s.git_branch,s.environment,s.status,s.status_reason,s.started_at,
                   coalesce(s.last_event_at,s.started_at) AS activity,s.source_deleted_at,s.source_id,s.project_id,
                   source.label AS source_label,source.environment AS source_environment,
                   source.agent AS source_agent,source.root_path AS source_root,source.path_mappings_json,source.removed
            FROM titled_sessions AS s JOIN sources AS source ON source.id=s.source_id
            LEFT JOIN source_files AS file ON file.id=s.file_id
            WHERE file.role IS NULL OR file.role<>?
            ORDER BY activity DESC,s.id DESC
            """, arguments: [SourceFile.Role.promptHistory.rawValue])
        let decoder = JSONDecoder()
        let normalizedHome = hostHome.flatMap(WorkspacePath.init)?.normalized
        var sources: [Int64: WorkspaceSource] = [:]
        var groups: [IndexedProject.ID: ProjectGroup] = [:]
        var order: [IndexedProject.ID] = []
        try rows.forEach { row in
            let session = try IndexedSession(row)
            let sourceID: Int64 = row["source_id"]
            let source: WorkspaceSource
            if let cached = sources[sourceID] {
                source = cached
            } else {
                source = .init(row, hostHome: normalizedHome, decoder: decoder)
                sources[sourceID] = source
            }
            let recorded = session.workspace.flatMap(WorkspacePath.init)
            let mapped = recorded?.normalized.flatMap {
                try? PathMapper.mappedPath($0, using: source.mappings, hostHome: normalizedHome)
            }.flatMap(WorkspacePath.init)
            let workspace = mapped ?? recorded
            let isHost = mapped != nil || (recorded?.normalized != nil &&
                source.localDefaultAgent == session.id.agent && session.environment == "Local")
            let explicitCatalog = (row["project_id"] as Int64?).flatMap { catalogByID[$0] }
            let hostRoot = isHost ? workspace?.hostRootKey : nil
            let attributed = explicitCatalog ?? hostRoot.flatMap { rootClaims[$0] }
            let id: IndexedProject.ID
            let name: String
            let path: String?
            let repository: String?
            let location: String?
            if let attributed {
                id = .init(key: .catalog(attributed.id))
                name = attributed.name
                path = attributed.normalizedRoot ?? attributed.path ?? workspace?.root
                repository = attributed.repoURL
                location = nil
            } else if let workspace {
                let bytes = Data(workspace.root.utf8)
                if isHost {
                    id = .init(key: .host(bytes))
                    location = nil
                } else {
                    id = .init(key: .environment(source: sourceID, name: Data(session.environment.utf8), path: bytes))
                    location = source.label == session.environment ? source.label : "\(source.label) · \(session.environment)"
                }
                name = workspace.name
                path = workspace.root
                repository = nil
            } else {
                return
            }
            if groups[id] == nil {
                order.append(id)
                let pinKey = attributed.map { ProjectPinPreferences.catalogKey($0.key) } ?? id.retentionKey
                groups[id] = .init(name: name, path: path, repository: repository, location: location, pinKey: pinKey)
            }
            let member = IndexedProjectSession(session: session, worktree: workspace?.worktree ?? recorded?.worktree)
            let knownPath: Data?
            if !source.removed, let path, let hostRoot, hostRoot.elementsEqual(path.utf8), path != "/" {
                knownPath = hostRoot
            } else { knownPath = nil }
            groups[id]?.append(member, rowID: row["id"], reveal: knownPath)
        }
        return ProjectPinPreferences.ordered(order.compactMap { id in groups[id]?.project(id, pins: pins) })
    }

    private static func projectActivity(_ db: Database, members: [Int64], limit: Int) throws -> [IndexedProjectActivity] {
        var latest: [(id: Int64, time: Int64, kind: String)] = []
        // Use the per-session event index. Chunk the membership so a single
        // project cannot exceed SQLite's bound-argument limit.
        let chunkSize = 400
        for start in stride(from: 0, to: members.count, by: chunkSize) {
            let chunk = members[start..<min(start + chunkSize, members.count)]
            let bindings = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let arguments = chunk.map(\.databaseValue) + [limit.databaseValue]
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.id,e.ts,e.kind FROM events e INDEXED BY events_session_seq
                WHERE e.session_id IN (\(bindings)) AND e.ts>0
                    AND e.kind IN ('user','assistant','summary','system','error','tool_call','tool_result')
                    AND NOT (\(StructuredActionProjection.hiddenProjectWrapper))
                ORDER BY e.ts DESC,e.id DESC LIMIT ?
                """, arguments: .init(arguments))
            latest.append(contentsOf: rows.map { (id: $0[0], time: $0[1], kind: $0[2]) })
            latest.sort { ($0.time, $0.id) > ($1.time, $1.id) }
            if latest.count > limit { latest.removeLast(latest.count - limit) }
        }
        return try latest.map { candidate in
            let action: IndexedProjectToolAction?
            if candidate.kind == EventKind.toolCall.rawValue {
                if let command = try StructuredActionProjection.command(for: candidate.id, db: db) {
                    action = .command(command)
                } else {
                    action = try StructuredActionProjection.filePreview(for: candidate.id, db: db)
                }
            } else { action = nil }
            guard let row = try Row.fetchOne(db, sql: """
                SELECT e.dedupe_key,e.kind,s.agent,s.native_id,
                    s.display_title AS title,
                    CASE WHEN length(CAST(e.tool_name AS BLOB))<=16384 THEN e.tool_name END AS tool_name,
                    CASE WHEN ? AND length(CAST(e.text AS BLOB))<=1048576 THEN e.text END AS text
                FROM events e JOIN titled_sessions s ON s.id=e.session_id WHERE e.id=?
                """, arguments: [action == nil, candidate.id]),
                let agent = AgentKind(rawValue: row["agent"]), let kind = EventKind(rawValue: row["kind"])
            else { throw StoreError.invalidStoredValue }
            return .init(id: row["dedupe_key"], session: .init(agent: agent, nativeID: row["native_id"]),
                         sessionTitle: row["title"], timestamp: candidate.time, kind: kind,
                         toolName: row["tool_name"], text: row["text"], action: action)
        }
    }
}

private struct CatalogProject {
    let id: Int64
    let key: String
    let name: String
    let path: String?
    let normalizedRoot: String?
    let hostRootKey: Data?
    let repoURL: String?

    init(_ row: Row) {
        id = row["id"]
        key = row["key"]
        name = row["display_name"]
        path = row["root_path"]
        let workspace = path.flatMap(WorkspacePath.init)
        // The displayed catalog path can still name the worktree.
        normalizedRoot = workspace?.normalized
        hostRootKey = workspace?.hostRootKey
        repoURL = row["repo_url"]
    }
}

private struct WorkspaceSource {
    let label: String
    let mappings: [PathMapping]
    let localDefaultAgent: AgentKind?
    let removed: Bool

    init(_ row: Row, hostHome: String?, decoder: JSONDecoder) {
        label = row["source_label"]
        removed = row["removed"]
        let serialized: String = row["path_mappings_json"]
        mappings = (try? decoder.decode([PathMapping].self, from: Data(serialized.utf8))) ?? []
        // A re-grant changes how a source is accessed, not its provenance.
        if let home = hostHome, let agent = AgentKind(rawValue: row["source_agent"]),
           (row["source_environment"] as String) == "Local",
           let sourceRoot = WorkspacePath(row["source_root"])?.normalized {
            let expected = (home == "/" ? home : home + "/") + agent.defaultSourceDirectoryName
            localDefaultAgent = sourceRoot.utf8.elementsEqual(expected.utf8) ? agent : nil
        } else {
            localDefaultAgent = nil
        }
    }
}

private struct WorkspacePath {
    /// Nil for ambiguous absolute spellings. Keep them literal and isolated.
    let normalized: String?
    let root: String
    let name: String
    let worktree: String?

    /// One identity for catalog claims and proven host workspaces.
    var hostRootKey: Data? { normalized.map { _ in Data(root.utf8) } }

    init?(_ path: String) {
        let bytes = path.utf8
        guard bytes.first == 0x2F, !bytes.contains(0) else { return nil }
        let components = bytes.split(separator: 0x2F)
        let hasAuthority = bytes.starts(with: [0x2F, 0x2F]) && !bytes.starts(with: [0x2F, 0x2F, 0x2F])
        if hasAuthority || components.contains(where: { $0.elementsEqual("..".utf8) }) {
            normalized = nil
            root = path
            name = components.last.map { String(decoding: $0, as: UTF8.self) } ?? path
            worktree = nil
            return
        }
        let cleaned = components.filter { !$0.elementsEqual(".".utf8) }
            .map { String(decoding: $0, as: UTF8.self) }
        normalized = "/" + cleaned.joined(separator: "/")
        let marker = cleaned.indices.first {
            $0 > 0 && $0 + 2 < cleaned.count && cleaned[$0] == ".claude" && cleaned[$0 + 1] == "worktrees"
        }
        let rootComponents = cleaned.prefix(marker ?? cleaned.count)
        root = "/" + rootComponents.joined(separator: "/")
        name = rootComponents.last ?? "/"
        worktree = marker.map { cleaned[$0 + 2] }
    }
}

private struct ProjectGroup {
    let name: String
    let path: String?
    let repository: String?
    let location: String?
    let pinKey: Data
    private var revealPaths: Set<Data> = []
    private var members: [IndexedProjectSession] = []
    private var rowIDs: [Int64] = []
    private var agents: Set<AgentKind> = []
    private var branches: Set<String> = []

    init(name: String, path: String?, repository: String?, location: String?, pinKey: Data) {
        self.name = name
        self.path = path
        self.repository = repository
        self.location = location
        self.pinKey = pinKey
    }

    mutating func append(_ member: IndexedProjectSession, rowID: Int64, reveal: Data?) {
        if let reveal { revealPaths.insert(reveal) }
        members.append(member)
        rowIDs.append(rowID)
        agents.insert(member.session.id.agent)
        if let branch = member.session.branch, !branch.isEmpty { branches.insert(branch) }
    }

    func project(_ id: IndexedProject.ID, pins: Set<Data>) -> IndexedProject {
        let directory: String?
        if revealPaths.count == 1, let path, revealPaths.contains(Data(path.utf8)) {
            directory = path
        } else { directory = nil }
        return .init(id: id, name: name, path: path, repositoryURL: repository, location: location,
                     agents: AgentKind.allCases.filter(agents.contains), branches: branches.sorted(),
                     sessions: members, activityScope: .init(sessionIDs: rowIDs.sorted()),
                     pinTarget: .init(id: id, key: pinKey), pinned: pins.contains(pinKey), revealPath: directory)
    }
}
