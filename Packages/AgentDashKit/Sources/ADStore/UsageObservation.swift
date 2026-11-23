import GRDB

public struct UsageProjectOption: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let name: String
}

public extension AgentStore {
    /// Each revision describes committed changes to the report's time series.
    func usageUpdates() -> some AsyncSequence<Int64, any Error> & Sendable {
        ValueObservation.tracking { db in
            try Int64.fetchOne(db, sql: "SELECT revision FROM usage_chart_state WHERE singleton=1") ?? 0
        }.removeDuplicates().values(in: databasePool, bufferingPolicy: .bufferingNewest(1))
    }

    func usageProjectOptions() throws -> [UsageProjectOption] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: "SELECT id,display_name FROM projects ORDER BY display_name,id").map {
                .init(id: $0["id"], name: $0["display_name"])
            }
        }
    }
}
