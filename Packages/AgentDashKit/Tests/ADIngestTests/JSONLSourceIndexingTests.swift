import ADAdapters
import ADCore
import ADIngest
import ADStore
import Foundation
import Testing

private enum SourceIndexTestFailure: Error { case noCompletedScan }

@Test("FR-SR: a Copilot workspace title updates without transcript replay and never overrides a user title",
      .timeLimit(.minutes(1)))
func copilotWorkspaceRenameWithoutEventReplay() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("copilot-title-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let root = temp.appendingPathComponent("synthetic-source")
    let recognized = root.appendingPathComponent("session-state/local-session")
    let metadataOnly = root.appendingPathComponent("session-state/metadata-only")
    try FileManager.default.createDirectory(at: recognized, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: metadataOnly, withIntermediateDirectories: true)
    let streamFile = recognized.appendingPathComponent("events.jsonl")
    let payload = Data(("""
        {"type":"session.start","id":"start","data":{"sessionId":"local-session"}}
        {"type":"user.message","id":"prompt","data":{"content":"Synthetic first prompt"}}
        """ + "\n").utf8)
    try payload.write(to: streamFile)
    let sidecar = recognized.appendingPathComponent("workspace.yaml")
    try Data("name: |-\n  Native title\n  continuation\n".utf8).write(to: sidecar)
    try Data("name: No event file here\n".utf8).write(to: metadataOnly.appendingPathComponent("workspace.yaml"))

    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    var entry = Source(agent: .copilot, label: "Synthetic", rootURL: root)
    entry.id = try store.upsertSource(entry)
    let source = entry
    let key = SessionKey(agent: .copilot, nativeID: "local-session")
    let updates = AsyncStream<SourceIndexUpdate>.makeStream(bufferingPolicy: .bufferingNewest(12))
    let worker = Task {
        defer { updates.continuation.finish() }
        try await JSONLSourceIndexing.run(source: source, authorizedRoot: root, adapter: CopilotAdapter(), store: store) {
            updates.continuation.yield($0)
        }
    }
    defer { worker.cancel() }
    func sessions() async throws -> [IndexedSession] {
        var iterator = store.indexedSessionUpdates().makeAsyncIterator()
        return try #require(try await iterator.next())
    }
    let initial = try await watchCompletedScan(updates.stream) { $0.bytesRead > 0 }
    #expect(initial.totalFiles == 1 && initial.failedFiles == 0)
    let first = try await sessions()
    #expect(first.count == 1 && first.first?.title == "Native title continuation" && first.first?.titleSource == .agent)
    let events = try store.events(in: key)

    try await store.setCustomSessionTitle("User override", for: key)
    try Data("name: 'Changed ''native'' title'\n".utf8).write(to: sidecar, options: .atomic)
    let updated = try await watchCompletedScan(updates.stream) { $0.bytesRead == 0 && $0.checkedFiles == 1 }
    #expect(updated.failedFiles == 0)
    let overridden = try await sessions()
    #expect(overridden.first?.title == "User override" && overridden.first?.titleSource == .user)
    try await store.setCustomSessionTitle(nil, for: key)
    let restored = try await sessions()
    #expect(restored.first?.title == "Changed 'native' title" && restored.first?.titleSource == .agent)
    #expect(try store.events(in: key) == events)
    #expect(try Data(contentsOf: streamFile) == payload)
    worker.cancel()
    do { try await worker.value } catch is CancellationError {}
}

@Test("FR-SRC-2: a native source session imports only after start and observes appends and newly discovered files",
      .timeLimit(.minutes(1)))
func selectedSourceIndexesAndWatchesUntilCancelled() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("source-watch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let root = temp.appendingPathComponent("synthetic-source")
    let project = root.appendingPathComponent("projects/synthetic")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let first = "00000000-0000-0000-0000-000000000051"
    let second = "00000000-0000-0000-0000-000000000052"
    let firstFile = project.appendingPathComponent(first + ".jsonl")
    let firstLine = #"{"type":"user","uuid":"synthetic-start","message":{"content":"Initial synthetic entry"}}"#
    try Data((firstLine + "\n").utf8).write(to: firstFile)
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    let registered = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
    var source = registered
    source.id = try store.upsertSource(registered)
    let selected = source
    let key = SessionKey(agent: .claudeCode, nativeID: first)
    #expect(try store.events(in: key).isEmpty)

    let updates = AsyncStream<SourceIndexUpdate>.makeStream(bufferingPolicy: .bufferingNewest(12))
    let worker = Task {
        defer { updates.continuation.finish() }
        try await JSONLSourceIndexing.run(source: selected, authorizedRoot: root, adapter: ClaudeCodeAdapter(), store: store) {
            updates.continuation.yield($0)
        }
    }
    defer { worker.cancel() }
    let initial = try await watchCompletedScan(updates.stream) { $0.checkedFiles == 1 && $0.bytesRead > 0 }
    #expect(initial.failedFiles == 0)
    #expect(try store.events(in: key).count == 1)

    let append = #"{"type":"assistant","uuid":"synthetic-append","message":{"content":[{"type":"text","text":"Appended synthetic entry"}]}}"#
    let delta = Data((append + "\n").utf8)
    let now = ContinuousClock.now
    try appendData(delta, to: firstFile)
    let changed = try await watchCompletedScan(updates.stream) { $0.bytesRead == Int64(delta.count) }
    #expect(changed.failedFiles == 0)
    #expect(try store.events(in: key).map(\.text) == ["Initial synthetic entry", "Appended synthetic entry"])
    print("Synthetic registered-source append to index: \(now.duration(to: .now))")

    let newLine = #"{"type":"user","uuid":"synthetic-new-file","message":{"content":"Discovered synthetic file"}}"#
    let secondFile = project.appendingPathComponent(second + ".jsonl")
    try Data((newLine + "\n").utf8).write(to: secondFile)
    let discovered = try await watchCompletedScan(updates.stream) { $0.totalFiles == 2 }
    #expect(discovered.failedFiles == 0)
    #expect(try store.events(in: .init(agent: .claudeCode, nativeID: second)).count == 1)

    worker.cancel()
    do {
        try await worker.value
        Issue.record("The cancelled source worker must end with cancellation.")
    } catch is CancellationError {}
    let stopped = #"{"type":"user","uuid":"synthetic-stop","message":{"content":"Not indexed after stop"}}"#
    let stoppedBytes = Data((stopped + "\n").utf8)
    try appendData(stoppedBytes, to: firstFile)
    #expect(try store.events(in: key).count == 2)

    let restart = AsyncStream<SourceIndexUpdate>.makeStream(bufferingPolicy: .bufferingNewest(12))
    let resumedWorker = Task {
        defer { restart.continuation.finish() }
        try await JSONLSourceIndexing.run(source: selected, authorizedRoot: root, adapter: ClaudeCodeAdapter(), store: store) {
            restart.continuation.yield($0)
        }
    }
    defer { resumedWorker.cancel() }
    let resumed = try await watchCompletedScan(restart.stream) { $0.checkedFiles == 2 }
    #expect(resumed.failedFiles == 0 && resumed.bytesRead == Int64(stoppedBytes.count))
    #expect(try store.events(in: key).map(\.text) == [
        "Initial synthetic entry", "Appended synthetic entry", "Not indexed after stop",
    ])
    #expect(try Data(contentsOf: firstFile) == Data((firstLine + "\n").utf8) + delta + stoppedBytes)
    resumedWorker.cancel()
    do {
        try await resumedWorker.value
        Issue.record("The resumed source worker must end with cancellation.")
    } catch is CancellationError {}
}

@Test("SEC-3: a running source stops on replacement without indexing the new root",
      .timeLimit(.minutes(1)))
func watchingSourceDoesNotIndexAReplacementRoot() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("watch-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let root = temp.appendingPathComponent("source")
    let project = root.appendingPathComponent("projects/demo")
    let initialID = "00000000-0000-0000-0000-000000000053"
    let replacementID = "00000000-0000-0000-0000-000000000054"
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let initialLine = #"{"type":"user","uuid":"original-root","message":{"content":"Registered source record"}}"#
    try Data((initialLine + "\n").utf8).write(to: project.appendingPathComponent(initialID + ".jsonl"))
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
    source.id = try store.upsertSource(source)
    let selected = source
    let updates = AsyncStream<SourceIndexUpdate>.makeStream(bufferingPolicy: .bufferingNewest(12))
    let exits = AsyncStream<SourceIndexFailure?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    let worker = Task {
        defer {
            updates.continuation.finish()
            exits.continuation.finish()
        }
        do {
            try await JSONLSourceIndexing.run(source: selected, authorizedRoot: root, adapter: ClaudeCodeAdapter(),
                                             store: store) { updates.continuation.yield($0) }
            exits.continuation.yield(nil)
        } catch {
            exits.continuation.yield(error as? SourceIndexFailure)
        }
    }
    defer { worker.cancel() }
    let scan = try await watchCompletedScan(updates.stream) { $0.checkedFiles == 1 }
    #expect(scan.failedFiles == 0)
    try FileManager.default.moveItem(at: root, to: temp.appendingPathComponent("displaced"))
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let replacement = #"{"type":"user","uuid":"replacement-root","message":{"content":"Must remain outside the index"}}"#
    try Data((replacement + "\n").utf8).write(to: project.appendingPathComponent(replacementID + ".jsonl"))

    let outcome = try await withThrowingTaskGroup(of: SourceIndexFailure?.self) { group in
        group.addTask {
            var results = exits.stream.makeAsyncIterator()
            return await results.next() ?? nil
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw SourceIndexTestFailure.noCompletedScan
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw SourceIndexTestFailure.noCompletedScan }
        return result
    }
    #expect(outcome == .rootChanged)
    #expect(try store.events(in: .init(agent: .claudeCode, nativeID: replacementID)).isEmpty)
    #expect(try store.events(in: .init(agent: .claudeCode, nativeID: initialID)).count == 1)
}

@Test("FR-STO-1: source deletion and index rebuild retain data, and replay restores the same session",
      .timeLimit(.minutes(1)))
func nativeSourceArchiveRetainsTranscriptSearchAndUsage() async throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("source-archive-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let root = temp.appendingPathComponent("source")
    let project = root.appendingPathComponent("projects/demo")
    let heldProject = temp.appendingPathComponent("held-project")
    let heldFile = temp.appendingPathComponent("held.jsonl")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    let key = SessionKey(agent: .claudeCode, nativeID: "00000000-0000-0000-0000-000000000071")
    let name = key.nativeID + ".jsonl"
    let file = project.appendingPathComponent(name)
    let time = Int64(Date().timeIntervalSince1970 * 1000) - 1000
    let lines = [
        #"{"type":"user","uuid":"archive-user","timestamp":\#(time),"message":{"content":"synthetic archive orbital"}}"#,
        #"{"type":"assistant","uuid":"archive-assistant","timestamp":\#(time),"message":{"id":"archive-response","content":"synthetic reply","usage":{"input_tokens":7,"output_tokens":3}}}"#,
    ]
    let bytes = Data((lines.joined(separator: "\n") + "\n").utf8)
    try bytes.write(to: file)
    let store = try AgentStore(databaseURL: temp.appendingPathComponent("index.sqlite"))
    var source = Source(agent: .claudeCode, label: "Synthetic", rootURL: root)
    let sourceID = try store.upsertSource(source)
    source.id = sourceID
    let selected = source
    let adapter = ClaudeCodeAdapter()
    let updates = AsyncStream<SourceIndexUpdate>.makeStream(bufferingPolicy: .bufferingNewest(20))
    let rescans = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    defer { rescans.continuation.finish() }
    let worker = Task {
        defer { updates.continuation.finish() }
        try await JSONLSourceIndexing.run(source: selected, authorizedRoot: root, adapter: adapter, store: store,
                                         rescans: rescans.stream) {
            updates.continuation.yield($0)
        }
    }
    defer { worker.cancel() }
    let initial = try await watchCompletedScan(updates.stream) { $0.totalFiles == 1 && $0.bytesRead > 0 }
    #expect(initial.failedFiles == 0)
    let original = try #require(try store.sourceArchiveCandidate(sourceID: sourceID, relativePath: "projects/demo/" + name))
    let opening = try #require(try store.transcriptPage(in: key))
    let scope = IndexedSearchScope(now: time + 1000, timeZone: .gmt)
    let query = try SearchQuery.parse("orbital")
    let window = try UsageWindow.make(.hour, now: scope.now, timeZone: .gmt)
    #expect(try store.usage(window: window).totals.counts.total == 10)

    // The active watcher handles the forced replay itself. Without an
    // explicit request the unchanged file's resume point would read no bytes.
    rescans.continuation.yield(())
    let replayed = try await watchCompletedScan(updates.stream) { $0.bytesRead == Int64(bytes.count) }
    #expect(replayed.failedFiles == 0)
    #expect(try store.transcriptPage(in: key) == opening)
    #expect(try store.usage(window: window).totals.counts.total == 10)

    // An unavailable parent is not evidence that the leaf was deleted.
    try FileManager.default.moveItem(at: project, to: heldProject)
    _ = try await watchCompletedScan(updates.stream) { $0.totalFiles == 0 }
    #expect(try store.checkpoint(for: original.id)?.sourceFileWasMissing == false)
    try FileManager.default.moveItem(at: heldProject, to: project)
    _ = try await watchCompletedScan(updates.stream) { $0.totalFiles == 1 }

    // A dangling entry is still present and must not count as disappearance.
    worker.cancel()
    do { try await worker.value } catch is CancellationError {}
    try FileManager.default.moveItem(at: file, to: heldFile)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: temp.appendingPathComponent("absent"))
    let later = AsyncStream<SourceIndexUpdate>.makeStream(bufferingPolicy: .bufferingNewest(20))
    let resumed = Task {
        defer { later.continuation.finish() }
        try await JSONLSourceIndexing.run(source: selected, authorizedRoot: root, adapter: adapter, store: store) {
            later.continuation.yield($0)
        }
    }
    defer { resumed.cancel() }
    _ = try await watchCompletedScan(later.stream) { $0.totalFiles == 0 }
    #expect(try store.checkpoint(for: original.id)?.sourceFileWasMissing == false)

    // Change a synthetic fixture, never an agent's source directory.
    try FileManager.default.removeItem(at: file)
    _ = try await watchCompletedScan(later.stream) { $0.bytesRead == 0 }
    let gone = try #require(try store.checkpoint(for: original.id))
    #expect(gone.sourceFileWasMissing && gone.offset == Int64(bytes.count))
    var sessions = store.indexedSessionUpdates().makeAsyncIterator()
    #expect(try await sessions.next()?.first(where: { $0.id == key })?.archived == true)
    var sources = store.indexedSourceStatusUpdates().makeAsyncIterator()
    let status = try #require(try await sources.next()?.first)
    #expect(status.goneFiles == 1 && status.archivedSessions == 1)
    #expect(try store.searchIndex(query, scope: scope).groups.map(\.session) == [key])
    #expect(try store.transcriptPage(in: key) == opening)
    #expect(try store.usage(window: window).totals.counts.total == 10)

    // A complete pass while the source stays absent preserves the archive.
    resumed.cancel()
    do { try await resumed.value } catch is CancellationError {}
    try await JSONLSourceIndexing.run(source: selected, authorizedRoot: root, adapter: adapter, store: store,
                                     mode: .fullRescan) { _ in }
    #expect(try store.checkpoint(for: original.id) == gone)
    #expect(try store.transcriptPage(in: key) == opening)

    // Rebuild from the app's retained records while the original file is absent.
    let rebuilt = try store.rebuildIndex(scoring: .init(counts: { _ in [:] }, top: { _, _, _ in [] }))
    #expect(rebuilt.indexedEvents == opening.events.count)
    #expect(try store.checkpoint(for: original.id) == gone)
    #expect(try store.searchIndex(query, scope: scope).groups.map(\.session) == [key])
    #expect(try store.transcriptPage(in: key) == opening)
    #expect(try store.usage(window: window).totals.counts.total == 10)

    // Same inode and bytes force a replay; the archive marker must clear
    // without introducing a second transcript, search hit or token event.
    try FileManager.default.moveItem(at: heldFile, to: file)
    try await JSONLSourceIndexing.run(source: selected, authorizedRoot: root, adapter: adapter, store: store,
                                     mode: .fullRescan) { _ in }
    #expect(try store.checkpoint(for: original.id)?.sourceFileWasMissing == false)
    #expect(try await sessions.next()?.first(where: { $0.id == key })?.archived == false)
    #expect(try store.searchIndex(query, scope: scope).matchCount == 1)
    #expect(try store.transcriptPage(in: key) == opening)
    #expect(try store.usage(window: window).totals.counts.total == 10)
    #expect(try Data(contentsOf: file) == bytes)
}

@Test("SEC-3: reader can reject a replacement of the authorized directory before opening its files")
func indexingRootCannotBeSwitchedToAReplacement() throws {
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("index-root-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temp) }
    let root = temp.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("old".utf8).write(to: root.appendingPathComponent("records.jsonl"))
    let expected = try SourceFileReader.directoryIdentity(root: root)
    try FileManager.default.moveItem(at: root, to: temp.appendingPathComponent("displaced"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try Data("replacement".utf8).write(to: root.appendingPathComponent("records.jsonl"))
    #expect(throws: SourceFileReader.Failure.rootChanged) {
        try SourceFileReader(root: root, relativePath: "records.jsonl", expectedRoot: expected)
    }
}

private func watchCompletedScan(_ stream: AsyncStream<SourceIndexUpdate>,
                                matching: @escaping @Sendable (SourceIndexScan) -> Bool) async throws -> SourceIndexScan {
    try await withThrowingTaskGroup(of: SourceIndexScan.self) { group in
        group.addTask {
            for await update in stream {
                if case .watching(let scan) = update, matching(scan) { return scan }
            }
            throw SourceIndexTestFailure.noCompletedScan
        }
        group.addTask {
            try await Task.sleep(for: .seconds(5))
            throw SourceIndexTestFailure.noCompletedScan
        }
        defer { group.cancelAll() }
        guard let scan = try await group.next() else { throw SourceIndexTestFailure.noCompletedScan }
        return scan
    }
}

private func appendData(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}
