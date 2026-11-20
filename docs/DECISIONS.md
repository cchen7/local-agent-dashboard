# Implementation decisions

SPEC §17 remains the source for confirmed product decisions D-1…D-10. The entries
below record development decisions and explicitly approved clarifications.

## DEV-001 — Worktrees and ownership (2026-11-17)

Keep the main checkout on `main` for coordination/review. Each coding task gets a
separate branch and linked worktree under ignored `.worktrees/`. The owner initially
selected manual handover, then explicitly requested coordinator-launched standard
Codex `gpt-6.1-sol` workers. The coordinator owns EXP-1 and merges reviewed PRs.
No global config, runtime installation or automatic worktree cleanup is authorized.

## DEV-002 — Status precedence (owner approved 2026-11-17)

SPEC §10.4 originally let `running` win over a pending tool's >15-second waiting
condition. The owner approved: error → explicit session end → waiting for input →
running. Inferred pending-tool approval is labeled "possibly needs approval";
file silence is not proof of an approval request. Old terminal events cannot
override later resumed activity. The corrected rules are in SPEC §10.4.

## DEV-003 — Initial missing full Xcode (resolved 2026-11-17)

At bootstrap only Command Line Tools was selected. The owner subsequently installed
Xcode 27.2; actual build, signed access and UI evidence is recorded in the M0 report.
Command-local `DEVELOPER_DIR` selects it without changing the global selection.

## DEV-004 — Store owns FTS registration (2026-11-17)

The `agentdash` tokenizer is referenced by M0's schema, while ADSearch depends on
ADStore. Keep GRDB registration in ADStore and any shared pure splitting in ADCore,
so migrations can run without a dependency cycle. M3 still owns the full search
syntax, ranking, snippets and UI. The required CJK behavior is not weakened.

## DEV-005 — Standard Codex workers (2026-11-17)

Fresh subagent model override inherited the coordinator's `astra_foundry` provider.
Use separate ordinary `codex --no-daemon exec` processes with `gpt-6.1-sol` and the
locally verified ordinary provider `azure`, with each cwd set to its assigned
worktree. A completed preflight verified provider/model, successful commands and
normal exit (FORMATS.md). The owner explicitly approved transmitting project
instructions, code and necessary tool output through the existing standard proxy;
raw agent-session content and credentials are excluded. Global config is unchanged.

## DEV-006 — M0 storage baseline (2026-11-17)

Pin the already-approved GRDB.swift dependency exactly to 7.11.1, revision
`b83108d10f42680d78f23fe4d4d80fc88dab3212`; keep the package and Xcode lockfiles
identical. The v1 migration adds `source_files.last_seq` and `previous_ts` so file
ordering and timestamp inheritance survive an incremental restart (ADP-2/5).
These fields are now included in SPEC §6.3. Same-session dedupe conflicts update
the existing row; copied events/tokens keep their first session owner instead of
moving old history to a resumed session. Full inheritance display and aggregate
maintenance remain later milestone work.

## DEV-007 — Local Xcode validation signing (2026-11-17)

The owner installed and initialized Xcode 27.2. Use command-local `DEVELOPER_DIR`
to select it; no global developer-directory change is needed. For local M0 checks,
build with ad-hoc signing, then explicitly sign the App with the frozen entitlement
plist and `--options runtime`, and inspect the actual signature. Xcode otherwise
omits Hardened Runtime for ad-hoc builds and testing builds add test entitlements.
App Debug uses `ENABLE_DEBUG_DYLIB=NO`: the separate debug dylib was rejected by
library validation in a real launch. No library-validation exception is added.
`LM_SKIP_METADATA_EXTRACTION=YES`, verified on Xcode 27.2, skips unused AppIntents
metadata work without adding a framework or broadly suppressing warnings.
Developer ID distribution/notarization remains the separate D-8/M5 requirement.

## DEV-008 — Grok unavailable on this Mac (owner confirmed 2026-11-17)

The owner confirmed Grok is not installed and asked to ignore it for now. Treat its
missing default root as an unavailable source, not a permission failure; it does
not block the current local M0 access check. Do not install Grok, create its source
directory, or fabricate observed fixtures. Local Grok capture/validation is deferred
until an actual source is available; retain the adapter extension point.

## DEV-009 — Native visual review without runner recording access (2026-11-17)

The owner explicitly approved the existing Codex Computer Use capture route for
synthetic App windows. XCTest verifies interaction and native geometry; the
authorized tool captures the real windows for Figma review. The test runner does
not request recording permissions. An opt-in serialized handoff permits captures
between geometry assertions, with acknowledgments only after image inspection.
On this desktop the menu entry was visible to the owner but unavailable in the
XCTest hierarchy. The explicit manual-entry mode still requires the real Dialog,
its 360-point width, and successful Open Dashboard assertions. A skip alone never
satisfies that acceptance check; the assisted case was executed and passed.

## DEV-010 — Native outer-window sizing (2026-11-17)

SPEC window sizes include native chrome. SwiftUI content minima alone produced a
960×652 outer window. A narrow AppKit bridge measures settled native chrome and
converts the 960×600 outer minimum to content constraints without a fixed toolbar
height. Its state belongs to window content; unchanged native values are not
reassigned. All six size/appearance combinations were executed and visually checked.

## DEV-028 — No session export (owner confirmed 2026-11-20)

The owner removed Markdown/JSON session export from the product scope. Full
transcripts remain viewable in the app, and Copy Resume Command and Show in
Finder remain available. No entitlement change is needed.
