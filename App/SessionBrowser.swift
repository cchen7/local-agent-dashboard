import ADCore
import ADInsights
import ADIngest
import ADPrivacy
import ADPricing
import ADSearch
import ADStore
import AppKit
import SwiftUI

struct SessionListCell: View {
    let session: SessionListItem
    var snippet: [SearchSnippetPart] = []
    var projectName: String? = nil
    var currency: PriceDisplayCurrency = .usd

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
                if let project = projectName ?? session.path.map({ $0.split(separator: "/").last.map(String.init) ?? $0 }) {
                    Text(verbatim: [project, session.branch].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if !snippet.isEmpty {
                    Text(highlightedSnippet(snippet))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let usage = session.usage {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            status.fixedSize()
                            Spacer(minLength: 4)
                            usageLabel(usage).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            status
                            usageLabel(usage)
                        }
                    }
                } else { status }
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    private var status: some View {
        HStack(spacing: 8) {
            SessionStatusPill(status: session.status, reason: session.statusReason)
            if session.archived {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary).accessibilityLabel("Archived")
            }
        }
    }

    private func usageLabel(_ summary: IndexedSessionUsageSummary) -> some View {
        let totals = summary.totals
        let tokens = totals.counts.total
        let cost = currency.formattedMicroUSD(Decimal(totals.costMicroUSD))
        let markedCost = summary.hasApproximateQuote ? "≈" + cost : cost
        let tokenLabel = String(localized: "\(tokens.formatted()) tokens")
        let costLabel: String? = totals.hasPricedUsage
            ? (totals.unpricedTokens > 0 ? String(localized: "Partial estimate: \(cost)")
                                        : String(localized: "List-price estimate: \(cost)"))
            : (totals.unpricedTokens > 0 ? String(localized: "Unpriced") : nil)
        let approximateLabel = summary.hasApproximateQuote && totals.hasPricedUsage
            ? String(localized: "Includes approximate quotes") : nil
        let description = totals.records == 0 ? String(localized: "No token usage yet")
            : [tokenLabel, costLabel, approximateLabel].compactMap { $0 }.joined(separator: " · ")
        return HStack(spacing: 4) {
            if totals.records == 0 {
                Text(verbatim: "—")
            } else {
                Text(tokens.formatted(.number.notation(.compactName)))
                if totals.hasPricedUsage {
                    Text(verbatim: "·")
                    if totals.unpricedTokens > 0 { Text("Partial estimate: \(markedCost)") }
                    else { Text(verbatim: markedCost) }
                } else if totals.unpricedTokens > 0 {
                    Text(verbatim: "·")
                    Text("Unpriced")
                }
            }
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: description))
        .accessibilityIdentifier("session.list.usage")
        .help(Text(verbatim: description))
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
    @DashboardClock private var clock
    @State private var section = DetailSection.transcript
    @State private var compactFacts = false
    @Environment(\.sessionOverviewOptions) private var overviewOptions
    @Environment(\.secretMaskingEnabled) private var maskSessionActivity
    #if AGENTDASH_SYNTHETIC_ONLY
    @Environment(\.syntheticLongTranscriptSelection) private var syntheticLongTranscriptSelection
    #endif

    private enum DetailSection: Hashable { case overview, transcript }
    private var showingOverview: Bool { overviewOptions.enabled && section == .overview }

    let session: SessionListItem
    let store: AgentStore
    let search: SessionTranscriptSearch?
    let hostHome: String?
    let contextWindowRules: [ModelContextWindow]
    let displayCurrency: PriceDisplayCurrency
    @State private var activity: SessionActivityDisplay?
    @State private var editingTitle = false
    private var running: Bool { session.status == .running && !session.archived }
    @State private var indexedContext: IndexedSessionContext?
    @State private var usage: IndexedSessionUsage?
    @State private var inherited: InheritedTranscriptSummary?
    @State private var request: TranscriptPageRequest
    @State private var loading = true
    @State private var failed = false
    @State private var page: TranscriptPage?
    @State private var viewRevision = 0
    @State private var transcriptPosition = ScrollPosition(idType: String.self)
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
         hostHome: String? = nil, contextWindowRules: [ModelContextWindow] = [], displayCurrency: PriceDisplayCurrency = .usd) {
        self.session = session
        self.store = store
        self.search = search
        self.hostHome = hostHome
        self.contextWindowRules = contextWindowRules
        self.displayCurrency = displayCurrency
        _request = State(initialValue: search.map { .around($0.firstMatchKey) } ?? .first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    SessionAgentMark(agent: session.id.agent)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            SessionTitle(title: session.title).font(.title3.weight(.semibold))
                                .accessibilityIdentifier("session.title.header")
                            Button { editingTitle = true } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Rename Session")
                            .accessibilityIdentifier("session.title.rename")
                            .help("Rename Session")
                        }
                        if let source = session.titleSource {
                            Text(source.label).font(.caption2).foregroundStyle(.secondary)
                                .accessibilityIdentifier("session.title.source")
                        }
                        Text(verbatim: [session.id.agent.sessionName, session.path, session.branch, session.environment]
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 8)
                    SessionStatusPill(status: session.status, reason: session.statusReason)
                }
                detailFacts.font(.caption)
                if running, let activity {
                    SessionActivityBar(activity: activity)
                }
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
            } else if let page, !page.events.isEmpty || inherited != nil {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if let inherited, search == nil {
                            InheritedTranscriptSection(child: session.id, summary: inherited, store: store)
                        }
                        ForEach(page.events, id: \.dedupeKey) { event in
                            let selectedKey = highlightedMatchKey
                            let matched = selectedKey.map(page.rowKey(forEvent:)) == event.dedupeKey
                            TranscriptEventRow(event: event, result: page.toolResults[event.dedupeKey],
                                               matchKey: matched ? selectedKey : nil, store: store)
                                .padding(matched ? 5 : 0)
                                .background(matched ? Color.accentColor.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 6))
                                .id(event.dedupeKey)
                                #if AGENTDASH_SYNTHETIC_ONLY
                                .background {
                                    if SyntheticLongTranscript.measuring,
                                       SyntheticLongTranscript.watches(session.id, sequence: event.sequence) {
                                        SyntheticTranscriptRowProbe(sequence: event.sequence) { window, scroll in
                                            SyntheticTranscriptRun.shared.didDraw(
                                                session: session.id, sequence: event.sequence, page: page,
                                                window: window, scroll: scroll,
                                                select: syntheticLongTranscriptSelection, seek: seek
                                            )
                                        }
                                    }
                                }
                                #endif
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollPosition($transcriptPosition, anchor: .top)
                .id(viewRevision)
                .accessibilityIdentifier("session.transcript.messages")
                #if AGENTDASH_SYNTHETIC_ONLY
                .background {
                    if let fixture = SyntheticResourceFixture.current, fixture.matches(session) {
                        SyntheticRowDrawMarker(event: "synthetic-resources transcript", onDraw: fixture.transcriptDidDraw)
                    }
                }
                #endif
            } else {
                EmptyPanel(title: "No transcript yet", symbol: "text.bubble",
                           message: "This indexed session does not have any transcript entries.")
            }
            Divider()
            SessionActionFooter(session: session.id, store: store, hostHome: hostHome)
        }
        .sheet(isPresented: $editingTitle) {
            SessionTitleEditor(session: session, store: store)
        }
        .task(id: running) { await observeActivity() }
        .task(id: session.id) { await observeContext() }
        .task(id: session.id) { await observeUsage() }
        .task(id: session.id) { await observeInheritedTranscript() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.transcript")
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: Bool.self) {
            DashboardLayoutRules.compactDetail(width: $0.size.width)
        } action: { compactFacts = $0 }
        .task(id: request) { [request] in await observePage(request) }
        .task(id: matchLookup) { [lookup = matchLookup] in
            if let lookup { await resolveMatch(lookup) }
        }
    }

    private func scrollTarget(in page: TranscriptPage) -> String? {
        guard case .around(let key) = request else { return nil }
        return page.rowKey(forEvent: key)
    }

    private func observeActivity() async {
        activity = nil
        guard running else { return }
        let masking = maskSessionActivity
        do {
            for try await indexed in store.sessionActivityUpdates(in: session.id) {
                guard !Task.isCancelled else { return }
                activity = indexed.map { SessionActivityDisplay($0, agent: session.id.agent, maskSecrets: masking) }
            }
        } catch {
            if !Task.isCancelled { activity = nil }
        }
    }

    @ViewBuilder private var detailFacts: some View {
        if compactFacts {
            twoColumnFacts
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    startFact.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 16)
                    turnsFact.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 16)
                    usageFact.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 16)
                    contextFact.fixedSize(horizontal: true, vertical: false)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("session.details.facts.wide")
                twoColumnFacts
            }
        }
    }

    private var twoColumnFacts: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow(alignment: .top) { startFact; turnsFact }
            GridRow(alignment: .top) { usageFact; contextFact }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("session.details.facts.compact")
    }

    private var startFact: some View {
        sessionFact("Started") {
            if let time = session.startedAt {
                Text(verbatim: sessionDate(time).formatted(clock.month(.abbreviated).day().hour().minute()))
                    .accessibilityIdentifier("session.started.clock")
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
                    let currency = displayCurrency.formattedMicroUSD(Decimal(usage.totals.costMicroUSD))
                    costReading(currency, partial: usage.totals.unpricedTokens > 0)
                        .accessibilityElement(children: .combine)
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

    private func costReading(_ currency: String, partial: Bool) -> some View {
        let amount = Text(verbatim: currency)
            .monospacedDigit()
            .fontWeight(.semibold)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
        let estimate = Text(partial ? "Partial estimate" : "List-price estimate")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                amount
                estimate
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 1) {
                amount
                estimate
            }
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

    private func observeInheritedTranscript() async {
        guard session.id.agent == .claudeCode, search == nil else { return }
        do {
            for try await summary in store.inheritedTranscriptSummary(in: session.id) {
                guard !Task.isCancelled else { return }
                inherited = summary
            }
        } catch {
            if !Task.isCancelled { inherited = nil }
        }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value.input.formatted()) / \(value.capacity.formatted()) tokens")
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(value.fraction.formatted(.percent.precision(.fractionLength(1)))) used")
                    .monospacedDigit()
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
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
        transcriptPosition = ScrollPosition(idType: String.self)
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
                if let snapshot {
                    let target = scrollTarget(in: snapshot)
                    let previousTarget = page.flatMap { scrollTarget(in: $0) }
                    if page == nil || previousTarget != target {
                        // Bind a target before the scroll view lays out this page.
                        // Keep a user's scroll position on unrelated index updates.
                        if let target { transcriptPosition.scrollTo(id: target, anchor: .top) }
                        else { transcriptPosition.scrollTo(edge: .top) }
                        if page != nil { viewRevision += 1 }
                    }
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

private struct InheritedTranscriptSection: View {
    let child: SessionKey
    let summary: InheritedTranscriptSummary
    let store: AgentStore
    @Environment(\.secretMaskingEnabled) private var maskSecrets
    @State private var expanded = false
    @State private var request: InheritedTranscriptRequest = .first
    @State private var page: InheritedTranscriptPage?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded.toggle()
                if !expanded { request = .first; page = nil }
            } label: {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    if let title = displayedSessionTitle(summary.originalTitle, maskSecrets: maskSecrets) {
                        Text("Continued from \(title)")
                            .lineLimit(2)
                    } else {
                        Text("Inherited conversation")
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout.weight(.medium))
            .accessibilityIdentifier("transcript.inherited.toggle")
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))

            if expanded {
                if failed {
                    Text("Could not read the transcript").foregroundStyle(.secondary)
                } else if let page {
                    if page.older != nil || page.newer != nil {
                        HStack {
                            Button("Earlier inherited messages") { if let cursor = page.older { request = .before(cursor) } }
                                .disabled(page.older == nil)
                            Button("Later inherited messages") { if let cursor = page.newer { request = .after(cursor) } }
                                .disabled(page.newer == nil)
                        }
                        .controlSize(.small)
                    }
                    ForEach(page.events, id: \.dedupeKey) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.kind.transcriptLabel).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            if let name = event.toolName { Text(verbatim: maskSecrets ? SecretMasker.mask(name) : name) }
                            // The verified copy includes the stored preview only;
                            // no actions can open the original session's raw tool records here.
                            if let text = event.text { ProtectedTranscriptText(raw: text) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else { ProgressView().controlSize(.small) }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
        .task(id: expanded ? request : nil) {
            guard expanded else { return }
            await observe(request)
        }
    }

    private func observe(_ requested: InheritedTranscriptRequest) async {
        failed = false
        page = nil
        do {
            for try await result in try store.inheritedTranscriptPages(in: child, request: requested) {
                guard !Task.isCancelled, expanded, request == requested else { return }
                page = result
            }
        } catch let error as TranscriptPagingError where error == .staleCursor && requested != .first {
            if !Task.isCancelled, request == requested { request = .first }
        } catch {
            if !Task.isCancelled, request == requested { failed = true }
        }
    }
}

private struct TranscriptEventRow: View {
    @DashboardClock private var clock
    let event: EventRecord
    let result: EventRecord?
    let matchKey: String?
    let store: AgentStore
    @State private var expanded = false

    var body: some View {
        if event.kind == .toolCall || event.kind == .toolResult {
            TranscriptToolRow(event: event, result: result, matchKey: matchKey, store: store)
        } else if event.kind == .thinking {
            DisclosureGroup(isExpanded: $expanded) {
                if expanded { ProtectedTranscriptText(raw: event.text ?? "").padding(.top, 5) }
            } label: {
                Label { Text(event.kind.transcriptLabel) } icon: { Image(systemName: "text.bubble") }
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
                    Text(verbatim: sessionDate(event.timestamp).formatted(clock.hour().minute())).foregroundStyle(.tertiary)
                }
                .font(.caption.weight(.medium))
                if let text = event.text {
                    ProtectedTranscriptText(raw: text)
                }
            }
        }
    }
}

private struct TranscriptToolRow: View {
    let event: EventRecord
    let result: EventRecord?
    let matchKey: String?
    let store: AgentStore
    @State private var expanded: Bool
    @Environment(\.secretMaskingEnabled) private var maskSecrets

    init(event: EventRecord, result: EventRecord?, matchKey: String?, store: AgentStore) {
        self.event = event
        self.result = result
        self.matchKey = matchKey
        self.store = store
        _expanded = State(initialValue: matchKey != nil)
    }

    private var input: EventRecord? { event.kind == .toolCall ? event : nil }
    private var output: EventRecord? { event.kind == .toolResult ? event : result }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 8)
                        .accessibilityHidden(true)
                    Label {
                        if let name = TranscriptToolPreview.summary(event.toolName ?? output?.toolName, masking: maskSecrets) {
                            Text(verbatim: name).fontWeight(.semibold).lineLimit(1)
                        } else { Text(event.kind.transcriptLabel).fontWeight(.semibold) }
                    } icon: {
                        Image(systemName: input == nil ? "doc.text" : "terminal")
                    }
                    .frame(maxWidth: 132, alignment: .leading)
                    .layoutPriority(1)
                    if let text = TranscriptToolPreview.argument(input, masking: maskSecrets) {
                        Text(verbatim: text)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let output {
                        if let text = TranscriptToolPreview.summary(output.text, masking: maskSecrets) {
                            Text(verbatim: text).lineLimit(1).frame(maxWidth: 132, alignment: .trailing)
                        } else { Text("Result recorded").lineLimit(1) }
                    } else { Text("No result recorded").lineLimit(1) }
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("transcript.tool.toggle")
            if expanded {
                VStack(alignment: .leading, spacing: 9) {
                    if let input {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tool Input").font(.caption.weight(.semibold))
                            ToolInputBody(event: input, store: store)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("transcript.tool.input")
                    }
                    if let output {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Tool Output").font(.caption.weight(.semibold))
                            ToolResultOutput(event: output, store: store).id(output.dedupeKey)
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("transcript.tool.output")
                    }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcript.tool.row")
        .onChange(of: matchKey) { _, key in if key != nil { expanded = true } }
    }
}

private enum TranscriptToolPreview {
    // Producers may cut at 2 KiB and drop up to three bytes of a trailing scalar.
    static func mayBePartial(_ value: String?) -> Bool { (value?.utf8.count ?? 0) >= 2045 }

    static func indexedText(_ value: String?, masking: Bool) -> String? {
        guard let value else { return nil }
        if masking && mayBePartial(value) {
            // An incomplete last line could end before a token is recognizable.
            guard let end = value.lastIndex(where: \.isNewline), end != value.startIndex else { return nil }
            return String(value[..<end])
        }
        return value
    }

    static func argument(_ event: EventRecord?, masking: Bool) -> String? {
        guard let event, let input = indexedText(event.text, masking: masking) else { return nil }
        if event.toolName == "exec_command",
           let arguments = try? JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any],
           let command = arguments["cmd"] as? String {
            return summary(command, masking: masking)
        }
        return summary(input, masking: masking)
    }

    static func summary(_ value: String?, masking: Bool) -> String? {
        guard let text = indexedText(value, masking: masking) else { return nil }
        let safe = masking ? IndexSecretMasker.text(text) : text
        guard let first = safe.split(whereSeparator: \.isNewline).first, !first.isEmpty else { return nil }
        return first.count <= 112 ? String(first) : String(first.prefix(112)) + "…"
    }
}

private struct ToolInputBody: View {
    let event: EventRecord
    let store: AgentStore
    @Environment(\.secretMaskingEnabled) private var maskSecrets
    @State private var hasOriginal = false
    @State private var original: String?
    @State private var loading = false
    @State private var failure: ToolInputReadFailure?
    @State private var readTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = original ?? TranscriptToolPreview.indexedText(event.text, masking: maskSecrets), !text.isEmpty {
                ProtectedTranscriptText(raw: text, maskStructured: true)
            } else {
                Text("No indexed input preview.").font(.caption).foregroundStyle(.secondary)
            }
            if original == nil {
                if hasOriginal {
                    Button("Read Original Input") {
                        readTask = Task { await readOriginal() }
                    }
                    .disabled(loading)
                    .accessibilityIdentifier("transcript.toolInput.readOriginal")
                } else if event.session.agent == .claudeCode || TranscriptToolPreview.mayBePartial(event.text) {
                    Text("Only the indexed input preview is available.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if loading { ProgressView().controlSize(.small) }
            if let failure {
                switch failure {
                case .tooLarge: Text("The original input exceeds the display limit.")
                case .changedOrUnavailable: Text("The original input is no longer available.")
                }
            }
        }
        .task(id: event.dedupeKey) {
            let store = store
            let key = event.session
            let dedupe = event.dedupeKey
            let available = await Task.detached {
                (try? store.registeredToolInput(in: key, eventKey: dedupe)) != nil
            }.value
            if !Task.isCancelled { hasOriginal = available }
        }
        .onDisappear {
            readTask?.cancel()
            readTask = nil
            original = nil
            hasOriginal = false
        }
    }

    private func readOriginal() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        failure = nil
        let store = store
        let key = event.session
        let dedupe = event.dedupeKey
        let task = Task.detached(priority: .utility) {
            guard let registered = try store.registeredToolInput(in: key, eventKey: dedupe)
            else { throw ToolInputReadFailure.changedOrUnavailable }
            let text = try await SourceAccessProbe.withIndexingAccess(to: registered.source) { root in
                try Task.checkCancellation()
                return try ToolInputReader.read(registered, authorizedRoot: root)
            }
            guard try store.registeredToolInput(in: key, eventKey: dedupe) == registered else {
                throw ToolInputReadFailure.changedOrUnavailable
            }
            return registered.redact ? IndexSecretMasker.text(text) : text
        }
        do {
            let text = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            if !Task.isCancelled { original = text }
        } catch {
            if !Task.isCancelled { failure = error as? ToolInputReadFailure ?? .changedOrUnavailable }
        }
    }
}

private struct ToolResultOutput: View {
    let event: EventRecord
    let store: AgentStore
    @Environment(\.secretMaskingEnabled) private var maskSecrets
    @State private var details: ToolOutputDetails?
    @State private var original: OriginalToolOutput?
    @State private var failed = false
    @State private var loading = false
    @State private var readTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let text = original?.text ?? details?.archivedText ?? TranscriptToolPreview.indexedText(event.text, masking: maskSecrets) {
                ProtectedTranscriptText(raw: text, maskStructured: true)
            } else {
                Text("No indexed output preview.").font(.caption).foregroundStyle(.secondary)
            }
            if original?.truncated == true {
                Text("Only a bounded prefix of the original is shown.").font(.caption).foregroundStyle(.secondary)
            }
            if details?.archivedText != nil && original == nil {
                Text("Archived tool output").font(.caption).foregroundStyle(.secondary)
            }
            if details?.hasOriginal == true && original == nil && details?.archivedText == nil {
                Button("Read Original Output") {
                    readTask = Task { await readOriginal() }
                }
                .disabled(loading)
                .accessibilityIdentifier("transcript.toolOutput.readOriginal")
            }
            if loading { ProgressView().controlSize(.small) }
            if failed { Text("The original output is no longer available.").font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: event.dedupeKey) {
            let key = event.session
            let dedupe = event.dedupeKey
            let store = self.store
            let read = await Task.detached { try? store.toolOutputDetails(in: key, eventKey: dedupe) }.value
            guard !Task.isCancelled else { return }
            details = read
        }
        .onDisappear { readTask?.cancel(); readTask = nil; original = nil; details = nil }
    }

    private func readOriginal() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        failed = false
        let store = self.store
        let key = event.session
        let dedupe = event.dedupeKey
        let masking = maskSecrets
        let task = Task.detached(priority: .utility) { () throws -> OriginalToolOutput in
            guard let registered = try store.registeredToolOutput(in: key, eventKey: dedupe)
            else { throw ToolOutputReadFailure.changedOrUnavailable }
            let result = try await SourceAccessProbe.withIndexingAccess(to: registered.source) { root in
                try ToolOutputReader.read(registered, authorizedRoot: root)
            }
            guard try store.registeredToolOutput(in: key, eventKey: dedupe) == registered
            else { throw ToolOutputReadFailure.changedOrUnavailable }
            var text = result.text
            // Do not expose an incomplete last line containing a partially
            // captured credential when either masking policy is active.
            if result.truncated && (masking || registered.redact), text.last?.isNewline == false {
                text = text.lastIndex(where: \.isNewline).map { String(text[..<$0]) } ?? ""
            }
            if registered.redact { text = IndexSecretMasker.text(text) }
            return .init(text: text, truncated: result.truncated)
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            original = value
        } catch { if !Task.isCancelled { failed = true } }
    }
}

private struct ProtectedTranscriptText: View {
    let raw: String
    var maskStructured = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.secretMaskingEnabled) private var maskSecrets
    @State private var revealedText: String?

    var body: some View {
        let masked = maskSecrets ? (maskStructured ? IndexSecretMasker.text(raw) : SecretMasker.mask(raw)) : raw
        let revealed = revealedText == raw
        let displayed = revealed ? raw : masked
        let sections = TranscriptFormatting.sections(displayed)
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if section.code {
                    Text(verbatim: section.text).font(.body).monospaced()
                } else {
                    Text(TranscriptFormatting.inline(section.text, maskRenderedText: maskSecrets && !revealed))
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
        .onChange(of: maskSecrets) { _, _ in revealedText = nil }
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

nonisolated func displayedSessionTitle(_ text: String?, maskSecrets: Bool) -> String? {
    guard let text else { return nil }
    // Mask the whole bounded title before flattening or taking a prefix.
    let safe = maskSecrets ? SecretMasker.mask(text) : text
    let line = safe.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return line.isEmpty ? nil : String(line.prefix(SessionTitleRules.maximumCharacters))
}

private extension SessionTitleSource {
    var label: LocalizedStringResource {
        switch self {
        case .user: "Custom title"
        case .agent: "From agent"
        case .firstPrompt: "From first prompt"
        }
    }
}

private struct SessionTitleEditor: View {
    let id: SessionKey
    let store: AgentStore
    let hasCustomTitle: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var saving = false
    @State private var failed = false

    init(session: SessionListItem, store: AgentStore) {
        id = session.id
        self.store = store
        hasCustomTitle = session.titleSource == .user
        #if AGENTDASH_SYNTHETIC_ONLY
        let fixture = ProcessInfo.processInfo.environment["AGENTDASH_SYNTHETIC_SESSION_TITLE"] == "1"
            ? "自定义会话示例" : nil
        _title = State(initialValue: fixture ?? session.title ?? "")
        #else
        _title = State(initialValue: session.title ?? "")
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Session").font(.headline)
            TextField("Session Title", text: $title)
                .accessibilityIdentifier("session.title.edit")
            Text("The title is stored in the local index.").font(.caption).foregroundStyle(.secondary)
            if failed { Text("Could not save the session title.").foregroundStyle(.red) }
            HStack {
                if hasCustomTitle {
                    Button("Use Automatic Title") { Task { await save(nil) } }
                        .accessibilityIdentifier("session.title.reset")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let value = SessionTitleRules.validatedCustomTitle(title) else { return }
                    Task { await save(value) }
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("session.title.save")
                .disabled(SessionTitleRules.validatedCustomTitle(title) == nil)
            }
        }
        .padding(20)
        .frame(width: 380)
        .disabled(saving)
        .interactiveDismissDisabled(saving)
    }

    private func save(_ title: String?) async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try await store.setCustomSessionTitle(title, for: id)
            dismiss()
        } catch {
            failed = true
        }
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
        case .thinking: "Thinking"
        case .unknown: "Unrecognized Event"
        }
    }
}

func sessionDate(_ epochMilliseconds: Int64) -> Date {
    Date(timeIntervalSince1970: Double(epochMilliseconds) / 1_000)
}
