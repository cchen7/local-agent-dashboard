import GRDB

/// The project and session views share the same indexed completion proof.
/// These fragments use fixed aliases; the callers bind all record identifiers.
enum StructuredActionProjection {
    private static let completionID = """
        CASE WHEN call.transcript_tool_id IS NOT NULL
            AND (SELECT count(*) FROM (
                SELECT 1 FROM events peer WHERE peer.session_id=c.session_id AND peer.kind='tool_call'
                    AND peer.transcript_tool_id=call.transcript_tool_id LIMIT 2
            ))=1
        THEN (SELECT CASE WHEN count(*)=1 THEN min(id) END FROM (
            SELECT r.id FROM events r WHERE r.session_id=c.session_id AND r.action_outcome_id=call.transcript_tool_id
                AND (r.seq,r.id)>(call.seq,call.id) LIMIT 2
        )) END
        """

    private static var commandQuery: String {
        """
        SELECT c.command,c.ts,
            coalesce(outcome.tool_action ->> '$.completion.exitCode',c.exit_code) AS exit_code,
            coalesce(outcome.tool_action ->> '$.completion.durationMS',c.duration_ms) AS duration_ms,
            CASE WHEN json_type(outcome.tool_action,'$.completion.success') IN ('true','false')
                THEN outcome.tool_action ->> '$.completion.success'
                WHEN c.status IN ('succeeded','failed') THEN c.status='succeeded'
            END AS success
        FROM commands c LEFT JOIN events call ON call.id=c.event_id
        LEFT JOIN events outcome ON outcome.id=(\(completionID))
        """
    }

    static func commands(in sessionID: Int64, db: Database) throws -> [IndexedOverviewCommand] {
        try Row.fetchAll(db, sql: """
            \(commandQuery)
            WHERE c.session_id=? AND length(CAST(c.command AS BLOB))<=1048576
            ORDER BY c.ts DESC,c.id DESC LIMIT 10
            """, arguments: [sessionID]).map(decodeCommand)
    }

    static func command(for eventID: Int64, db: Database) throws -> IndexedOverviewCommand? {
        try Row.fetchOne(db, sql: """
            \(commandQuery)
            WHERE c.event_id=? AND length(CAST(c.command AS BLOB))<=1048576
            """, arguments: [eventID]).map(decodeCommand)
    }

    private static func decodeCommand(_ row: Row) -> IndexedOverviewCommand {
        .init(text: row["command"], timestamp: row["ts"], exitCode: row["exit_code"],
              durationMS: row["duration_ms"], success: row["success"])
    }

    // File rows belong to the original event, not to a session-wide rollup.
    static func filePreview(for eventID: Int64, db: Database) throws -> IndexedProjectToolAction? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT path,op,ts,added,removed,count(*) OVER () AS total
            FROM action_file_events WHERE event_id=? ORDER BY path,op LIMIT 3
            """, arguments: [eventID])
        guard let first = rows.first else { return nil }
        let files: [IndexedOverviewFile] = rows.map {
            .init(path: $0["path"], operation: $0["op"], count: 1, added: $0["added"], removed: $0["removed"],
                  timestamp: $0["ts"])
        }
        return .files(files, total: first["total"])
    }

    // A raw result is covered only by a unique, earlier same-session pair
    // that really has structured evidence. The project view omits only empty
    // wrappers; any independently useful result text remains visible.
    static func hasStructuredCall(chronological: Bool) -> String {
        let visible = chronological ? "AND earlier.ts>0" : ""
        return """
            e.kind='tool_result' AND e.transcript_tool_id IS NOT NULL
            AND (SELECT count(*) FROM (
                SELECT 1 FROM events member WHERE member.session_id=e.session_id
                    AND member.transcript_tool_id=e.transcript_tool_id LIMIT 3
            ))=2
            AND EXISTS (
                SELECT 1 FROM events earlier WHERE earlier.session_id=e.session_id
                    AND earlier.transcript_tool_id=e.transcript_tool_id AND earlier.kind='tool_call'
                    AND (earlier.seq,earlier.id)<(e.seq,e.id)
                    AND (
                        EXISTS(SELECT 1 FROM commands c WHERE c.event_id=earlier.id)
                        OR EXISTS(SELECT 1 FROM action_file_events f WHERE f.event_id=earlier.id)
                    )
                    \(visible)
            )
            """
    }

    static var hiddenProjectWrapper: String {
        """
        CASE
            WHEN e.kind='tool_result' AND e.transcript_tool_id IS NOT NULL
                THEN (e.text IS NULL OR e.text='') AND (\(hasStructuredCall(chronological: true)))
            WHEN e.kind='system' AND e.action_outcome_id IS NOT NULL
                THEN (e.text IS NULL OR e.text='') AND EXISTS (
                    SELECT 1 FROM events call JOIN commands c ON c.event_id=call.id
                    WHERE call.session_id=e.session_id AND call.kind='tool_call' AND call.ts>0
                        AND call.transcript_tool_id=e.action_outcome_id
                        AND (call.seq,call.id)<(e.seq,e.id) AND (\(completionID))=e.id
                )
            ELSE 0
        END
        """
    }
}
