# M0-TOOLING handover

2026-11-17. Branch `feat/m0-tooling`, worktree `.worktrees/m0-tooling`.
Both were verified before editing; the initial working tree was clean.
Scope: `Tools/` and this report only. This worker created no commit, push or PR;
the coordinator owns review and publication, including the separately published
baseline/branches. Requirement anchors: M0, SEC-1…8,
ADP-1…7, SPEC §12.1 / §14.4 / §15.2.

## Delivered

- `Tools/forbid-apis.sh`: production App/package source scanning, comment-aware
  inspection with strings retained, C splicing before comment recognition and
  original physical line mapping, Swift declaration/call separation, no per-line/file
  fixture suppression, no following production symlinks, no worktree/cache/prose
  scanning. Covers mandated symbols and common equivalent network/process/Apple
  Events/AI APIs plus Spotlight/CloudKit. Diagnostics omit source excerpts.
- `Tools/check-entitlements.sh <app>`: actual `codesign --verify --strict`, signed
  entitlement XML, exact four-key/five-path SPEC policy with boolean type checks,
  and actual Hardened Runtime signature flag. Missing/unsigned artifacts fail.
- `Tools/check-dependencies.sh`: only literal, exact-pinned official GRDB.swift;
  lock identity/location/kind/version/revision and all discovered lockfiles must
  agree. Rejects extra/local/registry/branch/range dependencies, duplicate JSON
  keys and computed/conditional/decoy manifests. No manifest execution/resolution.
- `Tools/fixture-capture`: explicit JSON/JSONL input/output with an optional full
  source boundary, read-only snapshot checks, fail-closed recursive sanitization,
  same-file/inside-source/symlink/hardlink/overwrite rejection, independent protected
  destination-root rejection (including symlink targets), descriptor-relative
  mode-0600 staging and exclusive publication. Digest `.sanitized` markers appear
  only after validation; failures roll back only this invocation's files.
- `Tools/tests/`: synthetic unit/CLI cases, including real codesign of disposable
  synthetic apps. `Tools/README.md` documents commands, exit codes, exact privacy
  policy, Unicode semantics and limits. Python standard library only.

## Verification

Tests were written before implementation. The first run failed with missing
`fixture_capture` / `guardrails` modules. Additional regression tests exposed C
identifier splicing, manifest-decoy matching, destination symlink replacement and
numeric credential handling; those cases were fixed before this handover.

Command run:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/tests -v
```

Final review result: **40 tests passed, zero skipped** (initial handover: 33), including:

- Allowed production-shaped code passes; mandated forbidden families and injected
  network/process/AI code fail. Comments and a production `Fixtures` directory
  cannot suppress actual use; prose/test/cache/other-worktree examples are ignored.
- Exact synthetic GRDB pin passes; an unapproved pin, range/branch, version or
  revision mismatch, dynamic/quoted declaration, duplicate/invalid lock fails.
  Synthetic `7.8.0` is test data, not selection of the real GRDB release.
- Existing CLT `clang` built a synthetic `.app` entirely under `/private/tmp`.
  Ad hoc signing with the exact entitlement set + runtime passed the actual CLI;
  network and unknown extra entitlements failed, unsigned app failed, missing app
  returned an unmet prerequisite. Pure tests also cover unavailable codesign,
  invalid/missing plist, wrong paths/types, missing keys and missing runtime flag.
- Capture leaves source bytes/inode/mtime unchanged; strips synthetic secret
  formats, credential metadata (including numeric passwords), paths and unknown
  string/key values; preserves hand-specified token numbers and ID relationships.
  CJK/emoji/combining marks/Unicode separators, synthetic timestamp intervals,
  deterministic repeated capture and digest matching pass.
- Same file, existing output/marker, nested destination, symlink aliases, dangling
  links, hardlinks, concurrent destination creation and parent-symlink replacement
  fail without overwriting user files. Malformed/partial/non-finite/duplicate-key
  input, source change, validation error and marker failure do not publish a marker.
- Every independent `.claude` / `.codex` / `.copilot` / `.grok` destination is
  rejected regardless of the input root, with no output, marker or staging files.
  Coverage includes direct/nested paths, ordinary symlink aliases to protected
  roots, protected-name symlinks pointing outside, chained aliases and case variants.
- Swift protocol/method declarations named `accept` pass, including comments,
  newlines and backticks around declaration syntax. Actual calls in bodies/defaults,
  repeated names, qualified/backtick calls and dynamic-name string literals fail.
- C `sys` + backslash-newline + `tem` and socket identifier splicing fail, with
  LF/CRLF coverage. Splicing precedes comment handling: continued/formed comments
  pass when they contain only prose, while real calls hidden by the old order are
  detected at their original physical line. C block comments do not nest; Swift's do.

All test inputs, including every agent-named directory, are synthetic and live
below task-specific `/private/tmp/agentdash-m0-*`. No real agent files, global
Codex config/memory/credentials were read. During coordinator review, the user
explicitly authorized reading Foundation's manifest/tokenizer and running the two
read-only guards against `.worktrees/m0-foundation`; no Foundation file was copied
or changed. No runtime/package was installed and no real fixture was captured.

Final hygiene also passed: `ast.parse` for all Python files, individual `sh -n`
for all four entrypoints, and `git diff --no-index --check -- /dev/null <file>`
for all 11 newly added files (exit 1 with no diagnostics is the expected new-file
diff result). All files have final newlines and no `__pycache__` was generated.

## Integration prerequisites and coordinator follow-up

This branch has no App, package or signed Agent Dashboard artifact. Tool checks
do **not** close M0 or prove runtime sandbox/network behavior. The default commands
previously exercised missing-prerequisite behavior on this branch (exit 2):

| Command | Observed result |
|---|---|
| `Tools/forbid-apis.sh` | Exit 2: no production `App` / `Packages/*/Sources` files exist |
| `Tools/check-dependencies.sh` | Exit 2: required package manifest and lockfile absent |
| `Tools/check-entitlements.sh /private/tmp/agentdash-m0-tooling-unbuilt/AgentDashboard.app` | Exit 2: built signed `.app` required |

After the review fixes, the authorized read-only integration commands produced:

| Command from `.worktrees/m0-tooling` | Observed result |
|---|---|
| `Tools/forbid-apis.sh --root ../m0-foundation` | Exit 0: 18 production source files inspected; tokenizer declaration accepted |
| `Tools/check-dependencies.sh --root ../m0-foundation` | Exit 0: GRDB.swift exact 7.11.1, lockfiles consistent |

The dependency guard's literal-only policy was not broadened. Foundation initially
had a separate `let strict` constant; its owner handled the settings inlining.
The passing result above is the observed post-change state. This worker did not
run Foundation package tests, app builds/UI checks, signed source-directory
access/bookmark fallback or release network observation; those remain coordinator
integration/acceptance work. Rerun both guards on the final combined head.

Before adapter capture, review the sanitizer and the proposed conventions below;
then run real capture locally in the later adapter task. The coordinator can
incorporate accepted conventions into shared DECISIONS/FORMATS/SPEC. Those files
were intentionally not edited in this ownership boundary.

- Same-length text means Unicode code points, not Swift graphemes or UTF-8 bytes.
  Paths have a minimum synthetic-prefix length; timestamps use a synthetic origin.
  Numeric accounting is exact; credential subtrees are redacted; other numbers
  need privacy review. Markers explicitly require human review.
- New schema keys default to pseudonyms, never pass-through; new enum strings
  default to masked text. Review allow-list additions with fixtures. Provider,
  model and version strings are masked; argument JSON/commands/patches are opaque
  text. Specialized parser syntax must use synthetic fixtures as needed.
- Capture handles a stable uncompressed file, not whole roots, SQLite, YAML or
  `.jsonl.zst`. It does not weaken the later compressed-fixture review gate or add
  a zstd dependency. JSONL capture rejects malformed/half-written records even
  though the eventual ingestion parser must tolerate them.
- Dependency validation deliberately accepts a narrow declarative manifest. If
  Foundation's legitimate syntax differs, coordinate a reviewed guard change;
  do not bypass the check. Remote tag authenticity, vendored zstd licensing,
  source-write/privacy data flow and computed runtime API names remain review work.

Suggested coordinator PR title: `feat(M0): add SEC guardrails and safe fixture capture`.
Keep signed-app and final combined-head acceptance pending until executed.
