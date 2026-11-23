import ADCore
import Darwin
import Foundation
import GRDB

struct IndexedPriceUsage {
    let agent: AgentKind
    let model: String?
    let timestamp: Int64
    let counts: TokenCounts
    let precision: TokenPrecision
    let storedMicroUSD: Int64
    let wasUnpriced: Bool
}

enum PriceUsageSnapshot {
    enum Failure: Error { case notStandaloneSnapshot, incompatibleIndex, invalidUsage }

    /// Consume only accounting columns from an explicit, offline Agent Dashboard copy.
    /// A read-only connection to a live WAL database can still touch its sidecars.
    static func visit(_ url: URL, _ body: (IndexedPriceUsage) throws -> Void) throws {
        let path = url.path(percentEncoded: false)
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.notStandaloneSnapshot }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              ["-wal", "-shm", "-journal"].allSatisfy({ absent(path + $0) }),
              let header = try handle.read(upToCount: 100), header.count == 100,
              header.prefix(16) == Data("SQLite format 3\0".utf8),
              header[18] == 1, header[19] == 1
        else { throw Failure.notStandaloneSnapshot }
        var configuration = Configuration()
        configuration.readonly = true
        let db = try DatabaseQueue(path: path, configuration: configuration)
        try db.read { database in
            guard try database.tableExists("grdb_migrations"),
                  try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier='v11_token_quotes')") == true,
                  try database.tableExists("token_events")
            else { throw Failure.incompatibleIndex }
            let rows = try Row.fetchCursor(database, sql: """
                SELECT agent, model, ts, input_fresh, cache_read, cache_write, cache_write_1h,
                       output, reasoning, precision, cost_micro_usd, price_status
                FROM token_events
                """)
            while let row = try rows.next() {
                let rawAgent: String? = row[0]
                let rawPrecision: String? = row[9]
                guard let agent = rawAgent.flatMap(AgentKind.init(rawValue:)),
                      let precision = rawPrecision.flatMap(TokenPrecision.init(rawValue:)),
                      let timestamp: Int64 = row[2], let fresh: Int64 = row[3], let read: Int64 = row[4],
                      let write: Int64 = row[5], let longWrite: Int64 = row[6], let output: Int64 = row[7],
                      let reasoning: Int64 = row[8], let cost: Int64 = row[10], cost >= 0,
                      let status: String = row[11], ["priced", "approx", "unpriced"].contains(status),
                      status != "unpriced" || cost == 0
                else { throw Failure.invalidUsage }
                try body(.init(agent: agent, model: row[1], timestamp: timestamp,
                               counts: .init(inputFresh: fresh, cacheRead: read, cacheWrite: write,
                                             cacheWrite1h: longWrite, output: output, reasoning: reasoning),
                               precision: precision, storedMicroUSD: cost, wasUnpriced: status == "unpriced"))
            }
        }
    }

    private static func absent(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }
}
