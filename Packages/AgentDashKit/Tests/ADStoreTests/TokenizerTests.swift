import Foundation
import Testing
import GRDB
@testable import ADStore

@Test("SPEC 9.2: Chinese substring phrases, mixed text, identifiers, paths and emoji", arguments: [
    ("修复登录问题", "登录", true),
    ("修复登录问题", "\"登录问题\"", true),
    ("修复登录问题", "\"问题登录\"", false),
    ("这是一段用于验证中文子串检索的很长句子", "\"中文子串检索\"", true),
    ("中", "中", true),
    ("修复Login问题", "login", true),
    ("修复Login问题", "修复", true),
    ("verifyAndRotate", "verifyandrotate", true),
    ("verifyAndRotate", "rotate", true),
    ("verifyAndRotate", "and", true),
    ("parseHTTPResponse", "http", true),
    ("verify_and_rotate", "rotate", true),
    ("verify-and-rotate", "verify", true),
    ("src/middleware/auth.ts", "\"auth.ts\"", true),
    ("src/middleware/auth.ts", "auth", true),
    ("src/middleware/auth.ts", "ts", true),
    ("src/middleware/auth.ts", "middleware", true),
    ("登录😀成功🚀done", "成功", true),
    ("登录😀成功🚀done", "done", true),
    ("😀🚀", "login", false)
])
func tokenizerSearch(_ text: String, _ query: String, _ expected: Bool) throws {
    var config = Configuration()
    config.prepareDatabase { db in db.add(tokenizer: AgentDashTokenizer.self) }
    let queue = try DatabaseQueue(configuration: config)
    try queue.write { db in
        try db.execute(sql: "CREATE VIRTUAL TABLE sample USING fts5(text, tokenize='agentdash')")
        try db.execute(sql: "INSERT INTO sample(text) VALUES (?)", arguments: [text])
        let count = try Int.fetchOne(db, sql: "SELECT count(*) FROM sample WHERE sample MATCH ?", arguments: [query])
        #expect((count == 1) == expected)
    }
}

@Test("SPEC 9.2: overlapping bigrams have consecutive positions, identifier aliases are colocated")
func tokenPositions() throws {
    let queue = try DatabaseQueue()
    try queue.read { db in
        let tokenizer = try AgentDashTokenizer(db: db, arguments: [])
        let tokens = try tokenizer.tokenize(document: "修复登录问题 verifyAndRotate")
        #expect(tokens.map(\.token) == ["修复", "复登", "登录", "录问", "问题", "verifyandrotate", "verify", "and", "rotate"])
        #expect(tokens.map { $0.flags.contains(.colocated) } == [false, false, false, false, false, false, true, true, true])
    }
}

@Test("NFR-3: ASCII forwarding preserves mixed-token MATCH and highlight offsets")
func asciiTokenForwardingPreservesSearch() throws {
    var config = Configuration()
    config.prepareDatabase { db in db.add(tokenizer: AgentDashTokenizer.self) }
    let queue = try DatabaseQueue(configuration: config)
    try queue.write { db in
        try db.execute(sql: "CREATE VIRTUAL TABLE sample USING fts5(text, tokenize='agentdash')")
        try db.execute(sql: "INSERT INTO sample(text) VALUES (?)",
                       arguments: ["Login build42 parseHTTPResponse 修复登录 Café"])
        let highlighted = try String.fetchOne(db, sql: """
            SELECT highlight(sample,0,'[',']') FROM sample WHERE sample MATCH ?
            """, arguments: ["login OR build42 OR http OR 登录 OR cafe"])
        #expect(highlighted == "[Login] [build42] [parseHTTPResponse] 修复[登录] [Café]")
    }
}
