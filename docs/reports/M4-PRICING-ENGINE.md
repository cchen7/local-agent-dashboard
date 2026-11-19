# M4 pricing engine — scoped handoff

Requirement: FR-COST, SPEC §8.4–8.5 and §15 pricing. Base: public `main`
`86c1d08542ac8d9eb69f315e04a82c41c2928d4b`; work stays on
`feat/m4-pricing-engine`. All test documents are synthetic and constructed in
memory. This is the pure engine slice, not M4 acceptance or price-data maintenance.

## Public API

```swift
public struct PriceTable: Sendable {
    public static func decode(_ data: Data) throws(PricingError) -> Self
    public func match(model: String) -> ModelMatch?
    public func price(model: String, at timestamp: Int64) -> PriceSelection?
    public func estimate(_ event: TokenEvent) throws(PricingError) -> CostEstimate
}

public struct UTCDate: Equatable, Hashable, Comparable, Sendable {
    public let rawValue: String
    public init(_ value: String) throws(PricingError)
}

public struct CostEstimate: Equatable, Sendable {
    public let costMicroUSD: Int64
    public let unpricedTokens: Int64
    public let status: PricingStatus
    public let selection: PriceSelection?
    public let appliedTierThreshold: Int64?
}

public enum PricingStatus: Equatable, Sendable {
    case priced
    case approximate(Set<ApproximationReason>)
    case unpriced(UnpricedReason)
}
```

All result properties are immutable. Validated tables are constructible only by
`decode`. Supporting public value types (all `Equatable, Sendable`):

| Type | Public properties / cases |
|---|---|
| `PriceTable` | `schemaVersion: Int`, `currency, unit: String`, `updatedAt: UTCDate`, `displayCurrencies: [DisplayCurrency]`, `aliases: [String: String]`, `models: [PriceModel]` |
| `PriceModel` | `id, vendor, displayName: String`, `match: [String]`, `prices: [EffectivePrice]` |
| `EffectivePrice` | `effectiveFrom, checkedAt: UTCDate`, `rates: PriceRates`, `tiers: [PriceTier]`, `source: String` |
| `PriceRates` | `input, output: Decimal`, `cacheRead, cacheWrite5m, cacheWrite1h: Decimal?` |
| `PriceTier` | `whenPromptTokensAbove: Int64`, `rates: PriceRates` |
| `DisplayCurrency` | `code: String`, `ratePerUSD: Decimal`, `asOf: UTCDate` |
| `ModelMatch` | `model: PriceModel`, `kind: ModelMatchKind` |
| `ModelMatchKind` | `.alias`, `.exact`, `.glob` |
| `PriceSelection` | `match: ModelMatch`, `price: EffectivePrice` |
| `ApproximationReason` | `.coarsePrecision`, `.missingCacheReadPrice`, `.missingCacheWrite5mPrice`, `.missingCacheWrite1hPrice`; also `Hashable` |
| `UnpricedReason` | `.missingModel`, `.noMatchingModel`, `.noEffectivePrice` |

`PriceTable` is `Sendable` (not `Equatable`). `PricingError: Error, Equatable,
Sendable` has no associated values, underlying error, coding path, or input content:

```swift
case invalidJSON, unsupportedSchemaVersion, invalidCurrency, invalidUnit, invalidDate
case invalidModel, duplicateModel, emptyPrices, invalidPrice, duplicateEffectiveDate
case invalidTier, invalidMatchPattern, conflictingMatch, invalidAlias, invalidDisplayCurrency
case invalidTokenCounts, tokenCountOverflow, unrepresentableCost
```

## Behavior and conservative implementation choices

- Schema version 1, USD, per-million-token units. Required numeric fields must be
  JSON numbers; prices must be nonnegative and static display rates positive.
  Metadata dates are strict Gregorian `YYYY-MM-DD` in years 0001–9999.
  Source metadata must be nonblank; the engine does not verify vendor provenance.
- Optional aliases, display currencies, match patterns, and tiers default to empty.
  Optional cache rates remain `nil`, distinct from an explicit zero price.
- Normalize by trimming surrounding whitespace, lowercasing and removing one
  `anthropic/`, `openai/` or `xai/` prefix. Apply aliases to direct canonical model
  IDs, then exact normalized IDs, then anchored globs. `*` matches zero or more
  characters and `?` one character; other characters are literal. Literal match
  entries produce `.exact`. Glob specificity counts non-wildcard characters;
  equal specificity prefers the earlier model in JSON order.
- Duplicate normalized model IDs, identical normalized selectors naming different
  models, and literal selectors naming another model's canonical ID are conflicts.
  Overlapping distinct globs remain valid and use the specified priority rules.
  Alias targets must exist; chains/cycles, normalized key collisions and aliases
  overriding another canonical ID are rejected.
- Effective dates must be unique within a model; decode sorts their value copy.
  Lookup chooses the latest entry whose UTC date is no later than the event.
  Integer floor division handles pre-epoch milliseconds and both Int64 extrema.
  No date eligible means unpriced; no future-price fallback is used.
- Prompt count includes fresh input and all three cache categories. Call precision
  uses the highest tier whose threshold is **strictly below** prompt count, for
  the entire call. Snapshot/checkpoint precision always uses base prices and is
  approximate. Each missing cache rate falls back to the selected base/tier input
  rate; its reason is added only when that cache category has nonzero usage.
- Reasoning is validated as a nonnegative subset of output and never added again.
  Count sums use checked Int64 addition, including unpriced events. Unpriced
  results have zero cost and all cache-inclusive tokens in `unpricedTokens`.
  A valid zero-price estimate remains priced.
- All rates and products use Decimal. USD-per-million times token count is already
  micro-USD. Sum products, then call `NSDecimalRound(..., 0, .plain)` once per event:
  nearest integer, nonnegative half values round up. There is no Double conversion
  or rounding of individual components. Reject a result outside Int64 or an
  intermediate calculation that cannot stay in the 38-significant-digit Decimal
  envelope; do not clamp or return an unpriced result on arithmetic failure.
- Local execution exposed Foundation silently truncating some oversized JSON
  Decimal literals and multiplication coefficients despite a `.noError` result.
  The preflight requires UTF-8 and checks exactly the bytes passed to the typed
  decoder. It rejects duplicate decoded names in each JSON object (including
  escaped names), and rejects more than 38 significant digits (excluding
  leading/trailing zeroes and quoted strings) as `invalidJSON`.
  A bounded integer-coefficient check prevents multiply truncation while allowing
  exact trailing-zero cancellation; calculation error codes still guard arithmetic.

Review follow-up: 57 package tests passed, including 15 pricing tests. The new
tests reject UTF-16 and UTF-32 in both endian forms, conflicting rates in either
order, and duplicates represented by JSON escapes in tiers and aliases.

No source-format changes or confirmed product decisions are made. These choices
are proposed here for coordinator review, following `DEVELOPMENT_PLAN.md` rather
than editing the shared decision/spec files. The existing SPEC conflict about
backdated effective prices and historical recomputation remains unresolved and
outside this engine. Static display rates are decoded metadata; display conversion,
table persistence/fallback/watchers, update policy, and historical row/rollup writes
are outside this task.

## Verification

Tests were written first: the initial test build failed on the absent API. Two
precision regressions also failed before their respective guards were added.
Existing pinned GRDB checkout/repository copies seeded only the new task scratch;
dependency resolution was disabled, with no install or dependency/lockfile change.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$task_scratch/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$task_scratch/swift-cache" \
swift test --package-path Packages/AgentDashKit \
  --scratch-path "$task_scratch/build" --cache-path "$task_scratch/cache" \
  --config-path "$task_scratch/config" --security-path "$task_scratch/security" \
  --disable-sandbox --disable-automatic-resolution --filter ADPricingTests
```

The host rejected SwiftPM's nested sandbox at manifest compilation
(`sandbox-exec: sandbox_apply: Operation not permitted`). `--disable-sandbox`
disables that nested developer-tool sandbox only; the app's entitlements are
unchanged. All build/cache/config/security output paths above are task-local.

Final results: 13 Swift Testing tests in 1 suite passed, including 5 parameterized
rounding cases; no new compiler warnings. Golden examples include 161.75 → 162
micro-USD, all three cache types, reasoning inclusion, whole-call tiers at exact
boundaries, missing cache fallbacks and coarse precision. Invalid fields/dates,
alias/selector conflicts, numeric precision, negative/overflowing counts and amount
bounds are covered. `Tools/forbid-apis.sh`, `Tools/check-dependencies.sh`, and
`git diff --check` passed. Full package/App/UI tests were not run for this pure slice.

The focused checks use only synthetic inputs. They do not read real prices,
price files or user configuration, and do not write historical rows.
