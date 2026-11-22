import ADCore
import ADInsights
import ADPrivacy
import ADPricing
import ADSearch
import ADStore
import AppKit
import SwiftUI

struct SessionListCell: View {
    let session: SessionListItem
    var snippet: [SearchSnippetPart] = []

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            SessionAgentMark(agent: session.id.agent)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    SessionTitle(title: session.title).font(.body.weight(.semibold))
                    Spacer(minLength: 0)
                    if let activity = session.lastActivity {
                        Text(sessionDate(activity), style: .relative)
                            .font(.caption).foregroundStyle(.secondary).fixedSize()
                    }
                }
                if let path = session.path {
                    let project = path.split(separator: "/").last.map(String.init) ?? path
                    Text(verbatim: [project, session.branch].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if !snippet.isEmpty {
                    Text(highlightedSnippet(snippet))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    SessionStatusPill(status: session.status, reason: session.statusReason)
                    if session.archived {
                        Image(systemName: "archivebox")
                            .foregroundStyle(.secondary).accessibilityLabel("Archived")
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

private func highlightedSnippet(_ parts: [SearchSnippetPart]) -> AttributedString {
    var result = AttributedString()
    for part in parts {
        var text = AttributedString(part.text)
        if part.highlighted {
            text.backgroundColor = Color(nsColor: .systemOrange).opacity(0.22)
            text.inlinePresentationIntent = .stronglyEmphasized
        }
        result.append(text)
    }
    return result
}

struct SessionTranscript: View {
    @State private var section = DetailSection.transcript
    @Environment(\.sessionOverviewOptions) private var overviewOptions

    private enum DetailSection: Hashable { case overview, transcript }
    private var showingOverview: Bool { overviewOptions.enabled && section == .overview }

    let session: SessionListItem
    let store: AgentStore
    let search: SessionTranscriptSearch?
    let contextWindowRules: [ModelContextWindow]
    @State private var indexedContext: IndexedSessionContext?
    @State private var usage: IndexedSessionUsage?
    @State private var request: TranscriptPageRequest
    @State private var loading = true
    @State private var failed = false
    @State private var page: TranscriptPage?
    @State private var viewRevision = 0
    @State private var preferredMatchKey: String?
    @State private var match: IndexedSearchMatchPosition?
    @State private var resolvedLookup: MatchLookup?
    @State private var matchLookupFailed = false

    private struct MatchLookup: Equatable, Sendable {
        let search: SessionTranscriptSearch
        let preferredKey: String?
    }

    private var matchLookup: MatchLookup? {
        search.map { .init(search: $0, preferredKey: preferredMatchKey) }
    }

    private var highlightedMatchKey: String? {
        match?.eventKey ?? (resolvedLookup == nil ? search?.firstMatchKey : nil)
    }

    init(session: SessionListItem, store: AgentStore, search: SessionTranscriptSearch? = nil,
         contextWindowRules: [ModelContextWindow] = []) {
        self.session = session
        self.store = store
        self.search = search
        self.contextWindowRules = contextWindowRules
        _request = State(initialValue: search.map { .around($0.firstMatchKey) } ?? .first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    SessionAgentMark(agent: session.id.agent)
                    VStack(alignment: .leading, spacing: 4) {
                        SessionTitle(title: session.title).font(.title3.weight(.semibold))
                        Text(verbatim: [session.id.agent.sessionName, session.path, session.branch, session.environment]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    SessionStatusPill(status: session.status, reason: session.statusReason)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        startFact
                        turnsFact
                        usageFact
                        contextFact
                    }
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                        GridRow { startFact; turnsFact }
                        GridRow { usageFact; contextFact }
                    }
                }
                .font(.caption)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)

            Divider()
            HStack(spacing: 8) {
                if overviewOptions.enabled {
                    Picker("Session Details", selection: $section) {
                        Text("Overview").tag(DetailSection.overview)
                        Text("Transcript").tag(DetailSection.transcript)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityIdentifier("session.details.tabs")
                } else {
                    Text("Transcript").font(.headline)
                }
                Spacer()
                pagingButton("Older Messages", icon: "chevron.up", cursor: page?.older, direction: TranscriptPageRequest.before)
                pagingButton("Newer Messages", icon: "chevron.down", cursor: page?.newer, direction: TranscriptPageRequest.after)
                if let search {
                    Divider().frame(height: 16)
                    matchControls(search)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 9)

            if showingOverview {
                SessionOverview(session: session, store: store)
            } else if failed {
                EmptyPanel(title: "Could not read the transcript", symbol: "exclamationmark.triangle",
                           message: "Select the session again to retry.")
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let page, !page.events.isEmpty {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(page.events, id: \.dedupeKey) { event in
                                let matched = event.dedupeKey == highlightedMatchKey
                                TranscriptEventRow(event: event)
                                    .padding(matched ? 5 : 0)
                                    .background(matched ? Color.accentColor.opacity(0.15) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 6))
                                    .id(event.dedupeKey)
                            }
                        }
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .task(id: viewRevision) {
                        guard case .around(let key) = request else { return }
                        await Task.yield()
                        if !Task.isCancelled { scroll.scrollTo(key, anchor: .top) }
                    }
                }
                .id(viewRevision)
                .accessibilityIdentifier("session.transcript.messages")
            } else {
                EmptyPanel(title: "No transcript yet", symbol: "text.bubble",
                           message: "This indexed session does not have any transcript entries.")
            }
        }
        .task(id: session.id) { await observeContext() }
        .task(id: session.id) { await observeUsage() }
        .accessibilityIdentifier("session.transcript")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: request) { [request] in await observePage(request) }
        .task(id: matchLookup) { [lookup = matchLookup] in
            if let lookup { await resolveMatch(lookup) }
        }
    }

    private var startFact: some View {
        sessionFact("Started") {
            if let time = session.startedAt {
                Text(sessionDate(time), format: .dateTime.month(.abbreviated).day().hour().minute())
            } else { Text(verbatim: "—") }
        }
    }

    private var turnsFact: some View {
        sessionFact("Turns") { Text(verbatim: usage.map { $0.turns.formatted() } ?? "—") }
    }

    private var usageFact: some View {
        sessionFact("Tokens · Cost") {
            if let usage, usage.totals.records > 0 {
                Text(usage.totals.counts.total.formatted())
                    .monospacedDigit().accessibilityIdentifier("session.usage.total")
                    .help(breakdown(usage.totals.counts))
                if usage.totals.hasPricedUsage {
                    let currency = PriceDisplayCurrency.usd.formattedMicroUSD(Decimal(usage.totals.costMicroUSD))
                    Text(usage.totals.unpricedTokens > 0 ? "Partial estimate: \(currency)" : "List-price estimate: \(currency)")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("session.usage.cost")
                        .help(Text("\(usage.totals.unpricedTokens.formatted()) unpriced tokens"))
                    if usage.hasApproximateQuote {
                        Text("Includes approximate quotes").font(.caption2).foregroundStyle(.secondary)
                    }
                } else if usage.totals.unpricedTokens > 0 {
                    Text("Unpriced").foregroundStyle(.secondary)
                } else { Text(verbatim: "—").foregroundStyle(.secondary) }
            } else { Text(verbatim: "—").foregroundStyle(.secondary) }
        }
    }

    private var contextFact: some View {
        sessionFact("Context window") {
            contextReading.accessibilityIdentifier("session.context")
        }
    }

    private func sessionFact<Value: View>(_ label: LocalizedStringResource, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).foregroundStyle(.secondary)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func breakdown(_ counts: TokenCounts) -> Text {
        Text("Fresh: \(counts.inputFresh.formatted()) · Cache read: \(counts.cacheRead.formatted()) · Cache write: \((counts.cacheWrite + counts.cacheWrite1h).formatted()) · Output: \(counts.output.formatted())")
    }

    private func observeUsage() async {
        usage = nil
        do {
            for try await reading in store.sessionUsageUpdates(in: session.id) {
                guard !Task.isCancelled else { return }
                usage = reading
            }
        } catch {
            if !Task.isCancelled { usage = nil }
        }
    }

    @ViewBuilder private var contextReading: some View {
        if let value = SessionContextUsage(input: indexedContext?.input, recordedCapacity: indexedContext?.capacity,
                                           model: indexedContext?.model, rules: contextWindowRules) {
            Text("\(value.input.formatted()) / \(value.capacity.formatted()) tokens · \(value.fraction.formatted(.percent.precision(.fractionLength(1))))")
                .monospacedDigit()
                .lineLimit(1)
                .help(Text(value.source == .recorded ? "Context capacity from the source" : "Context capacity from Settings"))
        } else {
            Text(verbatim: "—").foregroundStyle(.secondary)
        }
    }

    private func observeContext() async {
        indexedContext = nil
        do {
            for try await reading in store.sessionContextUpdates(in: session.id) {
                guard !Task.isCancelled else { return }
                indexedContext = reading
            }
        } catch {
            if !Task.isCancelled { indexedContext = nil }
        }
    }

    private func matchControls(_ search: SessionTranscriptSearch) -> some View {
        let ready = resolvedLookup != nil && resolvedLookup == matchLookup
        return HStack(spacing: 5) {
            Group {
                if matchLookupFailed {
                    Text("Search position unavailable")
                } else if ready && match == nil {
                    Text("No matching messages")
                } else {
                    Text("\(match?.ordinal ?? 1) of \(match?.count ?? search.count) matches")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityIdentifier("transcript.match.position")
            matchButton("Previous Match", icon: "chevron.up", key: ready ? match?.previousKey : nil)
                .keyboardShortcut("g", modifiers: [.command, .shift])
            matchButton("Next Match", icon: "chevron.down", key: ready ? match?.nextKey : nil)
                .keyboardShortcut("g", modifiers: .command)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func matchButton(_ label: LocalizedStringResource, icon: String, key: String?) -> some View {
        Button {
            if let key { preferredMatchKey = key }
        } label: {
            Label { Text(label) } icon: { Image(systemName: icon) }
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(Text(label))
        .help(Text(label))
        .disabled(key == nil)
    }

    private func resolveMatch(_ lookup: MatchLookup) async {
        guard resolvedLookup != lookup else { return }
        matchLookupFailed = false
        let store = store
        let sessionID = session.id
        let work = Task.detached(priority: .userInitiated) {
            try SessionSearch.position(lookup.search.query, in: store, scope: lookup.search.scope,
                                       session: sessionID, around: lookup.preferredKey)
        }
        do {
            let position = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            guard !Task.isCancelled, matchLookup == lookup else { return }
            // Pin the first resolved hit as well as an explicitly selected
            // one. A new earlier hit must not steal the current selection.
            preferredMatchKey = position?.eventKey
            let previous = match
            match = position
            resolvedLookup = matchLookup
            if let position, position.eventKey != previous?.eventKey,
               request != .around(position.eventKey) {
                seek(.around(position.eventKey))
            }
        } catch {
            guard !Task.isCancelled, matchLookup == lookup else { return }
            matchLookupFailed = true
        }
    }

    private func seek(_ target: TranscriptPageRequest) {
        loading = true
        page = nil
        viewRevision += 1
        request = target
    }

    private func pagingButton(_ label: LocalizedStringResource, icon: String, cursor: TranscriptCursor?,
                              direction: @escaping (TranscriptCursor) -> TranscriptPageRequest) -> some View {
        Button {
            guard let cursor else { return }
            seek(direction(cursor))
        } label: {
            Label { Text(label) } icon: { Image(systemName: icon) }
        }
        .labelStyle(.iconOnly)
        .accessibilityLabel(Text(label))
        .help(Text(label))
        .disabled(cursor == nil || loading || showingOverview)
        .opacity(showingOverview ? 0 : 1)
        .accessibilityHidden(showingOverview)
    }

    private func observePage(_ requested: TranscriptPageRequest) async {
        do {
            for try await snapshot in try store.transcriptPageUpdates(in: session.id, request: requested) {
                guard !Task.isCancelled, request == requested else { return }
                if snapshot == nil, case .around = requested {
                    seek(.first)
                    return
                }
                page = snapshot
                loading = false
                failed = false
            }
        } catch {
            guard !Task.isCancelled, request == requested else { return }
            if error as? TranscriptPagingError == .staleCursor, requested != .first {
                seek(.first)
            } else {
                loading = false
                failed = true
            }
        }
    }
}

private struct TranscriptEventRow: View {
    let event: EventRecord

    var body: some View {
        if event.kind == .toolCall || event.kind == .toolResult {
            DisclosureGroup {
                ProtectedTranscriptText(raw: event.text ?? "")
                    .padding(.top, 5)
            } label: {
                Label {
                    if let name = event.toolName {
                        Text(verbatim: SecretMasker.mask(name)).lineLimit(1)
                    } else {
                        Text(event.kind.transcriptLabel)
                    }
                } icon: {
                    Image(systemName: event.kind == .toolCall ? "terminal" : "doc.text")
                }
                .font(.callout)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
        } else {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if event.kind == .assistant {
                        Text(verbatim: event.session.agent.sessionName)
                            .foregroundStyle(event.session.agent.sessionColor)
                    } else {
                        Text(event.kind.transcriptLabel).foregroundStyle(.secondary)
                    }
                    Text(sessionDate(event.timestamp), format: .dateTime.hour().minute()).foregroundStyle(.tertiary)
                }
                .font(.caption.weight(.medium))
                if let text = event.text {
                    ProtectedTranscriptText(raw: text)
                }
            }
        }
    }
}

private struct ProtectedTranscriptText: View {
    let raw: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var revealedText: String?

    var body: some View {
        let masked = SecretMasker.mask(raw)
        let revealed = revealedText == raw
        let displayed = revealed ? raw : masked
        let sections = TranscriptFormatting.sections(displayed)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if section.code {
                    Text(verbatim: section.text).font(.body).monospaced()
                } else {
                    Text(TranscriptFormatting.inline(section.text, maskRenderedText: !revealed))
                }
            }
            if masked != raw {
                Button {
                    revealedText = revealed ? nil : raw
                } label: {
                    if revealed { Text("Hide Credentials") } else { Text("Reveal Credentials Briefly") }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .textSelection(.enabled)
        .onChange(of: raw) { _, _ in revealedText = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { revealedText = nil } }
        .onDisappear { revealedText = nil }
        .task(id: revealed) {
            guard revealed else { return }
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            if !Task.isCancelled { revealedText = nil }
        }
    }
}

private enum TranscriptFormatting {
    struct Section {
        let text: String
        let code: Bool
    }

    static func sections(_ text: String) -> [Section] {
        var sections: [Section] = []
        var lines: [Substring] = []
        var opened: (marker: Character, length: Int)?
        func append(code: Bool) {
            guard !lines.isEmpty else { return }
            sections.append(.init(text: lines.joined(separator: "\n"), code: code))
            lines.removeAll(keepingCapacity: true)
        }
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: { $0 == " " })
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let length = trimmed.prefix(while: { $0 == marker }).count
                let trailing = trimmed.dropFirst(length)
                if let current = opened {
                    if marker == current.marker, length >= current.length, trailing.allSatisfy(\.isWhitespace) {
                        append(code: true)
                        opened = nil
                        continue
                    }
                } else if length >= 3, line.count - trimmed.count <= 3 {
                    append(code: false)
                    opened = (marker, length)
                    continue
                }
            }
            lines.append(line)
        }
        append(code: opened != nil)
        return sections
    }

    static func inline(_ text: String, maskRenderedText: Bool) -> AttributedString {
        var result = (try? AttributedString(markdown: text, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        result.link = nil
        result.imageURL = nil
        if maskRenderedText {
            // Markdown can join runs that had markup inside a credential.
            let visible = String(result.characters)
            let safe = SecretMasker.mask(visible)
            if safe != visible { return AttributedString(safe) }
        }
        return result
    }
}

struct SessionTitle: View {
    let title: String?

    var body: some View {
        Group {
            if let title { Text(verbatim: title) } else { Text("Untitled Session") }
        }
        .lineLimit(1)
    }
}

struct SessionAgentMark: View {
    let agent: AgentKind

    var body: some View {
        Text(verbatim: agent.sessionInitials)
            .font(.caption.weight(.semibold))
            .foregroundStyle(agent.sessionColor)
            .frame(width: 28, height: 28)
            .background(agent.sessionColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(Text(verbatim: agent.sessionName))
    }
}

private struct SessionStatusPill: View {
    let status: SessionStatus
    let reason: String?

    var body: some View {
        Label { Text(label) } icon: { Image(systemName: "circle.fill").imageScale(.small) }
            .font(.caption2.weight(.medium))
            .foregroundStyle(status.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(status.color.opacity(0.12), in: Capsule())
            .fixedSize()
            .help(Text(evidence))
            .accessibilityHint(Text(evidence))
    }

    private var label: LocalizedStringResource {
        switch reason {
        case StatusInferenceReason.possiblyNeedsApproval.rawValue: "Possibly needs approval"
        case StatusInferenceReason.needsApproval.rawValue: "Needs approval"
        default: status.label
        }
    }

    private var evidence: LocalizedStringResource {
        if reason == "archivedSession" { return "The source file was confirmed missing." }
        return switch reason.flatMap(StatusInferenceReason.init(rawValue:)) {
        case .apiError: "The source reported an API error."
        case .turnError: "The source reported a failed turn."
        case .toolResultError: "The latest tool result reported an error."
        case .sessionEnded: "The source recorded a session end."
        case .turnIdleCompleted: "The last turn ended normally and the session is idle."
        case .possiblyNeedsApproval: "Possibly needs approval: a tool call is still unanswered."
        case .needsApproval: "The source explicitly requested approval."
        case .waitingForReply: "The last turn ended; waiting for your reply."
        case .recentActivity: "The source contains recent activity."
        case .toolInFlight: "The source has a tool call without a result yet."
        case .pendingToolExpired: "The last unanswered tool call has expired."
        default: "Status inferred from local file activity."
        }
    }
}

extension SessionStatus {
    var label: LocalizedStringResource {
        switch self {
        case .running: "Running"
        case .waiting: "Waiting"
        case .completed: "Completed"
        case .failed: "Failed"
        case .unknown: "Unknown"
        }
    }

    var color: Color {
        switch self {
        case .running: Color(nsColor: .systemGreen)
        case .waiting: Color(nsColor: .systemOrange)
        case .failed: Color(nsColor: .systemRed)
        case .completed, .unknown: .secondary
        }
    }
}

extension AgentKind {
    var sessionName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .copilot: "Copilot CLI"
        case .grokBuild: "Grok Build"
        }
    }

    var sessionInitials: String {
        switch self {
        case .claudeCode: "CC"
        case .codex: "CX"
        case .copilot: "CP"
        case .grokBuild: "GK"
        }
    }

    var sessionColor: Color {
        switch self {
        case .claudeCode: Color(nsColor: .systemOrange)
        case .codex: Color(nsColor: .systemMint)
        case .copilot: Color(nsColor: .systemPurple)
        case .grokBuild: Color(nsColor: .systemBlue)
        }
    }
}

extension EventKind {
    var transcriptLabel: LocalizedStringResource {
        switch self {
        case .user, .promptHistory: "You"
        case .assistant: "Assistant"
        case .toolCall: "Tool Call"
        case .toolResult: "Tool Result"
        case .summary: "Summary"
        case .system: "System"
        case .error: "Error"
        case .unknown: "Unrecognized Event"
        }
    }
}

func sessionDate(_ epochMilliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(epochMilliseconds) / 1_000)
}
