#if AGENTDASH_SYNTHETIC_ONLY
import ADCore
import ADSearch
import ADStore
import AppKit
import Darwin
import Foundation

struct SyntheticNativeSearch: Sendable {
    static let environmentKey = "AGENTDASH_SYNTHETIC_NATIVE_SEARCH"
    private static let current = try? request()
    static var measuring: Bool { current?.mode == .measure }

    enum Mode: String, Sendable { case install, measure, cleanup }
    let mode: Mode
    let root: URL
    private var index: URL { root.appendingPathComponent("index.sqlite") }
    private var receipt: URL { root.appendingPathComponent("proof.json") }

    private struct Proof: Codable {
        let bytes: Int64
        let events: Int
        let sessions: Int

        var valid: Bool { events == 1_000_000 && sessions == 2_000 && (4_096...1_500_000_000).contains(bytes) }
    }

    static func request() throws -> Self? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard CommandLine.arguments.contains("--synthetic"), parts.count == 2,
              let mode = Mode(rawValue: String(parts[0])), let id = UUID(uuidString: String(parts[1]))
        else { throw StoreError.invalidLocation }
        return .init(mode: mode, root: FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDashboard-native-search-\(id.uuidString)", isDirectory: true))
    }

    static func report(_ value: String) {
        FileHandle.standardOutput.write(Data("synthetic-search: \(value)\n".utf8))
    }

    static func runFixtureCommand() -> Int32 {
        do {
            guard let fixture = try request() else { throw StoreError.invalidLocation }
            switch fixture.mode {
            case .install:
                try fixture.install()
                report("installed 1000000 search events")
            case .cleanup:
                try fixture.verifyPrepared()
                try FileManager.default.removeItem(at: fixture.root)
            case .measure:
                throw StoreError.invalidLocation
            }
            return EXIT_SUCCESS
        } catch {
            report("fixture unavailable")
            return EXIT_FAILURE
        }
    }

    func openMeasurementDirectory() throws -> URL {
        guard mode == .measure else { throw StoreError.invalidLocation }
        try verifyPrepared()
        return root
    }

    private func verifyPrepared() throws {
        let files = FileManager.default
        let folder = try files.attributesOfItem(atPath: root.path)
        let db = try files.attributesOfItem(atPath: index.path)
        let metadata = try files.attributesOfItem(atPath: receipt.path)
        guard folder[.type] as? FileAttributeType == .typeDirectory,
              (folder[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (folder[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              db[.type] as? FileAttributeType == .typeRegular,
              metadata[.type] as? FileAttributeType == .typeRegular,
              let size = (metadata[.size] as? NSNumber)?.intValue, (1...1024).contains(size),
              try JSONDecoder().decode(Proof.self, from: Data(contentsOf: receipt)).valid
        else { throw StoreError.invalidLocation }
    }

    private func install() throws {
        guard let raw = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_SEARCH_PROOF"],
              raw.utf8.count <= 1024 else { throw StoreError.invalidStoredValue }
        let proof = try JSONDecoder().decode(Proof.self, from: Data(raw.utf8))
        guard proof.valid else { throw StoreError.invalidStoredValue }
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? files.removeItem(at: root) } }
        guard files.createFile(atPath: index.path, contents: nil) else { throw StoreError.invalidLocation }
        let output = try FileHandle(forWritingTo: index)
        var written: Int64 = 0
        do {
            defer { try? output.close() }
            while let chunk = try FileHandle.standardInput.read(upToCount: 262_144), !chunk.isEmpty {
                if written == 0 && !chunk.starts(with: Data("SQLite format 3\0".utf8)) {
                    throw StoreError.invalidStoredValue
                }
                written += Int64(chunk.count)
                guard written <= proof.bytes else { throw StoreError.invalidStoredValue }
                try output.write(contentsOf: chunk)
            }
        }
        guard written == proof.bytes else { throw StoreError.invalidStoredValue }
        let store = try AgentStore(databaseURL: index)
        let example = SessionKey(agent: .codex, nativeID: "bench-42")
        guard try store.events(in: example).count == 500 else { throw StoreError.invalidStoredValue }
        try JSONEncoder().encode(proof).write(to: receipt, options: .withoutOverwriting)
        complete = true
    }
}

@MainActor
final class SyntheticNativeSearchRun {
    static let shared = SyntheticNativeSearchRun()

    private enum Action { case query, nextPage, previousPage, commit, seedTail, removeTail }

    private struct Scenario {
        let label: String
        let text: String
        let matches: Int
        let sessions: Int
        var action: Action = .query
        var offset = 0
        var verifiesOnly = false
        var verifiesRanking = false
        var requiresUncachedRead = false
        var expectsNewCount: Bool { action == .commit || action == .removeTail }
    }

    private static let broad = "auth OR middleware"
    private static let tail = "qaonlypagetail"
    private let scenarios = SyntheticNativeSearchRun.makeScenarios()

    private static func makeScenarios() -> [Scenario] {
        let broad = Self.broad
        let directory = Scenario(label: "directory", text: "dir:~/work/bench-42", matches: 500, sessions: 1)
        let requested = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_SEARCH_CYCLES"].flatMap(Int.init)
        let cycles = requested.flatMap { (1...20).contains($0) ? $0 : nil } ?? 20
        let pageSize = DashboardModel.sessionSearchPageSize
        if ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_SEARCH_FOCUS"] == "boundaries" {
            var steps: [Scenario] = [.init(label: "boundary-first", text: broad, matches: 100_000, sessions: 2_000,
                                          verifiesOnly: true, verifiesRanking: true)]
            for page in 2...8 {
                steps.append(.init(label: "forward-\(page)", text: broad, matches: 100_000, sessions: 2_000,
                                   action: .nextPage, offset: (page - 1) * pageSize, verifiesRanking: true,
                                   requiresUncachedRead: !page.isMultiple(of: 2)))
            }
            for page in [7, 6] {
                steps.append(.init(label: "back-\(page)", text: broad, matches: 100_000, sessions: 2_000,
                                   action: .previousPage, offset: (page - 1) * pageSize, verifiesRanking: true,
                                   requiresUncachedRead: page == 6))
            }
            var reset = directory
            reset.verifiesOnly = true
            let timedBroad = Scenario(label: "broad", text: broad, matches: 100_000, sessions: 2_000)
            for _ in 0..<cycles { steps += [reset, timedBroad] }
            steps += [
                .init(label: "tail-query", text: Self.tail, matches: 51, sessions: 51, action: .seedTail,
                      verifiesOnly: true, verifiesRanking: true),
                .init(label: "tail-page", text: Self.tail, matches: 51, sessions: 51, action: .nextPage,
                      offset: pageSize, verifiesOnly: true, verifiesRanking: true),
                .init(label: "tail-reset", text: Self.tail, matches: 50, sessions: 50, action: .removeTail,
                      verifiesOnly: true, verifiesRanking: true),
            ]
            return steps
        }
        let cycle: [Scenario] = [
            .init(label: "mixed", text: "登录 verify", matches: 20_000, sessions: 2_000),
            .init(label: "chinese", text: "登录", matches: 20_000, sessions: 2_000),
            .init(label: "broad", text: broad, matches: 100_000, sessions: 2_000),
            .init(label: "next-page", text: broad, matches: 100_000, sessions: 2_000, action: .nextPage, offset: pageSize),
            directory,
        ]
        var steps = (0..<cycles).flatMap { _ in cycle }
        steps.insert(.init(label: "page-refresh", text: broad, matches: 100_001, sessions: 2_000,
                           action: .commit, offset: pageSize),
                     at: steps.count - 1)
        return steps
    }
    private var warmed = false
    private var completed = 0
    private var waiting = false
    private var started: UInt64 = 0
    private var published: UInt64 = 0
    private var debounceMS = 0.0
    private var queryMS = 0.0
    private var previousPage: Set<SessionKey> = []
    func libraryDidDraw(model: DashboardModel, window: NSWindow) {
        guard !warmed, window.isVisible else { return }
        warmed = true
        guard model.sessions.count == 2_000 else {
            SyntheticNativeSearch.report("library count disagrees with fixture")
            return
        }
        SyntheticNativeSearch.report("ready 2000 sessions")
        schedule(model, window: window)
    }

    private func schedule(_ model: DashboardModel, window: NSWindow) {
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard window.isVisible, completed < scenarios.count else { return }
            let scenario = scenarios[completed]
            waiting = true
            started = DispatchTime.now().uptimeNanoseconds
            published = 0
            switch scenario.action {
            case .query:
                // Same setter used by the toolbar's native search binding.
                model.editSearchText(scenario.text)
            case .nextPage:
                model.pageSessionSearch(forward: true)
            case .previousPage:
                model.pageSessionSearch(forward: false)
            case .commit:
                guard let store = model.store, model.sessionSearchOffset == scenario.offset else {
                    return SyntheticNativeSearch.report("second page not visible before commit")
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        let event = EventRecord(session: .init(agent: .codex, nativeID: "bench-1"),
                                                sequence: 500, timestamp: 1_795_000_000_500, kind: .assistant,
                                                text: "updated middleware cache", dedupeKey: "native-search-refresh")
                        try store.write([.event(event)])
                    }.value
                } catch {
                    SyntheticNativeSearch.report("synthetic search commit failed")
                }
            case .seedTail, .removeTail:
                guard let store = model.store else { return SyntheticNativeSearch.report("missing synthetic store") }
                let removeTail = scenario.action == .removeTail
                let term = scenario.text
                guard !removeTail || (model.sessionSearchOffset == DashboardModel.sessionSearchPageSize &&
                                     model.selectedSessionID?.nativeID == "bench-1") else {
                    return SyntheticNativeSearch.report("synthetic tail not selected before commit")
                }
                do {
                    try await Task.detached(priority: .userInitiated) {
                        // Change only the text of the last session's one matching row.
                        let records = (1...(removeTail ? 1 : 51)).map { id in
                            NormalizedRecord.event(.init(session: .init(agent: .codex, nativeID: "bench-\(id)"),
                                sequence: 500, timestamp: 1_795_000_000_500, kind: .assistant,
                                text: removeTail ? "synthetic nonmatching replacement" : term,
                                dedupeKey: "native-search-tail-\(id)"))
                        }
                        try store.write(records)
                    }.value
                    if !removeTail { model.editSearchText(scenario.text) }
                } catch {
                    SyntheticNativeSearch.report("synthetic tail commit failed")
                }
            }
        }
    }

    func didPublish(text: String, offset: Int, matches: Int, debounce: Double, query: Double) {
        guard waiting, completed < scenarios.count, published == 0 else { return }
        let scenario = scenarios[completed]
        guard scenario.text == text, offset == scenario.offset,
              !scenario.expectsNewCount || matches == scenario.matches else { return }
        debounceMS = debounce
        queryMS = query
        published = DispatchTime.now().uptimeNanoseconds
    }

    // A revalidation can redraw the previous page before the next step starts.
    // Give a marker only to the active result, and distinguish the post-commit count.
    func marker(model: DashboardModel, results: SessionSearchResults) -> String? {
        guard waiting, published > 0, completed < scenarios.count else { return nil }
        let scenario = scenarios[completed]
        guard model.sessionSearchText == scenario.text, model.sessionSearchOffset == scenario.offset,
              !scenario.expectsNewCount || results.matchCount == scenario.matches else { return nil }
        return "synthetic-search result \(completed):\(results.matchCount)"
    }

    func resultsDidDraw(_ marker: String, model: DashboardModel, results: SessionSearchResults, window: NSWindow) {
        guard window.isVisible, self.marker(model: model, results: results) == marker,
              case .results(let current) = model.sessionSearchState, current == results else { return }
        let scenario = scenarios[completed]
        waiting = false
        guard results.matchCount == scenario.matches, results.sessionCount == scenario.sessions,
              results.hits.count == min(scenario.sessions - scenario.offset, DashboardModel.sessionSearchPageSize),
              scenario.label != "directory" || results.hits.first?.id.nativeID == "bench-42"
        else { return SyntheticNativeSearch.report("drawn results disagree with fixture") }
        if scenario.verifiesRanking {
            let end = scenario.sessions - scenario.offset
            // All matching sessions have equal scores and timestamps. The fixture
            // creates them in ascending ID order, so tied results descend by ID.
            let top = end + (scenario.action == .removeTail ? 1 : 0)
            let expected = (0..<results.hits.count).map {
                SessionKey(agent: .codex, nativeID: "bench-\(top - $0)")
            }
            guard results.hits.map(\.id) == expected, model.selectedSessionID == expected.first else {
                return SyntheticNativeSearch.report("ranking or selected session disagrees at \(scenario.label)")
            }
        }
        if scenario.requiresUncachedRead, queryMS == 0 {
            return SyntheticNativeSearch.report("expected an uncached read at \(scenario.label)")
        }
        if scenario.label == "broad" { previousPage = Set(results.hits.map(\.id)) }
        if scenario.action == .nextPage, !previousPage.isDisjoint(with: results.hits.map(\.id)) {
            return SyntheticNativeSearch.report("result pages overlap")
        }
        window.displayIfNeeded()
        let finished = DispatchTime.now().uptimeNanoseconds
        let total = Double(finished - started) / 1_000_000
        let render = Double(finished - published) / 1_000_000
        // Exclude only the prescribed delay, not any scheduler oversleep.
        if scenario.action == .commit {
            SyntheticNativeSearch.report("refreshed offset \(scenario.offset) matches \(results.matchCount)")
        } else if scenario.verifiesOnly {
            SyntheticNativeSearch.report("verified \(scenario.label) offset \(scenario.offset) matches \(results.matchCount)")
        } else {
            let adjusted = max(0, total - (scenario.action == .query ? 150 : 0))
            SyntheticNativeSearch.report(String(format: "drawn %@ total %.1f ms, adjusted %.1f ms, debounce %.1f ms, query %.1f ms, draw %.1f ms",
                scenario.label, total, adjusted, debounceMS, queryMS, render))
        }
        completed += 1
        if completed == scenarios.count {
            SyntheticNativeSearch.report("done")
        } else {
            schedule(model, window: window)
        }
    }
}
#endif
