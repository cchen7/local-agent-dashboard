# M2 — Pure path-mapping primitive

## Scope and baseline

FR-SRC-1, SEC-3, SPEC §5.1 / §15.1 / Appendix C. Scope is the pure ADCore
primitive and its synthetic tests.

The implementation belongs to ADCore. It does not integrate ingestion or the App,
open source paths, generate resume commands, or inspect actual session roots.
`PathMapping` keeps its existing `from` / `to` stored fields and synthesized
Codable representation. Its initializer still preserves both strings verbatim.

## API

```swift
let hostPath = try PathMapper.map(
    "/workspace/api/Sources",
    using: [PathMapping(from: "/workspace", to: "~/code")],
    hostHome: "/synthetic/home"
)
// /synthetic/home/code/api/Sources
```

`PathMapper.map(_:using:hostHome:) throws -> String` is stateless and uses only
Swift string/byte operations. `hostHome` defaults to `nil`; there is no ambient
home lookup, filesystem read, shell expansion, URL standardization or symlink
resolution. The result is a display/future copy-resume path, never a path for
opening a source or evidence of source authorization. Future resume-command
generation must supply its own shell quoting.

`PathMapper.Failure` distinguishes unsupported input (`invalidPath`), invalid
rule fields (`invalidFrom(ruleIndex:)`, `invalidTo(ruleIndex:)`), missing home
(`hostHomeRequired(ruleIndex:)`), invalid explicit home (`invalidHostHome`), and
conflicts (`ambiguousRules(firstIndex:secondIndex:)`). Rule indices are zero-based;
errors carry no path strings or underlying errors.

## Proposed lexical semantics and tradeoffs

- Match the longest complete component prefix, comparing UTF-8 bytes exactly.
  Matching is case-sensitive and does not fold Unicode spellings. Rule order
  cannot select a different output. Mapping is applied once, without chaining.
- Accept absolute POSIX paths and root `/`. Ignore trailing separators on rule
  fields and explicit host home. Join source/destination roots without a doubled
  slash. A matched input ending in separators retains one trailing `/`, except
  when the result is root. Valid unmatched paths are returned byte-for-byte.
- Only a destination starting with `~/` can expand, and only with an explicit,
  valid absolute `hostHome`. Bare `~` and `~user` are unsupported. An unused home
  argument is ignored. `$HOME`, globs, backslashes, spaces and shell syntax inside
  absolute components remain literal.
- Reject empty/relative paths, NUL, `.` / `..` components, leading `//`, and
  repeated internal separators. These cases are not silently standardized;
  callers must handle failure explicitly. This deliberately supports less than
  all possible filesystem path spellings without guessing their meaning.
- Validate the entire rule set before mapping, including unmatched rules. A bad
  longer rule cannot fall back to a shorter prefix. Equal sources after trailing
  separator trimming with different effective destinations fail even when
  unmatched. Duplicate rules with byte-identical effective destinations are
  harmless, including duplicates made equivalent by explicit home expansion.
  Other overlaps are resolved by longest prefix. No filesystem alias equivalence
  is inferred.
- Validation uses a simple pairwise duplicate check and runs on each call;
  matching is linear in rule count. This favors a small auditable primitive for
  source settings over a reusable compiled-rule cache or additional abstractions.

Per `docs/DEVELOPMENT_PLAN.md`, shared SPEC/DECISIONS/FORMATS incorporation remains
with the coordinator. This report records the proposed clarifications. No source
format or adapter changed, so no real fixture capture was needed or performed.

## Observed verification (2026-11-19)

Apple Swift 6.4.2, arm64, macOS SDK 27.2, command-local
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- Targeted Swift tests exited **0**: **35 test functions** passed, no failures or
  skips. The **19 new PathMapper functions** include **69 parameterized rows**,
  plus explicit assertions/loops for all rule orders, conflict handling, literal
  Unicode/metacharacters, one-pass mapping and exact Codable compatibility.
- No compiler warnings or errors were emitted.
- `Tools/forbid-apis.sh`: exit **0**, 24 production source files inspected.
- `Tools/check-dependencies.sh`: exit **0**, exact GRDB.swift 7.11.1 and consistent
  lockfiles; no dependency or package/lockfile changes.
- `git diff --check` and whitespace checks of the new files passed.

The focused suite passed in both an isolated ADCore-only package and the
repository package using its existing pinned dependencies. SHA-256 comparisons
verified the source and tests in the isolated copy. No installation was needed.

The scratch manifest contains only these targets, with no products or dependencies:

```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ADCorePathMappingVerification",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "ADCore", swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]),
        .testTarget(name: "ADCoreTests", dependencies: ["ADCore"],
                    swiftSettings: [.enableExperimentalFeature("StrictConcurrency")])
    ],
    swiftLanguageModes: [.v6]
)
```

Build products, SwiftPM caches and synthetic test files stay in a task-local
scratch directory. With `verify` set to that directory, run the focused
repository package tests:

```sh
CLANG_MODULE_CACHE_PATH="$verify/clang-module-cache" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test --package-path Packages/AgentDashKit \
  --scratch-path "$verify/swift-build" --cache-path "$verify/swift-cache" \
  --config-path "$verify/swift-config" --security-path "$verify/swift-security" \
  --manifest-cache local --disable-sandbox --disable-netrc --disable-keychain \
  --filter ADCoreTests
```

This verifies ADCore compilation and behavior, not full-package integration or App
acceptance. The complete package and App UI checks are outside the scoped pure
primitive. No App edits, GUI or session-root reads were needed.
