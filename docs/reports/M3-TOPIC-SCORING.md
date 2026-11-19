# M3 pure topic scorer — 2026-11-19

Scope: standalone SPEC §10.2 scoring and its bundled stop-word resources.

## Integration API

All types below are public in ADInsights. The value types are Sendable;
TopicDocument and WeightedTopic are also Equatable.

```swift
TopicDocument(userPrompts: [String], assistantReplies: [String], fileNames: [String])
try TopicScorer()
scorer.counts(for: document) // [String: Double]
scorer.top(counts, documentCount: n, documentFrequency: df, limit: 5) // [WeightedTopic]
WeightedTopic(term: String, score: Double) // public let term, score
```

The caller supplies text, N and df. The scorer does not query or maintain a store.
Only initialization reads the two bundled UTF-8 stop-word resources; file-name
strings are never opened. Package.swift processes ADInsights/Resources and declares
the ADInsightsTests target. Existing dependency pins and module dependencies stay intact.

## Behavior and findings

- Prompts/replies/file names contribute 2/1/1.5 per occurrence. Shared ADCore
  SearchTokenization provides normalization, whole identifiers, unique aliases and
  overlapping CJK bigrams. A safe Unicode scan separates prose, paths and emoji;
  surrounding `_-.` is trimmed while internal separators such as `auth.ts` remain.
- CJK singles, number-only terms and non-CJK terms shorter than three characters
  are omitted. Message/role boundaries do not create new tokens.
- Repository-curated resources contain 160 English/programming terms and 60 Chinese
  stop bigrams. Exact normalized matches are removed; domain examples such as
  cache, authentication, 登录, 缓存, 修复 and 问题 remain.
- Scores are exactly `ln(1 + count) * ln(N / (1 + df))`. Small corpora can produce
  zero or negative scores; these are retained without clamping or smoothing.
- Missing df is zero. Nonpositive N/limit returns an empty result. Empty terms,
  nonpositive/nonfinite counts and df outside 0...N are omitted. Converting df to
  Double before adding one avoids integer overflow at Int.max.
- Sort by descending score, then ascending term. Skip only substrings of already
  selected terms, continuing until the requested limit (default five) is filled
  or candidates are exhausted. A lower-ranked longer term may still be selected.

## Executed validation

Final focused headless package run passed: **12 test functions**, including seven
Chinese parameter cases, zero failures and no build warnings. Tests import the
public ADInsights API and use bounded synthetic strings (largest generated corpus:
256 fixed phrase repetitions), with hand-computed counts and exact score expectations.
The first run's sole failure expected the stop word `done` to survive; the synthetic
emoji-boundary case now uses the non-stop word `canvas`.

Resource validation passed unique-entry, normalized English/alphabetical and
two-character Chinese checks, including all six required Chinese examples.
`Tools/forbid-apis.sh` passed (24 production sources);
`Tools/check-dependencies.sh` passed (exact GRDB.swift 7.11.1, consistent locks);
`git diff --check` passed.

The focused run used task-local scratch and the existing pinned GRDB cache.

```sh
task_scratch=$(mktemp -d /private/tmp/agentdash-topic-verify.XXXXXX)
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  CLANG_MODULE_CACHE_PATH="$task_scratch/module-cache" \
  SWIFTPM_MODULECACHE_OVERRIDE="$task_scratch/module-cache" \
  xcrun swift test --package-path Packages/AgentDashKit \
  --scratch-path "$task_scratch/build" --cache-path "$task_scratch/cache" \
  --config-path "$task_scratch/config" --security-path "$task_scratch/security" \
  --manifest-cache local --disable-sandbox --disable-netrc --disable-keychain \
  --disable-automatic-resolution --jobs 4 --filter ADInsightsTests
```

Store/App/adapter code is unchanged. Verification uses only synthetic inputs
and no desktop automation or installation. Full package and
App/UI suites, App signing and entitlements validation were outside this focused
headless task; no acceptance claim is made for those or for store integration.
