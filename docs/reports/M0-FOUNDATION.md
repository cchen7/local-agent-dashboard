# M0-FOUNDATION handover — 2026-11-17

Status: implementation ready for coordinator review; **M0 acceptance remains blocked
on full Xcode, signed sandbox access and UI execution**. No commits, pushes, PRs or
merges were made. The initial working tree was clean. Only `App/`,
`AgentDashboard.xcodeproj/`, `Packages/AgentDashKit/` and this report were added.
`Tools/` and shared documents were not edited or imported from another worktree.

### Coordinator integration status

The worker statements above describe its original handover. The coordinator has
now published Draft PR #2 and integrated merged tooling PR #1. On the combined
source tree, the coordinator reran the API guard (18 production files), dependency
guard (exact GRDB 7.11.1, matching locks), all 40 tool tests (zero skipped), and
the 13 package test functions including 20 tokenizer cases: all passed. The schema
extension is recorded in SPEC §6.3 and DEV-006. Original notes below about missing
Tools are historical; actual App build, signed sandbox access and rendered UI
verification remain pending. No M0 acceptance or release claim is made.

Verified cwd:
`.worktrees/m0-foundation`.
Verified branch: `feat/m0-foundation`.

Coordinator review follow-up: removed the top-level `strict` helper and inlined
the identical `[.enableExperimentalFeature("StrictConcurrency")]` array on all
eight module targets and both test targets. `let package` is now the manifest's
only top-level declaration; Swift 6 complete concurrency and exact GRDB 7.11.1
remain unchanged. Before/after `swift package … dump-package` JSON is identical;
both lockfiles, the required `func accept` callback and cross-session dedupe
regression tests are byte-identical. No Tools changes were made.

Re-ran the documented package-test command after this manifest-only code change:
**13 test functions passed**, including **20 parameterized tokenizer cases**
(32 individual invocations). Log:
`/private/tmp/agentdash-m0-foundation/review-fix/package-tests.log`.
The existing CLT developer framework search-path linker warnings remain. The
coordinator's dependency guard and tooling worker's `func accept` false-positive
fix still require integration; actual App/UI/signed sandbox checks remain pending.

## Delivered and exported contracts

Requirements: M0, SEC-1…8, FR-SRC-1/2, ADP-3/5; foundational checkpoint support
for ADP-2/4; tokenizer cases from SPEC §9.2 and DEV-004.

`AgentDashKit` is one library product containing exactly the eight specified
modules. Its manifest declares only the SPEC §4.2 dependency edges. It uses Swift 6
language mode and strict concurrency, targeting macOS 27. The Xcode targets inherit
`ARCHS=arm64`, `MACOSX_DEPLOYMENT_TARGET=27.0`, `SWIFT_VERSION=6.0` and
`SWIFT_STRICT_CONCURRENCY=complete`.

| Public boundary | Contract for subsequent workers |
|---|---|
| `ADCore.Source`, `AccessKind`, `PathMapping`, `EnvironmentRule` | Sendable/Codable values; new sources have a nil database ID. Access is a default read-only location or opaque bookmark data. Mapping/rule execution is deferred. |
| `SourceFile`, `Checkpoint` | File identity is `(sourceID, relativePath)`. Checkpoint contains inode, observed byte size, next byte offset, parser version, last consumed sequence and previous UTC-millisecond timestamp. Register the source first; per-source adapters/ingestion receive its assigned ID. No file is opened by these values. |
| `SessionKey`, `SessionRecord` | Stable identity is `(agent, nativeID)`, independent of database session row IDs. Session metadata is intentionally minimal; remaining schema fields are reserved for later milestones. |
| `EventRecord`, `TokenEvent`, `NormalizedRecord` | Session records precede their event/token records. Adapters supply deterministic globally unique dedupe keys. Same-session corrections update a row; copied history from another session retains the first owner. Unknown event kind is representable. Truncation and vendor accounting remain adapter responsibilities. |
| `TokenCounts`, `TokenPrecision` | Total = fresh + cache read + both cache write classes + output. Reasoning is a subset of output. Store rejects negative components and reasoning greater than output. Usage remains unpriced in M0. |
| `ADAdapters.AgentAdapter` | SPEC §5.8 protocol only: discover, parse from checkpoint, and copyable resume-command text. No vendor implementation, source scan or compression dependency. |
| `ADStore.AgentStore` | Sendable synchronous facade over a private GRDB `DatabasePool`. APIs: `upsertSource`, `sources`, `upsertFile`, `checkpoint(for:)`, `write(_:fileID:checkpoint:)`, `events(in:)`. Call off the UI actor. No public SQL/GRDB objects; App imports ADCore/ADStore through the local package product. |
| Other five modules | Named module boundaries only, with no simulated ingestion, insights, search UI, privacy engine or pricing implementation. |

Store writes use natural-key upserts, never `REPLACE`. A record batch and its
optional checkpoint commit in one transaction. File metadata refresh with a nil
checkpoint preserves the old parser version so a later ingester can detect a
required reparse. `events(in:)` orders by sequence, then row ID, rather than time.
The initializer must receive an **app-owned** database URL, never a source database.

The v1 migration includes all SPEC §6.3 tables/indexes, external-content FTS and
insert/update/delete triggers. GRDB enables WAL and foreign keys; `agentdash` is
registered in `Configuration.prepareDatabase` **before migration**, on writer and
reader connections. DEV-004 is preserved: pure splitting is in ADCore and GRDB
registration is in ADStore; ADStore does not import ADSearch.

The unicode61 wrapper preserves original UTF-8 byte slices before case folding,
then emits ordered overlapping CJK bigrams and colocated identifier aliases. This
keeps camelCase, snake_case, kebab-case and whole filenames such as `auth.ts`
searchable. CJK phrase tests check substring order and a reversed negative case.
The M3 query builder/ranking/snippets remain unimplemented; multi-character CJK
substring queries must be submitted as ordered FTS phrases. Identifier aliases
share a position and can intentionally broaden a whole-identifier query.

`write` is an M0 persistence primitive: it **does not yet maintain session totals,
token rollups, costs, retention, keywords or observations**. Their schema is present;
complete those transactionally before connecting ingestion/dashboard UI. No claim
of parser or full accounting acceptance is made.

## Dependency pin and API evidence

Only external package: `https://github.com/groue/GRDB.swift.git`, exact **7.11.1**,
revision **b83108d10f42680d78f23fe4d4d80fc88dab3212**. Package and Xcode-workspace
lockfiles contain that identical single pin. GRDB and all eight project modules
compiled with the installed Swift 6.4.2 compiler. No zstd package was added.

Context7 resolved `/groue/grdb.swift/v7.11.1`; version-specific API documentation was
checked for DatabasePool, DatabaseMigrator, Configuration.prepareDatabase,
FTS5WrapperTokenizer and token callbacks. The original-case bridge and unicode61
configuration were also checked against the pinned official source:

- [FTS5 tokenizers](https://github.com/groue/GRDB.swift/blob/v7.11.1/Documentation/FTS5Tokenizers.md)
- [Tokenizer callback protocol](https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/FTS/FTS5Tokenizer.swift)
- [unicode61 descriptor](https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/FTS/FTS5TokenizerDescriptor.swift)
- [Concurrency](https://github.com/groue/GRDB.swift/blob/v7.11.1/GRDB/Documentation.docc/Concurrency.md)

All dependency checkouts, package caches, build output, development logs and helper
scripts are under `/private/tmp/agentdash-m0-foundation/`. No global configuration,
software, credentials, agent logs, memory or another worktree was inspected or
changed. Test records are inline synthetic values, not captured sessions.

## Native skeleton and access path

The shared `AgentDashboard` scheme builds the app and declares an XCUITest target.
Bundle ID is `com.chenxin.AgentDashboard`; signing team remains for the owner to
select. App Sandbox and Hardened Runtime are enabled. The entitlement plist matches
SPEC §12.1 exactly. `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` prevents an automatic
debug entitlement from expanding that list; the scheme launches without debugger
attachment. Actual signature entitlements have **not** been verified.

The app has an empty three-column Sessions/Projects window, two-column Token Usage
entry, 360-point menu panel, Settings, menu commands and English/Simplified Chinese
String Catalog (33 keys). Default size is 1120×720, minimum 960×600; sidebar and
list column bounds follow SPEC. Window-close keeps the menu app alive. No data or
active-session counts are fabricated. No SQL, network API, AI, child-process API,
source write or session-content logging was introduced in App/package sources.

Settings → Sources → Verify Access is a deliberately narrow M0 check: list each
root's immediate directory entries and display the count/status. It does not open
transcript contents, infer session counts, walk subdirectories or start ingestion.
The real account home is resolved by read-only `getpwuid_r`; sandbox-container home
is not mistaken for the user's agent root. Grant access again pre-navigates an
NSOpenPanel with hidden directories visible, requires the listed directory, creates
an **app-scoped read-only** bookmark, and saves it only in the app database.
Verification resolves the bookmark, detects staleness and balances scoped access.
Nothing reads source directories automatically at launch. Full source lifecycle and
launch-time bookmark health refresh remain M2 work.

The UI smoke test's `--synthetic` launch uses a unique temporary app database and
does not even resolve default agent roots. It has not been run. No app was launched
against real source directories during this task.

Figma design context/screenshots for Sessions `11:2624` and menu panel `31:847`
were read using the `figma-design-to-code` guidance. Native SwiftUI/system controls
are used for the empty M0 shell; populated rows/charts/prototype image assets are
outside this task. **No rendered app-to-Figma comparison has run**, including
960×600, 1120×720 and 1440×900, dark/light modes.

## Commands and observed results

Environment: `swift --version` reported Apple Swift 6.4.2, arm64 macOS 27.2 target;
`xcode-select -p` returned `/Library/Developer/CommandLineTools`.
`xcodebuild -version` failed with: `tool 'xcodebuild' requires Xcode ... active
developer directory ... is a command line tools instance`.

Reproducible package command setup, run from this worktree:

```zsh
m0_tmp=/private/tmp/agentdash-m0-foundation
mkdir -p "$m0_tmp/tmp"
m0_swift_args=(
  --package-path Packages/AgentDashKit
  --scratch-path "$m0_tmp/scratch"
  --cache-path "$m0_tmp/cache"
  --config-path "$m0_tmp/config"
  --security-path "$m0_tmp/security"
  --disable-netrc --disable-keychain --disable-sandbox
  --explicit-target-dependency-import-check error
)
env TMPDIR="$m0_tmp/tmp" CLANG_MODULE_CACHE_PATH="$m0_tmp/module-cache" \
  swift build "${m0_swift_args[@]}"
env TMPDIR="$m0_tmp/tmp" CLANG_MODULE_CACHE_PATH="$m0_tmp/module-cache" \
  swift test "${m0_swift_args[@]}" \
  -Xswiftc -plugin-path \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

`--disable-sandbox` here disables only SwiftPM's nested build-tool sandbox, which
this worker environment cannot create; it does not change the app sandbox or the
worker's filesystem restrictions.

| Check actually executed | Result / evidence under the task temp directory |
|---|---|
| Package dependency resolution | Passed, exact GRDB 7.11.1, local isolated cache/security/config paths, credential lookup disabled. |
| `swift build` using the arguments above | Passed; `package-build.log`. CLT emitted missing developer framework search-path linker warnings. Not a warning-free Xcode build claim. |
| `swift test` with explicit Testing plugin path | Passed: **13 test functions**, including **20 parameterized tokenizer cases** (32 individual invocations); `package-tests-final.log`. Coverage includes fresh/reopened WAL DB, v1 tables/FKs, source settings, stable dedupe IDs, copied-history ownership, token correction, rollback, checkpoint atomicity, parser-version preservation, ordering, and FTS insert/update/delete/cascade integrity. |
| App model/probe/views `swiftc -typecheck` in Swift 6 strict mode | Passed with no diagnostics after correcting an unused Task result; `app-views-typecheck.log`. Excludes App entry and XCTest source. |
| Synthetic source-probe executable | Passed: readable top-level count, missing path, invalid bookmark, unchanged synthetic file bytes/mtime. `source-probe-harness`; source is `SourceProbeHarness.swift`. This is unsigned helper execution, not sandbox/bookmark acceptance. |
| `plutil -lint AgentDashboard.xcodeproj/project.pbxproj App/AgentDashboard.entitlements` | Passed. Project converted to `project.json` for reference/settings validation. |
| `swift package … dump-package` plus `python3 /private/tmp/agentdash-m0-foundation/verify-foundation.py` | Passed: eight-module graph, Swift/platform settings, single matching pin, exact entitlement plist, project/scheme references, EN/zh-Hans catalog, App SQL boundary, forbidden API scan and whitespace. This is a task-local static check, not the parallel worker's guardrail scripts. |
| `git diff --check` | Passed; added/untracked files also received the explicit whitespace check above. |

The App view/model typecheck command was:

```zsh
env CLANG_MODULE_CACHE_PATH="$m0_tmp/module-cache" swiftc \
  -typecheck -parse-as-library -swift-version 6 -strict-concurrency=complete \
  -target arm64-apple-macos27.0 -module-cache-path "$m0_tmp/app-module-cache" \
  -I "$m0_tmp/scratch/out/Products/Debug" \
  -F "$m0_tmp/scratch/out/Products/Debug/PackageFrameworks" \
  -Xcc -fmodule-map-file="$m0_tmp/scratch/checkouts/GRDB.swift/Sources/GRDBSQLite/module.modulemap" \
  App/SourceAccessProbe.swift App/DashboardModel.swift App/MainWindow.swift \
  App/SettingsView.swift App/MenuBarPanel.swift
```

Development failures resolved or bounded:

- Nested SwiftPM sandbox initially failed `sandbox_apply: Operation not permitted`;
  the command-local SwiftPM flag above allowed package compilation without global
  changes.
- Initial Swift Testing expectations inside otherwise nonthrowing GRDB closures
  needed explicit `throws -> Void` closure signatures; fixed.
- Default CLT incremental SwiftBuild lost Testing macro discovery. Explicit
  `-plugin-path …/plugins/testing` restored repeatable test execution. A native
  build-engine fallback was also tried: it first lacked `Testing`; adding CLT
  framework/plugin paths ran tests but is not the final recommended command.
- An initial FTS update test reused the alias `tool` in old/new camelCase names;
  colocated synonym matching correctly matched both. Independent lowercase
  sentinels now test stale-index removal; identifier behavior has separate tests.
- Whole-App CLI typecheck reached `@State` but failed because this CLT installation
  lacks `SwiftUIMacros.StateMacro`. No compatibility branch or substitute toolchain
  was added. Full App build remains pending Xcode 27.

## Coordinator integration and remaining acceptance

1. Review the uncommitted additions, then integrate the reviewed tooling through
   the coordinator's process. `Tools/` is absent in this branch; neither
   `Tools/forbid-apis.sh` nor `Tools/check-entitlements.sh` was available to run.
   No GitHub publication was attempted.
2. Record the small schema extension in shared SPEC/DECISIONS: `source_files.last_seq`
   and `previous_ts` persist file ordering/timestamp inheritance across restarts.
   They are the only additional columns beyond SPEC §6.3. Shared docs were left
   untouched under ownership rules. FORMATS needs no parser-format update in M0.
3. After the owner installs/selects Xcode 27, resolve the exact lockfile with an
   isolated package cache and run the real app build/UI test commands, for example:

   ```zsh
   xcodebuild -project AgentDashboard.xcodeproj -scheme AgentDashboard \
     -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath /private/tmp/agentdash-m0-foundation/DerivedData \
     -clonedSourcePackagesDirPath /private/tmp/agentdash-m0-foundation/xcode-packages build
   xcodebuild test -project AgentDashboard.xcodeproj -scheme AgentDashboard \
     -destination 'platform=macOS,arch=arm64' \
     -derivedDataPath /private/tmp/agentdash-m0-foundation/DerivedData \
     -clonedSourcePackagesDirPath /private/tmp/agentdash-m0-foundation/xcode-packages
   ```

4. Select the owner's signing team without expanding entitlements, check the
   **actual signed .app** with the reviewed guardrails, and test Sources → Verify
   Access for each default root. If denied, grant its directory via NSOpenPanel,
   verify again, quit/relaunch and verify persisted bookmark resolution. Record
   counts/status only, never raw transcript text. Real-source runtime verification
   belongs to the coordinator/owner; this worker used only synthetic data.
5. Render the empty shell at 960×600, 1120×720 and 1440×900 in dark then light mode,
   including window restoration, closing/reopening via the menu panel, settings,
   localization and synthetic UI smoke. Compare geometry against Figma. App launch,
   UI, signed sandbox exceptions, valid security-scoped bookmark persistence and
   manual zero-network observation are all **unverified**.
6. Do not mark M0 accepted until those checks pass. No NFR, adapter, live ingestion,
   pricing, full search or real-session accuracy result is implied by these tests.
