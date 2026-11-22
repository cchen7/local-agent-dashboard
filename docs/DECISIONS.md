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

## DEV-047 — Register a custom source without replacing an existing one

Sources → Add Source records the agent, label, environment and read-only
permission after an explicit local folder choice. Read directory metadata
under that authorization. The store atomically checks agent, persistent
volume UUID, inode and directory creation time. An older row without stored
identity can match by its existing authorized directory. If the selected
folder occupies a registered pathname but does not match that source's
identity, report a path conflict. Check the current occupant separately from
the saved bookmark so aliases of the replacement also report a conflict.
Both outcomes leave the existing permission, configuration, checkpoint and
history intact. Registration does not read session files or start indexing.

Grant access again uses the same directory identity. Update a renamed
original in place and keep its identity, checkpoints and session history.
For a legacy custom source, require the old bookmark to resolve without
staleness to the same directory; a path match alone does not prove that.
A default source with no prior bookmark remains defined by its configured
path. The write checks that the source's saved path and permission still
match the snapshot used to grant access.

## DEV-038 — Commit JSONL batches against the expected checkpoint

Read the expected checkpoint before opening the pinned, read-only source
descriptor, then read the file up to its observed size. Preserve
newline byte offsets and keep at most a 1 MiB prefix of a physical line.
The adapter normalizes complete lines; record writes, decoder state and the
checkpoint share a transaction that rejects stale readers. A changed
device/inode, shrink, same-size modification, or parser version causes
replay with the adapter's existing dedupe keys. Older indexed records are
retained for the archive. This implements the common importer without
assuming any vendor's record format.

## DEV-039 — Normalize Claude Code files before indexing

Enumerate the authorized root descriptor without following symlinks. Use the
primary filename for file metadata and a valid recorded session ID for event
and usage ownership. A resumed copy can establish an original owner without
claiming its file or overriding an original event's order. Usage still merges
only compatible cumulative output into one billable response. A nested
subagent keeps its own records and resolves its parent when available.
Thinking stays outside the index. For oversized records, read the remainder
in bounded chunks from the pinned descriptor and retain only recognized tool
results with their identity and up to 2 KiB shared across each result’s text
blocks. Discard unrelated payloads as they are read. Successfully recovered
results do not count as unknown; malformed or unclassified records keep an
unknown marker without a raw fallback. During a v2-to-v3 replay, replace only
an empty marker that v2 would have emitted for the same committed file prefix.
Carry that boundary in decoder state until replay reaches it. The replacement
and checkpoint commit together. Keep archived, nonempty and unrelated rows.

## DEV-028 — No session export (owner confirmed 2026-11-20)

The owner removed Markdown/JSON session export from the product scope. Full
transcripts remain viewable in the app, and Copy Resume Command and Show in
Finder remain available. No entitlement change is needed.

## DEV-036 — Observe indexed sessions and one transcript page

The Sessions view observes committed metadata and the selected 128-record
transcript page separately. A moved or deleted paging anchor, or an older/newer
page emptied by a rewrite, restarts the transcript from the first page. Mask
display values before formatting; raw transcript data stays in the app's index. An explicit
reveal applies to one entry and expires after ten seconds, when the entry
leaves the view, or when the app loses focus. Markdown does not open links or
load images from transcripts.

## DEV-037 — Use the app-owned index for grouped search and navigation

Compile the query tree to literal FTS operands and bound SQL arguments. Keep
ranking and the first match in file order separate. Fetch text only for the
displayed 50-group page in the same read snapshot, then mask complete values
before cropping snippets. Full-text reads may use a reader-local 64 MiB
SQLite mapping to avoid copying hot pages. Dates use the display time zone;
`after:` includes the start of that local day and `before:` excludes it.
Directory filters compare whole components of recorded paths; the host
home is used only for `~/`. Observe commits to every table read by search,
including edits that change only event text. Refresh the same query and offset
with at most one query running and one pending refresh.
