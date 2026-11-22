import ADCore
import ADPrivacy
import Foundation
import GRDB

public extension AgentStore {
    func displaySecretMaskingEnabled() throws -> Bool {
        try databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key='privacy_mask_display'") != "0"
        }
    }

    func setDisplaySecretMaskingEnabled(_ enabled: Bool) throws {
        try databasePool.write { db in
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('privacy_mask_display',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [enabled ? "1" : "0"])
        }
    }

    func indexSecretRedactionEnabled() throws -> Bool {
        try databasePool.read { try IndexSecretRedaction.enabled($0) }
    }

    /// Applying the setting and redacting existing rows are one writer
    /// transaction. Disabling only affects future writes.
    @discardableResult
    func setIndexSecretRedactionEnabled(_ enabled: Bool) throws -> Bool {
        try databasePool.write { db in
            guard try enabled != IndexSecretRedaction.enabled(db) else { return false }
            if enabled { try IndexSecretRedaction.scrubExisting(db) }
            try db.execute(sql: """
                INSERT INTO app_meta(key,value) VALUES('privacy_strip_index_secrets',?)
                ON CONFLICT(key) DO UPDATE SET value=excluded.value
                """, arguments: [enabled ? "1" : "0"])
            return true
        }
    }
}

enum IndexSecretRedaction {
    static func enabled(_ db: Database) throws -> Bool {
        switch try String.fetchOne(db, sql: "SELECT value FROM app_meta WHERE key='privacy_strip_index_secrets'") {
        case nil, "0": return false
        case "1": return true
        default: throw StoreError.invalidStoredValue
        }
    }

    static func scrubExisting(_ db: Database) throws {
        try pages("SELECT id,text,tool_name,meta_json,tool_action FROM events", db: db) { row in
            let text: String? = row["text"]
            let tool: String? = row["tool_name"]
            let metadata: String? = row["meta_json"]
            let rawAction: String? = row["tool_action"]
            let parsed = rawAction.flatMap { try? JSONDecoder().decode(ToolActionEvidence.self, from: Data($0.utf8)) }
            let cleanAction = try AgentStore.encodedToolAction(parsed.map(redactedAction))
            let clean = text.map(IndexSecretMasker.text)
            let cleanTool = tool.map(IndexSecretMasker.text)
            let cleanMetadata = metadata.flatMap(IndexSecretMasker.eventMetadata)
            let id: Int64 = row["id"]
            if clean != text || cleanTool != tool {
                // Updating these columns also updates FTS through its normal triggers.
                try db.execute(sql: "UPDATE events SET text=?,tool_name=?,meta_json=?,tool_action=? WHERE id=?",
                               arguments: [clean, cleanTool, cleanMetadata, cleanAction, id])
            } else if cleanMetadata != metadata || cleanAction != rawAction {
                try db.execute(sql: "UPDATE events SET meta_json=?,tool_action=? WHERE id=?",
                               arguments: [cleanMetadata, cleanAction, id])
            }
        }
        try pages("SELECT id,title,user_title,first_prompt,latest_summary FROM sessions", db: db) { row in
            let title: String? = row["title"]
            let custom: String? = row["user_title"]
            let prompt: String? = row["first_prompt"]
            let summary: String? = row["latest_summary"]
            let cleanTitle = title.map(IndexSecretMasker.text)
            let cleanCustom = custom.map(IndexSecretMasker.text)
            let cleanPrompt = prompt.map(IndexSecretMasker.text)
            let cleanSummary = summary.map(IndexSecretMasker.text)
            if cleanTitle != title || cleanCustom != custom || cleanPrompt != prompt || cleanSummary != summary {
                try db.execute(sql: "UPDATE sessions SET title=?,user_title=?,first_prompt=?,latest_summary=? WHERE id=?",
                               arguments: [cleanTitle, cleanCustom, cleanPrompt, cleanSummary, row["id"] as Int64])
            }
        }
        try pages("SELECT id,command FROM commands", db: db) { row in
            let command: String = row["command"]
            let clean = IndexSecretMasker.text(command)
            if clean != command {
                try db.execute(sql: "UPDATE commands SET command=? WHERE id=?", arguments: [clean, row["id"] as Int64])
            }
        }
        try pages("SELECT id,decoder_state FROM source_files", db: db) { row in
            if let state: Data = row["decoder_state"], !IndexSecretMasker.canKeepDecoderState(state) {
                try db.execute(sql: "UPDATE source_files SET decoder_state=NULL,parser_version=0 WHERE id=?", arguments: [row["id"] as Int64])
            }
        }
        let archiveLimit = try ToolOutputArchive.limit(db)
        try pages("SELECT id,codec,raw_len,data FROM blobs", db: db) { row in
            let id: Int64 = row["id"]
            let text = ToolOutputArchive.decode(row)
            let clean = text.map(IndexSecretMasker.text)
            guard text == nil || clean != text else { return }
            if let clean, let replacement = ToolOutputArchive.encode(clean, limit: archiveLimit) {
                try db.execute(sql: "UPDATE blobs SET raw_len=?,data=? WHERE id=?", arguments: [replacement.rawCount,replacement.bytes,id])
            } else {
                try db.execute(sql: "UPDATE events SET blob_id=NULL WHERE blob_id=?", arguments: [id])
                try ToolOutputArchive.removeUnreferenced(id, db: db)
            }
        }
        try TopicLedger.invalidateAll(db)
    }

    private static func redactedAction(_ value: ToolActionEvidence) -> ToolActionEvidence {
        .init(files: value.files.map {
            .init(path: IndexSecretMasker.text($0.path), operation: $0.operation, added: $0.added, removed: $0.removed)
        }, command: value.command.map(IndexSecretMasker.text), completion: value.completion)
    }

    static func event(_ value: EventRecord) -> EventRecord {
        var safe = value
        safe.text = value.text.map(IndexSecretMasker.text)
        safe.toolName = value.toolName.map(IndexSecretMasker.text)
        safe.metadataJSON = value.metadataJSON.flatMap(IndexSecretMasker.eventMetadata)
        safe.toolAction = value.toolAction.map(redactedAction)
        if var capture = value.toolOutput {
            capture.archiveText = capture.archiveText.map(IndexSecretMasker.text)
            if let text = capture.archiveText {
                let prefix = Data(text.utf8.prefix(ToolOutputCapture.searchableBytes))
                safe.text = (0...min(3, prefix.count)).lazy.compactMap {
                    String(bytes: prefix.dropLast($0), encoding: .utf8)
                }.first ?? ""
            }
            safe.toolOutput = capture
        }
        return safe
    }

    static func session(_ value: SessionRecord) -> SessionRecord {
        var safe = value
        safe.title = value.title.map(IndexSecretMasker.text)
        return safe
    }

    static func checkpoint(_ value: Checkpoint) -> Checkpoint {
        guard let state = value.decoderState, !IndexSecretMasker.canKeepDecoderState(state) else { return value }
        // Dropping opaque state while resuming at the tail can corrupt usage.
        // Keep the durable cursor for inspection, but replay at the next open.
        var safe = value
        safe.decoderState = nil
        safe.parserVersion = 0
        return safe
    }

    /// Use a keyset and materialize at most one page before changing the table.
    private static func pages(_ select: String, db: Database, visit: (Row) throws -> Void) throws {
        var after: Int64?
        while true {
            try Task.checkCancellation()
            let next: Int64? = try autoreleasepool {
                let rows: [Row]
                if let after {
                    rows = try Row.fetchAll(db, sql: select + " WHERE id>? ORDER BY id LIMIT 256", arguments: [after])
                } else {
                    rows = try Row.fetchAll(db, sql: select + " ORDER BY id LIMIT 256")
                }
                guard let last = rows.last else { return nil }
                try rows.forEach(visit)
                return last["id"]
            }
            guard let next else { return }
            after = next
        }
    }
}
