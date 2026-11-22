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
quote. The app reads the authorized external file or the bundle, keeps the
last verified bytes in its own index, and fills only unpriced records in
bounded background batches. A malformed edit cannot replace the active
rates or change an existing historical estimate. Keep the currency choice
with the app's presentation settings; the stored ledger stays in micro-USD.
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

## DEV-031 — Separate display masking and live index redaction

Display masking starts on and does not change stored text. Index redaction
starts off and asks before updating existing local text; later writes use the
same rule inside the writer. Preserve normalized identity and accounting;
pseudonymize recognized credential-shaped call and message links consistently.
Clear derived keywords after redacting underlying text. Preserve safe decoder
state unchanged and replay after omitting unsafe state. The guarantee covers
live searchable text rather than prior backups, SQLite free pages, or the
original source files.

## DEV-063 — Enforce workspace exclusions in the writer

Compile rules before applying them. Compare policy revision and checkpoint
on file commits. Match raw or mapped paths, retaining only session-key
fingerprints and file references as exclusion bookkeeping. A copied-history
placeholder cannot establish a workspace. Delete only confirmed matches
and publish usage changes with the index transaction. Invalidate only affected
checkpoints on rule changes and replay missing-workspace prefixes when trusted
metadata arrives. Stop active indexing before changing the rules. Do not
start stopped sources automatically.

## DEV-064 — Opt in to readable Claude thinking

Require explicit confirmation and stopped workers before changing the setting.
Enable marks only still-present Claude transcript checkpoints for replay on
the next scan; it does not start a reader. The index writer also enforces
consent and size limits. Disabling removes indexed thinking rows, including
archived copies. Leave source files, token usage and preserved reply rows
unchanged. Never store signatures, opaque blocks or partial thinking text.

## DEV-065 — Verify a confirmed manual clear against current index ownership

Clear scopes are an app-owned transaction. Recompute project membership and
check stable session and file identities before applying a confirmed plan.
Keep other session data and shared references; reset only affected file
checkpoints without starting a scanner. Scope clears subtract attributed
usage. Clear everything also removes aggregate-only legacy history and
rate limits. The source registry, preferences and saved searches survive.
Manual clear is separate from expiry, which must keep aggregate history.

## DEV-066 — Expire archived content while retaining attributed usage

Only a confirmed archive date ages into retention. Expiry deletes transcripts
and raw usage rows in one transaction and adds detached numeric totals at
identical timestamps. Keep source/workspace attribution for exclusions and
scoped clears; store only fingerprints to block replay of expired content or
already retained global token keys. Full rebuild and partial-minute reads
consult the retained amounts. Retention starts off (forever); explicit clears
remove retained usage for their scope as well as the reimport fingerprints.

## DEV-067 — Keep indexed previews, archives, and source reads separate

Tool results keep a two-KiB search preview. Store a complete body only if both
its decoded size and compressed size fit policy. Read a verified original
only on explicit request, using recorded line identity and the current
read-only source grant. Bound source display to 256 KiB; omit record locators
for over-limit lines. The viewer identifies truncation and never stores a
fetched source body. Index-time redaction applies to archives and source
previews. Lower limits remove only over-limit archives, not originals.

## DEV-068 — Copy resume text and reveal only the verified session record

Use the stored workspace and the source's current path mappings for Copy Resume
Command. Keep the environment reminder fixed so source metadata cannot change
shell syntax. Prompt histories and subagents do not supply resume IDs. Show in
Finder uses the existing read-only grant and the indexed file's device and
inode, plus the registered directory identity when available. Associate the
identity with the session when ingest confirms it, so reusing the same path
for a different file cannot retarget an older session. Existing indexes
confirm associations on the next authorized scan; migration does not read
source files. Neither button acts on an archived session or a removed source.

## DEV-069 — Use status evidence for live session activity

Derive the activity bar and status from the same committed evidence. Show the
most recent eligible unmatched call and its elapsed time; a recorded turn end
shows that the turn finished. A newer event, late result, archive or status
deadline invalidates the prior action. Show input for known shell tools only.
Apply the display masking policy before shortening it, and omit potentially
truncated command input. The timer is display-only; it never queries the
filesystem, process table, or index.

## DEV-070 — Fold tool results at their call without moving search evidence

Index the bounded normalized tool ID, using existing event metadata. Fold only a
unique call and following result in the same session. Child records lacking a
stable stream ID stay separate. Keep up to one result preview alongside each
visible call, skip folded results in both paging directions, and anchor result
search hits at the call. Keep the original event keys and indexed search data.
On explicit expansion, use the existing output archive and verified original
read. Mask whole available fields before excerpting, and flag input when only
its indexed preview is available.

## DEV-071 — Read original tool input by verified record, on request

Track the file and digest of a tool record when Claude's summary omits its
argument object or when a Codex or Copilot preview is clipped. A source replay
can add the locator without storing the original argument body. An explicit
read uses the current source grant and checks the pinned file, exact line and
boundaries. Show at most 256 KiB of complete input after applying the privacy
policy; do not show malformed JSON fragments or follow paths printed by tools.
Discard read bodies when the view closes. Retain an honest preview if the
original is gone or exceeds the limit.

## DEV-072 — Project typed tool actions from their indexed event identity

Store bounded action evidence with the deduplicated event. Maintain a
per-event file target ledger and incremental path/operation rollups in the
same write transaction. Unknown edit counts stay unknown and are never
treated as zero when aggregating. Use the event reference for each command.
Read outcomes by the specific same-session call ID and source sequence;
require a unique call and a unique later typed completion. Do not infer
paths from shell text, success from output prose, or a duration from time gaps.
Privacy redaction reprojects these same facts without keeping raw shadow rows.

## DEV-073 — Use the same typed facts in the multi-agent project timeline

Use the session overview's indexed proof for command outcomes and the original
event's file ledger rather than project-wide file counts. Rank eligible events
by timestamp and event ID before fetching content. Keep the original call time
and origin session when a late completion changes its status. Elide empty
wrappers only when a unique visible call covers them. Show up to three file
targets per event with a count of the remainder, and preserve separate result
text or unresolved entries. Apply the normal masking policy before excerpting.

## DEV-074 — Scope project charts to membership and retained identity

Build the project usage list and the selected chart from one consistent
snapshot. Use canonical live session membership and retained scope
fingerprints, never a display path or the unclassified catalog bucket.
Batch list totals in SQL; only draw the selected project's chart while
the Usage tab is visible. Exact half-open bounds and current display
zone drive the existing UsageWindow buckets. Keep cache inclusive totals,
stored quote amounts and unknown price disclosure. Include undated records
only in All totals. Retained-only projects show numeric history without
bringing back expired sessions. Refresh on observed index changes; no
periodic polling is required.

## DEV-075 — Save project pins by durable identity and reveal confirmed host paths

Use app-owned preference fingerprints for pins. Workspace and retained identities
use the retained fingerprint; catalog projects include their stable catalog key
rather than an integer row number. Pins do not store raw project paths. Recheck
the selected identity inside the write transaction. The list keeps its existing
activity order within pinned and unpinned groups.

Finder needs a current source-backed host path or an explicit mapping, not a
remote path with similar spelling. On click confirm the catalog target again,
walk only directory metadata without following symlinks, and reject known
remote or automounted paths before opening them. Hand the verified directory
to Finder without requesting a new grant or launching a shell.

## DEV-076 — Refresh deterministic topics from changed indexed documents

Queue only changed indexed conversations or distinct touched paths. Compute
off the ingestion writer from complete logical messages and known file names,
then apply only if the queued revision still matches. Keep per-session term
counts and exact document frequencies with cascading updates. Manual rebuild
uses the same ledger. Privacy changes invalidate counts and queue fresh masked
work. A session still being refreshed does not display outdated computed
labels. Rank with the existing TF-IDF rule, return at most five distinguishable
labels with literal search proof, and aggregate project labels only from a
current canonical member scope. Cap candidate reads, assembled message sizes,
and the distinct term set; use no polling while idle.

## DEV-077 — Group visible session rows with the Projects identity

The grouping preference is app-owned and starts off by default. Observe the
existing project catalog only on the Sessions page while grouping is enabled.
Use the canonical project ID, never the masked header name or raw workspace
text. Form sections from the already-ordered current rows; group order follows
the first hit, with original activity or relevance order within each section.
Missing project metadata keeps a visible row under Ungrouped. Retain search
and sidebar scope rather than changing the query or paging. Mask complete
heading fields before display, and fall back to the flat list if unavailable.

## DEV-078 — Read the same committed usage in Sessions rows and detail

Backfill one summary per session from the app-owned token ledger. Maintain
the summary in the same transactions as token inserts, corrections, ownership
transfers, quote backfill, and deletes. A background quote batch updates
each affected session once inside the same transaction. A library observation uses one indexed
join; opening and scrolling the list do not scan token events or start an
observer per row. The detail uses the same counters, keeping its turn query and
chart separate. Retained usage after a session expires continues to belong to
period and project totals, without creating a session row. Rows show compact
tokens and the selected display currency, with exact counts in accessible
labels and explicit partial, approximate and unpriced states.

## DEV-079 — Fold only confirmed copies into a continued transcript

Link the current Claude primary file and child session to canonical event rows
with matching recorded owner, stable event UUID and indexed content. Keep the
copy's physical order and block position; its reference never adds FTS, text,
usage or turns to the child. The default folded row identifies one contributing
original when known; multiple owners stay generic. Expansion pages only copied
previews, without the original file or archived tool actions. Re-scan a live
file from byte zero to reconstruct its references; a canonical body edit or
owner change invalidates old references. Deleting or excluding the canonical
event or child removes its references. No ancestry is inferred for a
source that has not demonstrated its copy format.

Session rows reserve their normal height during live insertion. The native list
can otherwise briefly allocate its one-line default to a new multi-line row,
letting the following row obscure its caption and click target.

## DEV-080 — Describe the running app’s signature in About

Use the bundle’s version and build. Validate this process with Apple’s
code-signing services and [the no-network flag](https://developer.apple.com/documentation/security/seccsflags/nonetworkaccess),
then render the embedded entitlement dictionary. The configured plist is not
runtime readback, and an invalid, unreadable or unrecognized profile cannot
verify the absence of network permission. This display does not replace
the release’s signed artifact check or zero-network observation.

The native About check takes an independent artifact receipt in
`TEST_RUNNER_AGENTDASH_ABOUT_ARTIFACT_RECEIPT`: version and build strings from
the built Info.plist and entitlement entries from `codesign -d --entitlements - --xml`.
Represent booleans as `true`/`false` strings and join array entries with newlines.
Compare the receipt against the running app’s display in English and Chinese.

## DEV-081 — Local clock and optional menu throughput

General persists just the display options. The clock uses
[Foundation’s locale hour-cycle override](https://developer.apple.com/documentation/foundation/locale/components/hourcycle)
for absolute times and period controls without moving any query or bucket
boundary. The default follows the system. Only an enabled menu label
observes recent call-level counts; its sampling matches the panel’s exact
trailing minute and wakes only on relevant token changes or to age out a
nonzero value. The detailed panel keeps its own visible-only read.

## DEV-082 — Present validated search filters as native tokens

The same bounded lexer that validates a query captures filter spellings. This
lets the native field show text and tokens without changing query bytes on
presentation or submission. Typed input is kept verbatim until submission,
and AppKit’s marked-text state prevents converting during composition.
Only removing or editing a token or text changes the query; filters are
global and remain in their original order, independent of the sidebar scope.
The session list’s Search Filters menu offers mouse removal with masked labels.
Keep filter management and result sorting beside the results so the native
search field has room for both tokens and the query at minimum width.

## DEV-083 — Fail closed on accidental test launches

Use a separate SyntheticQA build configuration and bundle identifier for
native tests, using the same frozen entitlements. The app's entry point
rejects a missing `--synthetic` argument before SwiftUI creates its app
delegate or model. Verify the signed identity, compiled guard and actual
early exit before a desktop test. Debug and Release keep normal entry
behavior; tests target only the isolated QA bundle.

An explicitly authorized QA launch opens the existing Dashboard scene after
startup, without relying on restored windows from the normal app. Native
diagnostics use the test window, never a complete application accessibility
tree. Keep normal Debug and Release entry and window behavior.

Bind the transcript's match scroll position before laying out a new page.
An immediate scroll call after creating the scroll view could be dropped on
a fresh launch, even though the right match page had loaded. Keep a manual
scroll position when unrelated changes refresh the same page.

## DEV-084 — Keep user session titles separate from imported metadata

Write the optional override to the owned index; clear it explicitly to
resume automatic titles. Resolve the title and its origin once in the shared
session projection, using indexed user/summary lookups only. The first
prompt fallback skips slash commands and recognized injected context. The
app masks complete bounded values before shortening them for display, and
stored overrides follow index redaction both on write and during a scrub.
No added source discovery is needed for this projection.

## DEV-085 — Measure startup against a previously prepared QA index

Run `python3 Tools/measure-synthetic-startup.py /path/to/AgentDashboard.app`
against the signed SyntheticQA bundle. The tool verifies that bundle before
launching it, creates a UUID-scoped index with 1,000 sessions and 10,000
events in a separate prepare launch, then measures fresh processes reopening
that same index. Reopen rejects a missing index, and prepare rejects an
already used identity. The path comes from the app's temporary directory and
the UUID, never from an external database path.

The clock starts just before spawning each process and stops at a QA marker
from the known first session row after its AppKit draw pass. This includes
spawn and pipe overhead; it measures process startup with a recent disk
cache, without capture or keyboard automation. It does not measure WindowServer
presentation, normal Release startup, or a production-sized library.

## DEV-086 — Measure live updates after the actual watcher starts

Run `python3 Tools/measure-synthetic-live-update.py /path/to/AgentDashboard.app`
against signed SyntheticQA. A separate writer process enters the QA-only
tool mode before any UI or store setup. It creates and writes only its own
private UUID fixture directory in the QA container and removes it at exit.
The dashboard gets an agent and a fixture ID, opens the corresponding
generated source read-only, and uses the normal Start Indexing action's
controller. Release has neither test entry point.

Wait for both the real watcher and a baseline row. Then measure an append to
the existing JSONL and creation of a new session file, each through the
normal discovery or tail, store, and Sessions list. The intervals include
sending the small write command to the producer and end after AppKit draws
the matching Chinese title in the real list. The command
tests Claude Code, Codex, and Copilot CLI without keyboard input. It does
not measure derived topic or status debounce, compressed immutable rollouts,
or the load of a production-sized library.

## DEV-087 — Measure loaded-app memory and idle CPU with one million events

Build and sign SyntheticQA with Release optimization (`SWIFT_OPTIMIZATION_LEVEL=-O`),
then run `python3 Tools/measure-synthetic-resources.py /path/to/AgentDashboard.app`.
The generator supplies batches of synthetic messages to a separate prepare
launch, which verifies stored event counts and finishes topic and status work.
The timed runs reopen that same isolated index. One waits for the real
transcript to draw; the other closes that same window normally and checks
that the Dashboard, Settings and menu panel are hidden. The menu item remains
registered. Neither run starts a live source read.

After a four-second settling interval, the tool samples that PID's physical
footprint and RSS and computes single-core-equivalent CPU usage from its
cumulative user and system time. No accessibility access, screen capture or
keyboard input is used. This tests a stable library with the menu panel
closed; rendering the panel and workloads that change the library are
separate cases.

Pass `--mode usage` to sample the visible 24H chart on the same fixture.
Its three series contain older in-period usage, with no expiry during the
sample. QA-only markers verify initial report and headroom reads, a
drawn chart, continuing NOW ticks and zero additional usage reads after
settling. Process I/O alone cannot establish that a cached index was not read.

## DEV-088 — Schedule usage reads at changes and real deadlines

Menu usage, the optional throughput label and limit cards observe owned
index changes. Readings include the next change caused by the clock;
one-shot wakeups handle trailing-window entry and expiry, quota reset or
freshness, displayed session minutes and local midnight. Empty readings
without a known change have no timer. Nearby expiries can share a read.

The Usage page refreshes its report when period or comparison membership
changes, and refreshes only the chart when its trailing minute changes.
Its five-second NOW animation moves the range used for drawing, without
querying usage or rebuilding the plot. Clock or time-zone changes resample
the visible consumers; custom reports do not acquire a rolling deadline.

## DEV-089 — Measure the native first screen and scrolling on 50,000 messages

Build and sign the optimized SyntheticQA bundle, then run
`python3 Tools/measure-synthetic-transcript.py /path/to/AgentDashboard.app`.
A separate prepare process uses the project generator and verifies 50,000
stored messages. The sample warms a short transcript and times the same
selection binding the native list uses until a clipped message row draws.
It checks a 128-message first page and the actual next cursor page.

The window's display link requests 60 Hz. Each sample moves the real
AppKit scroll viewport, runs pending view display and submits the layer
transaction. Measure completed scroll updates, frame work and deadline
misses, and require actual new message rows to draw in the viewport.
These are view and submission measurements; they do not sample final
display pixels or WindowServer presentation. No desktop capture, keyboard
input or user source is involved.

## DEV-090 — Measure complete period switching in the native Usage view

Run `Tools/measure-synthetic-usage-period.py` against the signed, optimized
SyntheticQA build. It uses the period picker's binding and times until the
new chart's draw pass completes. A separate fixture holds 1M verified
token rows with stored synthetic quotes. The probe checks the selected
period, exact report totals and chart totals; it records query, plot and
end-to-end time. A warm initial chart excludes process launch but does not
assume every other period's database pages are already resident.

Keep the chart mounted while replacing a report and hide the stale scope
during loading. Rolling and fixed periods share their chart structure;
fixed ranges have no visual timer. Draw each line as a batch of unchanged
data points and derive obstacle coordinates from the actual linear scales.
Use existing scope rollups for agent-wide summaries and a ranked minute
cost index for long ranges. For middle ranges, seek by rank and time at
each of a bounded number of distinct values, skipping ties outside the
window. Scan unresolved scopes by time; partial-minute facts and
project/model filters remain exact. Reuse an unchanged chart and its last
peak-label plan only when the data and resolved geometry match. Measure
and place the three viewport blocks with the same size proposal.

Start a reader from the period selection; the view adopts it only if
its full request still matches. Cancelling or leaving the page cannot
publish a previous scope.

## DEV-091 — Check native responsiveness during a real price-file sweep

Export an owned fixture from the Release Package test, then use the
signed, optimized SyntheticQA app:

```sh
fixture=$(uuidgen)
AGENTDASH_NATIVE_REPRICE_EXPORT="$fixture" \
  swift test --package-path Packages/AgentDashKit -c release \
  --filter exportNativeRepricingFixture
python3 Tools/measure-synthetic-repricing.py /path/to/AgentDashboard.app --export "$fixture"
```

The exporter verifies one million eligible rows and one previously
quoted row. The app checks the transferred index and renders its old
totals before accepting an atomic replacement inside its private
synthetic price directory. Its normal watcher loads the price table.
Measure file change to the final drawn total, and two actual period
selections while the sweep is active. The historical estimate remains
included at its original price. No real price table or keyboard is used.

During a bulk sweep, combine committed usage revisions before redrawing
and flush the last revision at completion. Explicit period selections
still read the current index. The worker uses bounded 2,048-row
transactions and yields between writes; hidden or unchanged pages do
not start a polling loop.

## DEV-092 — Measure and reuse adjacent search pages (FR-SR, NFR-4)

Start the 150 ms deadline at the edit itself. Keep the native list mounted
during queries but hide its stale rows and controls. Rank and count in one
committed read, then retain at most two pages of masked result rows for that
query, sort, filter and privacy revision. When the user opens a retained page,
the normal search observation still revalidates it against the index.

Export the same million-event workload used by the search package benchmark,
then measure the actual result list in the signed, optimized SyntheticQA app:

```sh
fixture=$(uuidgen)
AGENTDASH_NATIVE_SEARCH_EXPORT="$fixture" \
  swift test --package-path Packages/AgentDashKit -c release \
  --filter exportNativeSearchFixture
python3 Tools/measure-synthetic-native-search.py /path/to/AgentDashboard.app --export "$fixture"
```

The runner prepopulates the search binding, invokes the same page action as
the Next button, and measures through the first visible result row draw.
It checks exact counts, disjoint pages and the refreshed count at the same
offset after a synthetic commit. The timing reports both the full duration
and the duration excluding only the prescribed debounce. No keyboard is used.

## DEV-093 — Check cold page transitions and broad OR (FR-SR, NFR-4)

The signed SyntheticQA runner's `--boundaries` mode walks the million-event
fixture from page one through eight, then back twice. Check every ranked
identity and the selected session, including crossings that must read an
uncached result page. Then repeat broad OR alone for latency, using a
narrow prefill between samples, and verify that a real event rewrite
empties the tail page and returns to page one with the exact new count.

The FTS reader uses a bounded, reader-local 256 MiB virtual mapping so
large index reads can reuse mapped file pages. Tally consecutive hits
locally, merging by session when the rows are interleaved. Keep the same
BM25 ordering, exact totals, and masking before highlighting; reuse the
last snippet only for byte-identical input within that read.

## DEV-094 — Restore the offline pricing maintenance commands (FR-COST, SEC-7)

Keep the developer executable out of the App target. It uses the existing
ADPricing decoder and cost estimator, and emits only accounting summaries.
Inventory and historical preview require an explicit standalone index copy;
they reject WAL format before opening SQLite to avoid touching an active
database or its sidecars. A preview reports hypothetical quotes separately
from stored quotes and possible fills of previously unpriced events.

Installation is explicit and append-only against both bundled and installed
tables. It stages in the destination directory and atomically replaces only
the external pricing file. Reject an unreadable or symlinked destination
instead of silently overwriting evidence. No user price file is written by
validation or inventory.

## DEV-095 — Read Copilot's native workspace title (ADP-CP, FR-SR)

Read only the title scalars of the optional sidecar next to a registered
Copilot event file. Use the native `name`, then `summary`; malformed or
absent sidecars preserve an already indexed title. A user title stays
separate and wins. New Copilot records no longer copy the prompt into
the agent title field; the ordinary first-prompt fallback remains in
the index view.

Map a sidecar notification only to an already known event file. On
an unchanged event checkpoint, refresh the title without reading event
bytes. A metadata-only workspace does not enter the transcript index.

## DEV-096 — Use the native Sessions divider for responsive widths

Apply the specified 300/356/420-point defaults to the actual native
list pane. Keep its mounted search, selection and transcript; the narrow
detail uses a 2×2 fact grid. A user drag overrides the interpolated
default and is persisted as an App presentation preference. Limit the
mouse handler to a gesture that starts on the Sessions divider in its
own window.

Verify geometry without input. Verify drag and relaunch with the
explicit native visual review handoff; a skip outside that handoff
does not attest pointer behavior or persistence.

## DEV-097 — Keep Token Usage chart series distinct (FR-TK-1, §11.4)

Give vectorized plots explicit identities for each agent, combined
throughput and cumulative usage. Implicit grouping on macOS 27 joined
these paths and discarded the agent strokes and the cumulative dash.
Keep the selected metric and periods together when their intrinsic
width fits; move periods below the heading when it does not.
Verify the native strokes and heading at three sizes in both appearances.

## DEV-098 — Read the model in Copilot's per-call usage (ADP-CP)

Some real `session.usage_record` rows carry the model only inside the
usage object. Read it ahead of session metadata so a call keeps its
explicit model and time. Bump the parser version so files with skipped
calls replay; reconcile the existing checkpoint remainder as those
calls arrive. A synthetic v4 checkpoint test verifies that a preceding
call replaces its covered volume and a subsequent call adds new volume.
