import ADCore
import ADStore
import Foundation
import Testing

@Test("FR-SRC-2: completing setup without indexing survives reopening; existing libraries skip setup")
func firstRunStateSurvivesReopening() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("source-onboarding-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let empty = directory.appendingPathComponent("empty.sqlite")
    let fresh = try AgentStore(databaseURL: empty)
    let source = Source(agent: .codex, label: "Synthetic", rootURL: directory.appendingPathComponent("not-opened"))
    try fresh.upsertSource(source)
    #expect(try fresh.needsSourceOnboarding())
    try fresh.completeSourceOnboarding()
    let reopened = try AgentStore(databaseURL: empty)
    #expect(try !reopened.needsSourceOnboarding())
    #expect(try reopened.sources().count == 1)
    #expect(try reopened.searchIndex(SearchQuery.parse("synthetic"), scope: .init(now: 0, timeZone: .gmt)).matchCount == 0)

    let existing = try AgentStore(databaseURL: directory.appendingPathComponent("existing.sqlite"))
    let id = try existing.upsertSource(source)
    try existing.write([.session(.init(key: .init(agent: .codex, nativeID: "synthetic-session"),
                                      sourceID: id, environment: "Synthetic"))])
    #expect(try !existing.needsSourceOnboarding())
}
