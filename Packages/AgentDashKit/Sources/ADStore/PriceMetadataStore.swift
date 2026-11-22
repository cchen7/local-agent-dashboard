import Foundation
import GRDB

public struct UnpricedModelUsage: Equatable, Identifiable, Sendable {
    public let model: String?
    public let tokens: Int64
    public var id: String { model ?? "" }
}

public extension AgentStore {
    /// App-owned metadata only. Never opens a price file or updates a token record.
    func lastVerifiedPriceBytes() throws -> Data? {
        try databasePool.read { db in
            guard let value = try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key='price_verified_bytes'"),
                  value.utf8.count <= 5_592_408 else { return nil }
            return Data(base64Encoded: value)
        }
    }

    func rememberVerifiedPriceBytes(_ data: Data) throws {
        guard !data.isEmpty, data.count <= 4 * 1024 * 1024 else { throw StoreError.invalidStoredValue }
        let value = data.base64EncodedString()
        try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('price_verified_bytes',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value WHERE app_meta.value<>excluded.value
                """, arguments: [value])
        }
    }

    /// Reports persisted unpriced volume. A verified file is not proof that
    /// historical estimates have been applied.
    func unpricedUsageByModel(limit: Int = 200) throws -> [UnpricedModelUsage] {
        try databasePool.read { db in
            try Row.fetchAll(db, sql: """
                SELECT model,sum(unpriced_tokens) AS tokens FROM token_minute WHERE unpriced_tokens>0
                GROUP BY model ORDER BY tokens DESC,model LIMIT ?
                """, arguments: [max(1, min(500, limit))]).map { row in
                    let name: String = row["model"]
                    return UnpricedModelUsage(model: name.isEmpty ? nil : name, tokens: row["tokens"])
                }
        }
    }
}
