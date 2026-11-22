import ADCore
import Foundation
import GRDB

/// Read complete logical messages from the owned index. Preserve one bounded
/// message at a time so whole-field masking is effective even across fragments.
enum TopicCorpus {
    static func counts(_ db: Database, session: Int64, claude: Bool, scoring: IndexTopicScoring) throws -> [String: Double] {
        let rows = try Row.fetchCursor(db, sql: """
            SELECT kind,CASE WHEN length(CAST(text AS BLOB))<=1048576 THEN text END AS preview,
              CASE WHEN ? AND substr(dedupe_key,1,13)='claude:event:'
                THEN CASE WHEN kind='assistant' AND length(CAST(meta_json AS BLOB))<=4096
                              AND json_valid(meta_json) AND json_extract(meta_json,'$.claude_message_id') IS NOT NULL
                     THEN 'm:' || json_extract(meta_json,'$.claude_message_id')
                     ELSE 'p:' || seq || ':' || rtrim(dedupe_key,'0123456789') END
                ELSE 'e:' || id END AS message
            FROM events WHERE session_id=? AND kind IN ('user','assistant') AND text IS NOT NULL
              AND (transcript_channel IS NOT 'fallback' OR NOT EXISTS(
                  SELECT 1 FROM events preferred
                  WHERE preferred.session_id=? AND preferred.transcript_channel='preferred'))
            ORDER BY kind,message COLLATE BINARY,seq,rtrim(dedupe_key,'0123456789'),
                CAST(substr(dedupe_key,length(rtrim(dedupe_key,'0123456789'))+1) AS INTEGER),id
            """, arguments: [claude, session, session])
        var counts: [String: Double] = [:]
        var tooManyTerms = false
        func merge(_ values: [String: Double]) {
            guard !tooManyTerms else { return }
            for (term, count) in values where !term.isEmpty && term.utf8.count <= 512 && count.isFinite && count > 0 {
                counts[term, default: 0] += count
                if counts.count > 65_536 {
                    tooManyTerms = true
                    return
                }
            }
        }
        var message: String?
        var role = ""
        var text = ""
        var bytes = 0
        var blocks = 0
        var oversized = false
        func countMessage() {
            guard message != nil, !oversized else { return }
            let input: IndexTopicInput = role == "user" ? .prompt(text) : .reply(text)
            merge(scoring.counts(input))
        }
        while let row = try rows.next() {
            try Task.checkCancellation()
            let next: String = row["message"]
            let kind: String = row["kind"]
            if role != kind || message?.utf8.elementsEqual(next.utf8) != true {
                countMessage()
                guard !tooManyTerms else { return [:] }
                role = kind
                message = next
                text = ""
                bytes = 0
                blocks = 0
                oversized = false
            }
            guard !oversized, let piece: String = row["preview"], blocks < 240,
                  piece.utf8.count <= 1_048_576 - bytes else {
                oversized = true
                continue
            }
            // Mask the reconstructed message, including secrets split across blocks.
            text.append(piece)
            bytes += piece.utf8.count
            blocks += 1
        }
        countMessage()
        let paths = try String.fetchCursor(db, sql: """
            SELECT DISTINCT path FROM file_touches WHERE session_id=? AND length(CAST(path AS BLOB))<=16384
            """, arguments: [session])
        while let path = try paths.next() {
            try Task.checkCancellation()
            merge(scoring.counts(.path(path)))
            guard !tooManyTerms else { return [:] }
        }
        return tooManyTerms ? [:] : counts
    }
}
