#if AGENTDASH_SYNTHETIC_ONLY
import ADCore
import ADStore
import AppKit
import Darwin
import Foundation
import QuartzCore
import SwiftUI

struct SyntheticLongTranscript: Sendable {
    static let environmentKey = "AGENTDASH_SYNTHETIC_LONG_TRANSCRIPT"
    private static let current = try? request()
    static var measuring: Bool { current?.mode == .measure }
    static let warm = SessionKey(agent: .codex, nativeID: "synthetic-transcript-warm")
    static let target = SessionKey(agent: .codex, nativeID: "synthetic-transcript-long")
    private static let receiptBytes = Data("50000 messages\n".utf8)

    enum Mode: String, Sendable { case prepare, measure, cleanup }
    let mode: Mode
    let root: URL
    private var index: URL { root.appendingPathComponent("index.sqlite") }
    private var receipt: URL { root.appendingPathComponent("verified-message-count") }

    static func request() throws -> Self? {
        guard let raw = ProcessInfo.processInfo.environment[environmentKey] else { return nil }
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard CommandLine.arguments.contains("--synthetic"), parts.count == 2,
              let mode = Mode(rawValue: String(parts[0])), let id = UUID(uuidString: String(parts[1]))
        else { throw StoreError.invalidLocation }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDashboard-long-transcript-\(id.uuidString)", isDirectory: true)
        return .init(mode: mode, root: root)
    }

    static func report(_ text: String) {
        FileHandle.standardOutput.write(Data("synthetic-long-transcript: \(text)\n".utf8))
    }

    static func runFixtureCommand() -> Int32 {
        do {
            guard let fixture = try request() else { throw StoreError.invalidLocation }
            switch fixture.mode {
            case .prepare:
                try fixture.prepare()
                report("prepared 50000 messages")
            case .cleanup:
                try fixture.verifyPrepared()
                try FileManager.default.removeItem(at: fixture.root)
            case .measure: throw StoreError.invalidLocation
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
        let directory = try files.attributesOfItem(atPath: root.path)
        let database = try files.attributesOfItem(atPath: index.path)
        let proof = try files.attributesOfItem(atPath: receipt.path)
        guard directory[.type] as? FileAttributeType == .typeDirectory,
              (directory[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (directory[.posixPermissions] as? NSNumber)?.intValue == 0o700,
              database[.type] as? FileAttributeType == .typeRegular,
              proof[.type] as? FileAttributeType == .typeRegular,
              (proof[.size] as? NSNumber)?.intValue == Self.receiptBytes.count,
              try Data(contentsOf: receipt) == Self.receiptBytes else { throw StoreError.invalidLocation }
    }

    private func prepare() throws {
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var complete = false
        defer { if !complete { try? files.removeItem(at: root) } }
        let store = try AgentStore(databaseURL: index)
        let source = try store.upsertSource(.init(agent: .codex, label: "Synthetic transcript",
            rootURL: root.appendingPathComponent("unused-source"), environment: "Synthetic"))
        let base = Int64(Date().timeIntervalSince1970 * 1000) - 86_400_000
        try store.write([
            .session(.init(key: Self.warm, sourceID: source, environment: "Synthetic", title: "Synthetic warm session",
                           startedAt: base, lastEventAt: base, status: .completed)),
            .event(.init(session: Self.warm, sequence: 0, timestamp: base, kind: .user,
                         text: "Synthetic warm transcript", dedupeKey: "synthetic-long:warm")),
            .session(.init(key: Self.target, sourceID: source, environment: "Synthetic", title: "Synthetic 50,000 messages",
                           startedAt: base - 120_000, lastEventAt: base - 70_001, status: .completed)),
        ])
        let decoder = JSONDecoder()
        for offset in stride(from: 0, to: 50_000, by: 1_000) {
            guard let line = readLine(), line.utf8.count <= 1_048_576 else { throw StoreError.invalidStoredValue }
            let texts = try decoder.decode([String].self, from: Data(line.utf8))
            guard texts.count == 1_000, texts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 })
            else { throw StoreError.invalidStoredValue }
            let records = texts.enumerated().map { index, text -> NormalizedRecord in
                let sequence = Int64(offset + index)
                return .event(.init(session: Self.target, sequence: sequence, timestamp: base - 120_000 + sequence,
                                    kind: sequence.isMultiple(of: 2) ? .user : .assistant,
                                    text: text, dedupeKey: "synthetic-long:\(sequence)"))
            }
            try store.write(records)
        }
        guard readLine() == nil, try store.events(in: Self.target).count == 50_000,
              try store.transcriptPage(in: Self.target, request: .last)?.events.last?.sequence == 49_999
        else { throw StoreError.invalidStoredValue }
        try Self.receiptBytes.write(to: receipt, options: .withoutOverwriting)
        complete = true
    }

    static func watches(_ session: SessionKey, sequence: Int64) -> Bool {
        (session == warm && sequence == 0) || (session == target && sequence < 256 && sequence.isMultiple(of: 8))
    }
}

private struct SyntheticLongSelectionKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var syntheticLongTranscriptSelection: (@MainActor () -> Void)? {
        get { self[SyntheticLongSelectionKey.self] }
        set { self[SyntheticLongSelectionKey.self] = newValue }
    }
}

/// Reports actual row paint only when the row intersects the native scroll viewport.
struct SyntheticTranscriptRowProbe: NSViewRepresentable {
    let sequence: Int64
    let painted: @MainActor (NSWindow, NSScrollView) -> Void

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {
        if view.sequence != sequence {
            view.sequence = sequence
            view.reported = false
            view.needsDisplay = true
        }
        view.painted = painted
    }

    final class Marker: NSView {
        var sequence: Int64?
        var reported = false
        var painted: (@MainActor (NSWindow, NSScrollView) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard !reported, !dirtyRect.isEmpty, let window, window.isVisible,
                  let scroll = enclosingScrollView, let painted,
                  scroll.contentView.bounds.intersects(convert(bounds, to: scroll.contentView)) else { return }
            reported = true
            DispatchQueue.main.async { painted(window, scroll) }
        }
    }
}

@MainActor
final class SyntheticTranscriptRun: NSObject {
    static let shared = SyntheticTranscriptRun()
    private enum Stage { case warming, selecting, opening, settling, scrolling, paging, done }
    private var stage = Stage.warming
    private var began: CFTimeInterval = 0
    private var scrollBegan: CFTimeInterval?
    private var previousTick: CFTimeInterval?
    private var moved = 0
    private var missed = 0
    private var late = 0
    private var frameWork: [Double] = []
    private var visibleRows = Set<Int64>()
    private var maximumTravel: CGFloat = 0
    private var direction: CGFloat = 1
    private var link: CADisplayLink?
    private weak var window: NSWindow?
    private weak var scroll: NSScrollView?
    private var nextPage: (@MainActor () -> Void)?

    func didDraw(session: SessionKey, sequence: Int64, page: TranscriptPage, window: NSWindow, scroll: NSScrollView,
                 select: (@MainActor () -> Void)?, seek: @escaping @MainActor (TranscriptPageRequest) -> Void) {
        switch stage {
        case .warming where session == SyntheticLongTranscript.warm && sequence == 0:
            guard let select else { return fail("selection unavailable") }
            stage = .selecting
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard stage == .selecting, window.isVisible else { return fail("warm window disappeared") }
                stage = .opening
                began = CACurrentMediaTime()
                select()
            }
        case .opening where session == SyntheticLongTranscript.target && sequence == 0:
            guard page.events.count == 128, page.events.first?.sequence == 0,
                  page.events.last?.sequence == 127, page.older == nil, let newer = page.newer
            else { return fail("first page incorrect") }
            stage = .settling
            window.displayIfNeeded()
            let duration = (CACurrentMediaTime() - began) * 1_000
            SyntheticLongTranscript.report(String(format: "first-screen %.1f ms, 128 rows", duration))
            self.window = window
            self.scroll = scroll
            nextPage = { seek(.after(newer)) }
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                startScroll()
            }
        case .scrolling where session == SyntheticLongTranscript.target && page.events.first?.sequence == 0:
            visibleRows.insert(sequence)
        case .paging where session == SyntheticLongTranscript.target && sequence == 128:
            guard page.events.count == 128, page.events.first?.sequence == 128, page.events.last?.sequence == 255,
                  page.older != nil, page.newer != nil else { return fail("next page incorrect") }
            stage = .done
            window.displayIfNeeded()
            SyntheticLongTranscript.report(String(format: "next-screen %.1f ms, 128 rows",
                                                   (CACurrentMediaTime() - began) * 1_000))
        default: break
        }
    }

    private func startScroll() {
        guard stage == .settling, let window, window.isVisible, scroll != nil else {
            return fail("scroll view unavailable")
        }
        stage = .scrolling
        let link = window.displayLink(target: self, selector: #selector(frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        self.link = link
        link.add(to: .main, forMode: .common)
    }

    @objc private func frame(_ link: CADisplayLink) {
        guard stage == .scrolling, let window, window.isVisible, let scroll, let document = scroll.documentView else {
            return fail("scroll view disappeared")
        }
        let started = CACurrentMediaTime()
        let interval = link.targetTimestamp - link.timestamp
        guard interval > 0 else { return }
        if scrollBegan == nil { scrollBegan = started }
        let elapsed = started - (scrollBegan ?? started)
        if elapsed >= 4 { return finishScroll(elapsed: elapsed) }
        if let previousTick, started - previousTick > interval * 1.5 { missed += 1 }
        previousTick = started

        let clip = scroll.contentView
        let original = clip.bounds.origin
        let minimum = document.frame.minY
        let maximum = max(minimum, document.frame.maxY - clip.bounds.height)
        let step = CGFloat(interval * 1_450)
        if original.y + step * direction > maximum { direction = -1 }
        if original.y + step * direction < minimum { direction = 1 }
        let y = min(maximum, max(minimum, original.y + step * direction))
        clip.scroll(to: NSPoint(x: original.x, y: y))
        scroll.reflectScrolledClipView(clip)
        window.displayIfNeeded()
        CATransaction.flush()
        let travel = abs(clip.bounds.origin.y - original.y)
        if travel > 0.5 { moved += 1; maximumTravel += travel }
        let completed = CACurrentMediaTime()
        frameWork.append((completed - started) * 1_000)
        if completed > link.targetTimestamp { late += 1 }
    }

    private func finishScroll(elapsed: Double) {
        link?.invalidate()
        link = nil
        guard visibleRows.count >= 4, let nextPage, moved > 0 else { return fail("scroll did not draw enough new rows") }
        let timings = frameWork.sorted()
        let p95 = timings[max(0, Int(ceil(Double(timings.count) * 0.95)) - 1)]
        SyntheticLongTranscript.report(String(format: "scroll %.2f updates/s, %d moves, %d drawn probes, %.0f pt, %.2f ms P95, %d gaps, %d late",
            Double(moved) / elapsed, moved, visibleRows.count, maximumTravel, p95, missed, late))
        stage = .paging
        self.nextPage = nil
        DispatchQueue.main.async {
            self.began = CACurrentMediaTime()
            nextPage()
        }
    }

    private func fail(_ reason: String) {
        link?.invalidate()
        link = nil
        stage = .done
        SyntheticLongTranscript.report(reason)
    }
}
#endif
