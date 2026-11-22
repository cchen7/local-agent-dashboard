import GRDB

enum UsageChartChanges {
    private static let retainedRevisions = 128

    static func publish(_ db: Database) throws {
        try db.execute(sql: """
            INSERT INTO usage_chart_changes(revision,low_ts,high_ts)
            SELECT revision+1,pending_low,pending_high FROM usage_chart_state WHERE pending_low IS NOT NULL;
            """)
        guard db.changesCount != 0 else { return }
        try db.execute(sql: """
            UPDATE usage_chart_state SET revision=revision+1,pending_low=NULL,pending_high=NULL WHERE singleton=1;
            DELETE FROM usage_chart_changes
            WHERE revision<=(SELECT revision-? FROM usage_chart_state WHERE singleton=1);
            """, arguments: [retainedRevisions])
    }

    /// A rebuild replaces projections without changing individual token
    /// rows. Advance the revision with a gap so prior snapshots fully reload.
    static func invalidateAll(_ db: Database) throws {
        try db.execute(sql: """
            DELETE FROM usage_chart_changes;
            UPDATE usage_chart_state
            SET revision=revision+1,pending_low=NULL,pending_high=NULL WHERE singleton=1;
            """)
    }

    /// An unjournaled writer leaves a pending range, so reads cannot reuse a
    /// snapshot until it is published. This is safe even for ad hoc DB changes.
    static func revision(_ db: Database) throws -> Int64? {
        try Int64.fetchOne(db, sql: """
            SELECT revision FROM usage_chart_state WHERE singleton=1 AND pending_low IS NULL
            """)
    }

    enum Delta {
        case none, changed(ClosedRange<Int64>), reload
    }

    static func delta(_ db: Database, after: Int64?, through: Int64?) throws -> Delta {
        guard let after, let through, 0 <= after, after <= through else { return .reload }
        if after == through { return .none }
        guard through - after <= Int64(retainedRevisions) else { return .reload }
        let row = try Row.fetchOne(db, sql: """
            SELECT count(*) AS revisions,min(low_ts) AS low,max(high_ts) AS high
            FROM usage_chart_changes WHERE revision>? AND revision<=?
            """, arguments: [after, through])
        guard let row, row["revisions"] as Int64 == through - after,
              let low: Int64 = row["low"], let high: Int64 = row["high"], low <= high else { return .reload }
        return .changed(low...high)
    }
}
