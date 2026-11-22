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

## DEV-049 — Save source settings without changing access

The editor updates only the source name, environment label, path mappings and
Codex profile rules. Compare the edited fields byte-for-byte before writing;
a permission re-grant is independent and its latest bookmark is preserved.
Re-granting updates only access fields for the same source identity so a
picker opened before a settings edit cannot overwrite that edit. Reject a
stale editor rather than overwriting newer configuration. Validate changed
mappings and rules without opening any paths. Existing sessions and
checkpoints are unchanged; saving does not rebuild the index.

## DEV-062 — Read session usage and costs from committed quotes

Observe the selected session's token and quote rows for the detail facts.
Show the cache-inclusive total and the sum of available estimates;
identify missing and approximate quotes. The overview's chart is separate
and bounded to 72 timestamp buckets. These reads include archived
sessions and do not touch original files or price tables.

## DEV-061 — Keep sidebar filters separate from displayed query text

Filter the session library by its indexed agent, environment or status.
An environment's displayed label is masked; its byte-exact identity is
used only for local filtering. Apply the same scope in search and match
navigation and preserve it when saving a Smart Group. Session metadata
without transcript events is still eligible for the filtered list.

## DEV-060 — Sort complete search matches before paging

Rank matching sessions by relevance, last activity or recorded total
token volume before taking a page. Count cache-inclusive input and output,
without adding reasoning again. Only volume-sorted searches refresh on
usage-only changes. Persist the order with Smart Groups; old rows retain
relevance.

## DEV-059 — Keep Smart Groups as live local searches

Save the named query in the existing app-owned saved-search table. Opening
a group starts the ordinary search with its original syntax and current
scope rather than persisting result rows. Sidebar labels use the display
masker. Removing a group removes only its configuration row.

## DEV-058 — Remove a source without deleting indexed sessions

Stop and await the source worker before marking its registration removed
and forgetting its bookmark. Retain the row, settings and checkpoints so
its existing library remains readable. Default installation leaves the
removed row alone; explicitly choosing the same agent and directory path
with a fresh grant restores it. Exclude removed sources from source
diagnostics and reject further ingest batches.

## DEV-057 — Start first-run indexing only after source selection

The first-run preview discovers filenames through the same authorization
as the indexer. Only supported sources with session files are selectable.
Setup completion is recorded before starting the selected workers. Users
can continue without indexing, and an existing library skips setup.

## DEV-056 — Reconcile Copilot usage inside the ingest transaction

Use producer event IDs and preserve the first occurrence. Reconcile the
per-model cumulative samples with call-level rows by file sequence; only
uncovered usage becomes a coarse token row. Ignore child usage and stale
decreases. Apply pricing to the final rows with the same quote mechanism
as other agents. Discover from the already-authorized root only.

## DEV-055 — Tie context usage to the measured request

Keep the measured input, model ID and recorded capacity together.
Settings → Thresholds stores optional model-prefix capacities in app
UserDefaults. Source-reported capacity wins; use the longest literal
prefix only as a fallback, and leave the ratio unknown without both
values. Changing fallback rules updates the detail without reindexing.

## DEV-054 — Share usage redlines between usage surfaces

Save per-agent redlines atomically in the app index, using the existing
usage-limit keys. A blank field clears that agent's value. Observe redline
settings separately from the time-series revision so editing a redline
updates the guide and headroom without rebuilding historical usage.

## DEV-053 — Reevaluate indexed status when thresholds change

Store status threshold preferences in app UserDefaults. The owned index
records the policy it reflects; a changed policy invalidates the previous
deadlines and prevents an older evaluator from overwriting new results.
Changing or resetting thresholds does not reread raw sources.

## DEV-052 — Read menu data only while the panel is open

Use the owned index for a committed snapshot of local-day totals, the
trailing 60 seconds of call-level usage, headroom and at most six active
sessions. Match the current display time zone. Refresh on index commits
and every five seconds while the native panel is visible. Reuse chart
buckets; the menu does not read raw files or retain a closed panel snapshot.

## DEV-051 — Refresh status from committed evidence

Infer a session’s status from the latest 8,192 indexed evidence rows,
without loading transcript text or inspecting processes. Committed event
changes schedule a refresh; use one timer for the nearest remaining
transition, with no idle polling. Reject a stale evaluation if its event
revision changed. An archived file does not establish a successful end.
Hover shows the reason, including the qualification on inferred approval.

## DEV-050 — Replay sources without resetting their checkpoints

An explicit rescan ignores the resume position for this pass while keeping
the saved checkpoint for the writer's race check. Live watchers serialize
replay with incremental work; a stopped source does not start watching.
Record the time of a completed discovery pass. Replay uses existing access
and dedupe keys, and does not clear archived sessions or stored quotes.

## DEV-032 — Guard index rebuild from incomplete usage history

Settings → Storage shows the app-owned database and sidecar size. Rebuild
search, usage and masked topic projections atomically from local indexed
records. Refuse to replace totals the source rows cannot reproduce.
Do not open agent files or change stored events, checkpoints or prices.

## DEV-029 — Archive only confirmed missing transcript files

After a successful discovery or a known-file watch event, the reader confirms
an absent leaf under the pinned authorized root without following symlinks.
The store marks the file and its sessions only if the observed checkpoint
still matches. Keep transcript, search and usage intact. Absence invalidates
older ingest writers and forces replay even when a restored file has the
same inode and contents. A different session at the same path does not
unarchive the previous one.

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
If the saved path still identifies the selected directory, preserve that
spelling so startup discovery and Projects continue to recognize a default root.
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

## DEV-048 — Separate index status from directory access

Source diagnostics summarize committed app-index records. A file is counted
as indexed only after a checkpoint is persisted. Keep partial, missing and
error file counts separate; exclude prompt-history buckets from navigable
session counts. Show only a recorded scan timestamp and a typed error
indicator, never source modification times or raw stored error text.

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

## DEV-044 — Start indexing from an explicit source action

The Sources pane starts one in-process scan and watcher for the selected
registered Claude Code source; launching the app does not read sessions.
Keep bookmark access alive through both activities and release it after
Stop. Subscribe before discovery and coalesce byte-exact hints; unknown
paths and ambiguous events go through discovery before import. Reject a
replacement of the selected root, keep existing indexed history, and
resume from committed checkpoints on the next explicit start.

## DEV-041 — Local Codex port and immutable compressed rollouts

The Codex decoder persists per-file model, cumulative usage and tool call
context. Only usable preferred transcript messages displace fallback text;
the writer removes those fallback events and their search entries in the
same transaction. Treat compressed rollouts as immutable. Validate every
frame before replaying the pinned file with bounded memory. A complete
physical cursor skips an unchanged archive; an interrupted replay starts
over with the same dedupe keys. This draft and the associated format
observations remain local pending the established publication review.

Keep plain replay offsets and oversized-frame recovery independent of zstd.
Archive checkpoints retain physical bytes at EOF; decompressed positions
are not handed back as source offsets or legacy replay evidence.

## DEV-042 — Read live usage from committed rollups

The app's token ledger updates minute and hour projections with raw event
writes. Exact range edges still use individual events. Chart revisions let
the visible Usage page reuse unchanged buckets and refresh after commits.
Keep rates with each priced event so a later correction uses the original
quote. This local candidate bundles the checked static table, remembers the
last verified bytes, and fills only unpriced records in bounded background
batches. It does not install an external table or change already priced
history merely because a bundled file is replaced.
A correction to a Claude response moves both its owner and project; usage
and cached savings leave the old rollup while the stored rate basis stays.

## DEV-046 — Read the Overview from the owned index

A session Overview observes one bounded database snapshot. Prefer the
recorded summary, prompt, reply, file touches and command results. Rebuild
Claude assistant text by producer message ID across physical records when
available, and otherwise from the same physical record, before masking and
making an excerpt. Replaying a retained resume copy can fill a missing
message ID on a matching record UUID and owner without changing any other
stored event fields. The v7 local integration replays both earlier public
checkpoints and the previous private v6 checkpoint.
Use the newest actions across structured and normalized records.
Each structured row replaces at most one call by timestamp, exact payload
and tool kind so repeat calls and tool results survive.
Omit oversized fields rather than clipping before masking. Catalog topic
terms must occur in the masked sample and match this session via the same
literal query the chip starts. Searching still opens the
transcript, and the Overview does not read working directories or execute
commands.

## DEV-028 — No session export (owner confirmed 2026-11-20)

The owner removed Markdown/JSON session export from the product scope. Full
transcripts remain viewable in the app, and Copy Resume Command and Show in
Finder remain available. No entitlement change is needed.

## DEV-040 — Browse projects from the local index

Observe the Projects catalog only when the page is open. An indexed project
ID wins when provided. An otherwise unattributed local or explicitly mapped
host workspace can join a catalog project only at its unique host root.
Collapse worktrees for both sides of that identity; keep the recorded
catalog path for display. An unmapped environment stays scoped by source
and environment.
Recognize default local sources by registered root and environment, independently
of how access was granted. Normalize unambiguous absolute path spellings by byte
and collapse Claude worktrees to their repository root. Keep parent traversal
and exactly two leading separators literal and scoped; do not read the filesystem.
Prompt-history buckets stay searchable but are not navigable project sessions.
The timeline uses indexed event times and fetches text only for the bounded
recent set. Mask complete activity text before shortening it for display.

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
with at most one query running and one pending refresh. Transcript navigation
uses the same filter snapshot as the result list. Resolve the preferred hit,
ordinal and neighboring keys in one scoped read, ordered by sequence and
row ID. Search refreshes retain valid selected events and only reseek the
transcript when the selected event changes.
