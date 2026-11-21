import ADAdapters
import ADCore
import ADIngest
import ADStore
import Foundation
import Testing

@Test("SPEC §11.3: Claude history stays searchable without counting or opening it as a project session",
      .timeLimit(.minutes(1)))
func projectsIgnorePromptHistoryBuckets() async throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("project-history-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: home) }
    let root = home.appendingPathComponent(".claude")
    let folder = root.appendingPathComponent("projects/demo")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let nativeID = "00000000-0000-0000-0000-000000000075"
    let workspace = "/synthetic/work/review"
    try Data((#"{"type":"user","uuid":"real-project-session","cwd":"/synthetic/work/review","timestamp":1000,"message":{"content":"Recorded transcript"}}"#
        + "\n").utf8).write(to: folder.appendingPathComponent(nativeID + ".jsonl"))
    try Data((#"{"display":"freshprompt synthetic","project":"/synthetic/work/review","timestamp":2000}"#
        + "\n").utf8).write(to: root.appendingPathComponent("history.jsonl"))
    let store = try AgentStore(databaseURL: home.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
    source.id = try store.upsertSource(source)
    let adapter = ClaudeCodeAdapter()
    let files = try adapter.discover(in: source, authorizedRoot: root)
    #expect(files.contains { $0.role == .promptHistory })
    for file in files {
        try JSONLFileImporter.importFile(file, from: source, authorizedRoot: root, store: store, adapter: adapter)
    }

    var groups = store.indexedProjectUpdates(hostHome: home.path).makeAsyncIterator()
    let projects = try #require(try await groups.next())
    let project = try #require(projects.first)
    let genuine = SessionKey(agent: .claudeCode, nativeID: nativeID)
    #expect(projects.count == 1 && project.path == workspace)
    #expect(project.sessions.map(\.session.id) == [genuine])
    #expect(project.sessions.first?.session.lastActivity == 1000)
    var timeline = try store.indexedProjectActivityUpdates(project.activityScope).makeAsyncIterator()
    let events = try #require(try await timeline.next())
    #expect(events.map(\.session) == [genuine])

    let sourceID = try #require(source.id)
    let scope = IndexedSearchScope(now: 3000, timeZone: .current)
    let results = try store.searchIndex(SearchQuery.parse("freshprompt role:user"), scope: scope)
    #expect(results.matchCount == 1)
    #expect(results.groups.map(\.session.nativeID) == ["history:\(sourceID):\(workspace)"])
}
