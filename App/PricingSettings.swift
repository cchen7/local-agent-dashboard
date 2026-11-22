import ADIngest
import ADPricing
import ADPrivacy
import ADStore
import AppKit
import SwiftUI

struct PricingRuntimeUpdate: Sendable {
    struct Sweep: Sendable {
        let unpriced: UnpricedTokenSweep?
        let cacheSavings: CacheSavingsSweep?
    }

    let status: PriceFileStatus
    let sweep: Sweep?
}

/// Serializes file resolution and activation. The displayed table is the one
/// supplying new quotes; validated but uninstalled bytes are not published.
actor LocalPricingRuntime {
    nonisolated let external: URL?
    private let bundled: URL?
    private let store: AgentStore
    private var resolver: PriceFileResolver
    private var cached: Data?
    private var active: PriceFileStatus?

    init(external: URL?, bundled: URL?, store: AgentStore) {
        self.external = external
        self.bundled = bundled
        self.store = store
        cached = try? store.lastVerifiedPriceBytes()
        resolver = PriceFileResolver(lastVerified: cached.map(PriceFileCandidate.bytes) ?? .missing)
    }

    func refresh(restartSweep: Bool = false) -> PricingRuntimeUpdate? {
        guard !Task.isCancelled else { return nil }
        var pending = resolver
        var status = pending.refresh(external: external.map { PriceFileReader.read($0) } ?? .missing,
                                     bundled: bundled.map { PriceFileReader.read($0) } ?? .missing)
        guard !Task.isCancelled else { return nil }
        var sweep: PricingRuntimeUpdate.Sweep?
        if active == nil || active?.fingerprint != status.fingerprint || restartSweep {
            do {
                let savings = try store.pendingCacheSavings()
                let horizon = try store.activatePricing(TokenQuoteEngine.make(table: pending.verifiedTable))
                let unpriced = status.modelCount > 0 ? horizon : nil
                if unpriced != nil || savings != nil { sweep = .init(unpriced: unpriced, cacheSavings: savings) }
            } catch {
                let retained = status.issues.reduce(active ?? .empty) { $0.reporting($1) }
                return .init(status: retained.reporting(.init(origin: status.origin, failure: .pricingApplyFailed)), sweep: nil)
            }
        }
        resolver = pending
        active = status
        if let bytes = resolver.verifiedBytes, bytes != cached {
            do { try store.rememberVerifiedPriceBytes(bytes); cached = bytes }
            catch { status = status.reporting(.init(origin: .lastVerified, failure: .cacheWriteFailed)) }
        }
        return .init(status: status, sweep: sweep)
    }
}

@MainActor @Observable
final class PricingModel {
    private(set) var status = PriceFileStatus.empty
    private(set) var backfilling = false
    private(set) var backfillFailed = false
    private(set) var unpriced: [UnpricedModelUsage]?
    private(set) var unpricedFailed = false
    @ObservationIgnored private var store: AgentStore?
    @ObservationIgnored private var runtime: LocalPricingRuntime?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?
    @ObservationIgnored private var watchID = UUID()
    @ObservationIgnored private var sweepID = UUID()
    private static let currencyKey = "priceDisplayCurrency"
    private let persistsCurrency = !CommandLine.arguments.contains("--synthetic")
    private var preferredCurrency = "USD"

    init() {
        if persistsCurrency {
            preferredCurrency = UserDefaults.standard.string(forKey: Self.currencyKey) ?? "USD"
        }
    }

    deinit { watchTask?.cancel(); sweepTask?.cancel() }

    var currencies: [PriceDisplayCurrency] { PriceDisplayCurrency.choices(status.displayCurrencies) }
    var currency: PriceDisplayCurrency { currencies.first { $0.code == preferredCurrency } ?? .usd }

    func selectCurrency(_ code: String) {
        guard currencies.contains(where: { $0.code == code }) else { return }
        preferredCurrency = code
        if persistsCurrency { UserDefaults.standard.set(code, forKey: Self.currencyKey) }
    }

    func attach(store: AgentStore, runtime: LocalPricingRuntime, initial: PricingRuntimeUpdate?) {
        self.store = store
        self.runtime = runtime
        if let initial { receive(initial) }
        reload(restartSweep: false)
    }

    func reload(restartSweep: Bool = true) {
        guard let runtime else { return }
        watchTask?.cancel()
        watchID = UUID()
        let watchID = self.watchID
        watchTask = Task.detached(priority: .utility) { [weak self] in
            let directory = runtime.external?.deletingLastPathComponent()
            let events = AsyncStream<FSEventsWatcher.Signal>.makeStream(bufferingPolicy: .bufferingNewest(1))
            func watch() -> FSEventsWatcher? {
                guard let directory else { return nil }
                return try? FSEventsWatcher(authorizedRoot: directory) { events.continuation.yield($0) }
            }
            var watcher = watch()
            defer { watcher?.cancel(); events.continuation.finish() }
            func publish(watchingUnavailable: Bool, restartSweep: Bool = false) async {
                guard let update = await runtime.refresh(restartSweep: restartSweep), !Task.isCancelled else { return }
                let status = watchingUnavailable
                    ? update.status.reporting(.init(origin: .external, failure: .watchingUnavailable)) : update.status
                await self?.receiveWatched(.init(status: status, sweep: update.sweep), watchID: watchID)
            }
            // Watch before the first read to cover changes after the bootstrap.
            await publish(watchingUnavailable: directory != nil && watcher == nil, restartSweep: restartSweep)
            guard watcher != nil else { return }
            for await signal in events.stream {
                guard !Task.isCancelled else { return }
                if signal == .rescanRequired { watcher?.cancel(); watcher = watch() }
                await publish(watchingUnavailable: watcher == nil)
                if watcher == nil { return }
            }
        }
    }

    private func receiveWatched(_ update: PricingRuntimeUpdate, watchID: UUID) {
        guard self.watchID == watchID else { return }
        #if AGENTDASH_SYNTHETIC_ONLY
        if SyntheticRepricing.measuring, update.status.origin == .none,
           !update.status.issues.contains(where: { $0.failure == .watchingUnavailable }) {
            SyntheticRepricingRun.shared.watcherDidStart()
        }
        #endif
        receive(update)
    }

    private func receive(_ update: PricingRuntimeUpdate) {
        status = update.status
        guard let sweep = update.sweep, let store else { return }
        sweepTask?.cancel()
        sweepID = UUID()
        let sweepID = self.sweepID
        backfilling = true
        backfillFailed = false
        #if AGENTDASH_SYNTHETIC_ONLY
        if SyntheticRepricing.measuring, status.origin == .external {
            SyntheticRepricingRun.shared.sweepStarted()
        }
        #endif
        sweepTask = Task.detached(priority: .utility) { [weak self] in
            var savings = sweep.cacheSavings
            var unpriced = sweep.unpriced
            do {
                while let page = savings {
                    try Task.checkCancellation()
                    savings = try store.backfillCacheSavings(page).next
                    await Task.yield()
                }
                #if AGENTDASH_SYNTHETIC_ONLY
                var measuredQuoted = 0
                var nextProgress = 200_000
                #endif
                while let page = unpriced {
                    try Task.checkCancellation()
                    // Fewer commit round-trips, while the worker still
                    // yields between bounded writes.
                    let batch = try store.backfillUnpriced(page, limit: 2_048)
                    unpriced = batch.next
                    #if AGENTDASH_SYNTHETIC_ONLY
                    if SyntheticRepricing.measuring {
                        measuredQuoted += batch.priced
                        if measuredQuoted >= nextProgress {
                            SyntheticRepricing.report("progress \(measuredQuoted)")
                            nextProgress += 200_000
                        }
                    }
                    #endif
                    await Task.yield()
                }
                await self?.finishSweep(sweepID, failed: false)
            } catch is CancellationError { return }
            catch StoreError.pricingSuperseded { await self?.finishSweep(sweepID, failed: false) }
            catch { await self?.finishSweep(sweepID, failed: true) }
        }
    }

    private func finishSweep(_ id: UUID, failed: Bool) {
        guard sweepID == id else { return }
        backfilling = false
        backfillFailed = failed
        #if AGENTDASH_SYNTHETIC_ONLY
        if SyntheticRepricing.measuring, status.origin == .external {
            SyntheticRepricingRun.shared.sweepFinished(failed: failed)
        }
        #endif
    }

    func observeUnpriced(in store: AgentStore) async {
        unpricedFailed = false
        do {
            for try await rows in store.unpricedUsageUpdates() {
                guard !Task.isCancelled else { return }
                unpriced = rows
            }
        } catch {
            if !Task.isCancelled { unpricedFailed = true }
        }
    }

    func copyUnpricedModels() {
        guard let unpriced, !unpriced.isEmpty else { return }
        let report = unpriced.map { item -> String in
            let model = item.model.map(SecretMasker.mask) ?? String(localized: "Unknown model")
            let label = model.components(separatedBy: .controlCharacters).joined(separator: " ")
            return "\(label)\t\(item.tokens)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

struct PricingSettingsPane: View {
    let model: PricingModel
    let store: AgentStore?

    var body: some View {
        Form {
            Section("Price table") {
                LabeledContent("Active source") { Text(origin(model.status.origin)) }
                if let date = model.status.updatedAt {
                    LabeledContent("Updated") { Text(verbatim: date.rawValue) }
                    LabeledContent("Models") { Text(model.status.modelCount.formatted()) }
                }
                UsageCurrencyPicker(pricing: model)
                if let date = model.currency.asOf {
                    Text("Static exchange rate dated \(date.rawValue)").font(.caption).foregroundStyle(.secondary)
                }
                if model.backfilling { ProgressView("Updating price estimates…") }
                if model.backfillFailed {
                    Label("Price estimates could not be updated.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("Existing historical estimates are preserved.").foregroundStyle(.secondary)
                Button("Reload Price Table") { model.reload() }.disabled(store == nil)
                ForEach(Array(model.status.issues.enumerated()), id: \.offset) { _, issue in
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(origin(issue.origin)).font(.caption)
                            Text(message(issue.failure))
                        }
                    } icon: { Image(systemName: "exclamationmark.triangle") }
                        .foregroundStyle(.orange)
                }
            }
            Section("Unpriced models") {
                if model.unpricedFailed {
                    Text("Could not read unpriced usage.").foregroundStyle(.secondary)
                } else if let rows = model.unpriced {
                    if rows.isEmpty {
                        Text("No unpriced usage in the index.").foregroundStyle(.secondary)
                    } else {
                        ForEach(rows) { row in
                            LabeledContent {
                                Text(row.tokens.formatted()).monospacedDigit()
                            } label: {
                                if let id = row.model { Text(verbatim: SecretMasker.mask(id)).lineLimit(1) }
                                else { Text("Unknown model") }
                            }
                        }
                        Button("Copy Unpriced Models") { model.copyUnpricedModels() }
                    }
                } else {
                    ProgressView("Reading unpriced usage…")
                }
            }
        }
        .formStyle(.grouped)
        .task(id: store != nil) { if let store { await model.observeUnpriced(in: store) } }
        .accessibilityIdentifier("settings.pricing")
    }

    private func origin(_ source: PriceFileOrigin) -> LocalizedStringResource {
        switch source {
        case .external: "External price table"
        case .bundled: "Bundled price table"
        case .lastVerified: "Last verified table"
        case .none: "No verified price table"
        }
    }

    private func message(_ failure: PriceFileIssue.Failure) -> LocalizedStringResource {
        switch failure {
        case .unreadable: "A price file could not be read."
        case .invalid(.invalidJSON): "A price file contains invalid JSON."
        case .invalid(.duplicateEffectiveDate): "A price table repeats an effective date."
        case .invalid(.conflictingMatch), .invalid(.invalidAlias): "A price table has conflicting model rules."
        case .invalid: "A price table failed validation."
        case .cacheWriteFailed: "The verified table could not be retained for next launch."
        case .watchingUnavailable: "Price file changes require a manual reload."
        case .pricingApplyFailed: "Price estimates could not be updated."
        }
    }
}
