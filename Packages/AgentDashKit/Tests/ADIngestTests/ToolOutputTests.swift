import ADAdapters
import ADCore
import ADIngest
import ADStore
import Foundation
import Testing

@Test("ADP-7: compressed tool body stays outside search, follows privacy policy, and falls back to a verified read-only line")
func archivedToolOutputIsBoundedAndOriginalIsVerified() throws {
    let box = try OutputFixture()
    defer { box.remove() }
    let tail = "syntheticoutputtail"
    let body = "API_TOKEN=synthetic-only-secret\n" + String(repeating: "synthetic output line\n", count: 720) + tail
    let bytes = try box.line(body)
    try bytes.write(to: box.file)
    _ = try box.readIndex()
    let event = try #require(try box.store.events(in: box.key).first)
    #expect(event.text?.utf8.count == 2048 && event.toolOutput == nil)
    let indexed = try box.store.toolOutputDetails(in: box.key, eventKey: event.dedupeKey)
    #expect(indexed.archivedText == body && indexed.hasOriginal)
    let scope = IndexedSearchScope(now: 1_770_000_000_000, timeZone: .gmt)
    #expect(try box.store.searchIndex(SearchQuery.parse(tail), scope: scope).matchCount == 0)
    #expect(try box.store.setIndexSecretRedactionEnabled(true))
    let redacted = try box.store.toolOutputDetails(in: box.key, eventKey: event.dedupeKey)
    #expect(redacted.archivedText?.contains("API_TOKEN=••••••") == true)
    #expect(redacted.archivedText?.contains("synthetic-only-secret") == false)
    #expect(try box.store.setToolOutputArchiveLimit(.previewOnly))
    let evicted = try box.store.toolOutputDetails(in: box.key, eventKey: event.dedupeKey)
    #expect(evicted.archivedText == nil && evicted.hasOriginal)
    let handle = try FileHandle(forWritingTo: box.file)
    try handle.seekToEnd()
    let harmless = Data("{}\n".utf8)
    try handle.write(contentsOf: harmless)
    try handle.close()
    let registration = try #require(try box.store.registeredToolOutput(in: box.key, eventKey: event.dedupeKey))
    let original = try ToolOutputReader.read(registration, authorizedRoot: box.root)
    #expect(original.text == body && !original.truncated)
    #expect(registration.redact)
    #expect(try Data(contentsOf: box.file) == bytes + harmless)

    let rewrite = try FileHandle(forWritingTo: box.file)
    try rewrite.truncate(atOffset: 0)
    try rewrite.write(contentsOf: box.line(body + "changed"))
    try rewrite.close()
    #expect(throws: ToolOutputReadFailure.changedOrUnavailable) {
        try ToolOutputReader.read(registration, authorizedRoot: box.root)
    }
    try box.store.removeRegisteredSource(try #require(box.source.id))
    #expect(try box.store.registeredToolOutput(in: box.key, eventKey: event.dedupeKey) == nil)
}

@Test("ADP-7 / SEC-3: a Claude persisted-output marker reads only its own verified sidecar")
func claudeSidecarDoesNotFollowPrintedPath() throws {
    let box = try OutputFixture()
    defer { box.remove() }
    let sidecars = box.file.deletingPathExtension().appendingPathComponent("tool-results", isDirectory: true)
    try FileManager.default.createDirectory(at: sidecars, withIntermediateDirectories: true)
    let path = sidecars.appendingPathComponent("result.txt")
    let payload = String(repeating: "synthetic sidecar bytes\n", count: 170)
    try Data(payload.utf8).write(to: path)
    let stub = "<persisted-output>\nFull output saved to: /foreign/root/projects/demo/\(box.key.nativeID)/tool-results/result.txt\npreview\n</persisted-output>"
    try box.line(stub).write(to: box.file)
    _ = try box.readIndex()
    let event = try #require(try box.store.events(in: box.key).first)
    let details = try box.store.toolOutputDetails(in: box.key, eventKey: event.dedupeKey)
    #expect(details.archivedText == nil && details.hasOriginal)
    let registration = try #require(try box.store.registeredToolOutput(in: box.key, eventKey: event.dedupeKey))
    #expect(try ToolOutputReader.read(registration, authorizedRoot: box.root).text == payload)
    #expect(try Data(contentsOf: path) == Data(payload.utf8))
    try FileManager.default.removeItem(at: path)
    try FileManager.default.createSymbolicLink(at: path, withDestinationURL: box.file)
    #expect(throws: (any Error).self) { try ToolOutputReader.read(registration, authorizedRoot: box.root) }
}

private struct OutputFixture {
    let directory: URL
    let root: URL
    let file: URL
    let store: AgentStore
    let source: Source
    let key = SessionKey(agent: .claudeCode, nativeID: "00000000-0000-0000-0000-000000000037")

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("tool-output-\(UUID())")
        root = directory.appendingPathComponent("source")
        let project = root.appendingPathComponent("projects/demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        file = project.appendingPathComponent(key.nativeID + ".jsonl")
        store = try AgentStore(databaseURL: directory.appendingPathComponent("index.sqlite"))
        var descriptor = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
        descriptor.id = try store.upsertSource(descriptor)
        source = descriptor
    }

    func line(_ body: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": "synthetic-result", "sessionId": key.nativeID,
            "cwd": "/synthetic/tool-output", "message": ["content": [["type": "tool_result", "tool_use_id": "synthetic-call", "content": body]]]]) + Data([0x0A])
    }

    func readIndex() throws -> JSONLImportResult {
        let adapter = ClaudeCodeAdapter()
        let input = try #require(try adapter.discover(in: source, authorizedRoot: root).first)
        return try JSONLFileImporter.importFile(input, from: source, authorizedRoot: root, store: store, adapter: adapter)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

@Test("ADP-7: a large Claude envelope does not make a complete recovered body look truncated")
func oversizedEnvelopeLocatesCompleteToolResult() throws {
    let box = try OutputFixture()
    defer { box.remove() }
    let body = String(repeating: "synthetic complete output\n", count: 160)
    let extra = Data(("{\"unrelated\":\"" + String(repeating: "x", count: 1_060_000) + "\",").utf8)
    let bytes = try extra + box.line(body).dropFirst()
    try bytes.write(to: box.file)
    _ = try box.readIndex()
    let event = try #require(try box.store.events(in: box.key).first { $0.kind == .toolResult })
    #expect(event.text?.utf8.count == 2048)
    let registration = try #require(try box.store.registeredToolOutput(in: box.key, eventKey: event.dedupeKey))
    let read = try ToolOutputReader.read(registration, authorizedRoot: box.root)
    #expect(read.text == body && !read.truncated)
    #expect(try Data(contentsOf: box.file) == bytes)
}
