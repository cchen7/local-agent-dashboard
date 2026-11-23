# Observed formats

## Evidence boundary

2026-11-17: coordinator completed EXP-1 by streaming local metadata. No raw
conversation text, credentials, session IDs or copied source files are included.
Ordinary JSONL was scanned at 2026-11-17T07:27:03.780525+00:00; compressed JSONL at
2026-11-17T07:29:51.500657+00:00. Live files can continue growing after these observations.

Only fields, record shapes and counts were extracted. The scan used existing
Python 3.15.2 `compression.zstd`; it installed nothing and did not change the
original files. This is format discovery, not adapter/fixture acceptance.

## Codex environments (EXP-1)

### Locations and launchers

- One discovered Codex root: `~/.codex`, with `sessions/` and `archived_sessions/`.
- No `CODEX_HOME` override was present in the coordinator shell. No `*.config.toml`
  profile files were found. Only base `config.toml` was present.
- Shell entrypoint inspection plus a home-directory search to file depth 5 found
  no extra `rollout-*.jsonl` locations. Search excluded Library, media directories,
  Trash, build/dependency/Git directories and other agents' default roots.
  This bounded search cannot establish that no deeper/custom/synced root exists.
- Ordinary `codex` resolves to CLI 0.169.0. Its current base config selects
  `model_provider = azure`, `model = gpt-6.1-sol`, via the existing standard proxy.
- `codex-astra` is a wrapper around the same CLI. Its current code retains the
  same `CODEX_HOME`, overrides the provider map for that process, chooses
  `astra_foundry` for fresh sessions, and defaults to `gpt-6-astra`.
- The former mixed launcher is retired in the currently inspected source.
  All three model IDs in the Foundry wrapper route through Foundry; selecting Sol
  there does not switch to the normal proxy. No launcher or global config changed.

### File inventory

| Files | Count | Interpretation |
|---|---:|---|
| Uncompressed rollout JSONL | 174 | 156 begin with `session_meta`; 18 are legacy headers |
| Compressed `.jsonl.zst` | 586 | 584 active-tree files and 2 archived-tree files; all begin with `session_meta` |
| Distinct modern session IDs across both encodings | 742 | IDs counted privately, not exported |
| Modern session IDs appearing in more than one scanned file | 0 | Metadata-only duplicate check |

The 18 legacy first records have keys `id,timestamp` (17 files), or
`id,instructions,timestamp` with null `instructions` (1 file), and no `type`.
Under the current SPEC these fail the Codex adapter's first-record validation.
Count/report them as unsupported legacy files; do not silently claim full coverage
or add an undocumented legacy parser. Raise a scoped compatibility question before
changing the validation rule.

Compressed records have `ordinal` in addition to `type,timestamp,payload`.
Unknown envelope fields must be tolerated. SEC-4's condition for a source-vendored
zstd decoder is now satisfied by observed files; a new package is still not allowed.
Capture and sanitize decompressed fixtures before implementing this path.

### Provider counts (modern files)

| `session_meta.model_provider` | Sessions |
|---|---:|
| `<missing>` | 8 |
| `astra_foundry` | 16 |
| `azure` | 717 |
| `azure_direct` | 1 |

### Origin / source / provider / CLI version combinations

`{subagent}` denotes the shape of an object, not its private parent IDs. A current
spawn uses `source.subagent.thread_spawn` with parent/depth/agent-path metadata.
Other helper sessions use `source.subagent.other`. Do not require `source` to be a string.

| originator | source | model_provider | cli_version | Count |
|---|---|---|---|---:|
| `Codex Desktop` | `vscode` | `azure` | `0.105.0` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.116.0-alpha.10` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.129.0-alpha.15` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.131.0-alpha.9` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.142.4` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.142.5` | 6 |
| `Codex Desktop` | `vscode` | `azure` | `0.153.4` | 1 |
| `Codex Desktop` | `{subagent}` | `azure` | `0.131.0-alpha.9` | 1 |
| `Codex Desktop` | `{subagent}` | `azure` | `0.142.5` | 1 |
| `Codex Desktop` | `{subagent}` | `azure` | `0.144.3` | 2 |
| `codex-tui` | `cli` | `astra_foundry` | `0.164.0` | 2 |
| `codex-tui` | `cli` | `astra_foundry` | `0.166.0` | 2 |
| `codex-tui` | `cli` | `astra_foundry` | `0.169.0` | 1 |
| `codex-tui` | `cli` | `azure` | `0.115.0` | 2 |
| `codex-tui` | `cli` | `azure` | `0.118.0` | 13 |
| `codex-tui` | `cli` | `azure` | `0.120.0` | 4 |
| `codex-tui` | `cli` | `azure` | `0.122.0` | 3 |
| `codex-tui` | `cli` | `azure` | `0.125.0` | 5 |
| `codex-tui` | `cli` | `azure` | `0.128.0` | 3 |
| `codex-tui` | `cli` | `azure` | `0.129.0` | 1 |
| `codex-tui` | `cli` | `azure` | `0.130.0` | 10 |
| `codex-tui` | `cli` | `azure` | `0.134.0` | 4 |
| `codex-tui` | `cli` | `azure` | `0.137.0` | 1 |
| `codex-tui` | `cli` | `azure` | `0.139.0` | 9 |
| `codex-tui` | `cli` | `azure` | `0.141.0` | 2 |
| `codex-tui` | `cli` | `azure` | `0.142.0` | 8 |
| `codex-tui` | `cli` | `azure` | `0.142.5` | 6 |
| `codex-tui` | `cli` | `azure` | `0.144.3` | 3 |
| `codex-tui` | `cli` | `azure` | `0.144.4` | 8 |
| `codex-tui` | `cli` | `azure` | `0.144.6` | 4 |
| `codex-tui` | `cli` | `azure` | `0.145.0` | 20 |
| `codex-tui` | `cli` | `azure` | `0.147.0` | 11 |
| `codex-tui` | `cli` | `azure` | `0.148.0` | 1 |
| `codex-tui` | `cli` | `azure` | `0.149.0` | 4 |
| `codex-tui` | `cli` | `azure` | `0.150.1` | 3 |
| `codex-tui` | `cli` | `azure` | `0.151.0` | 2 |
| `codex-tui` | `cli` | `azure` | `0.152.1` | 5 |
| `codex-tui` | `cli` | `azure` | `0.153.1` | 3 |
| `codex-tui` | `cli` | `azure` | `0.153.4` | 26 |
| `codex-tui` | `cli` | `azure` | `0.154.0` | 17 |
| `codex-tui` | `cli` | `azure` | `0.155.1` | 4 |
| `codex-tui` | `cli` | `azure` | `0.156.0` | 4 |
| `codex-tui` | `cli` | `azure` | `0.160.1` | 3 |
| `codex-tui` | `cli` | `azure` | `0.162.1` | 5 |
| `codex-tui` | `vscode` | `azure` | `0.157.1` | 4 |
| `codex-tui` | `vscode` | `azure` | `0.158.0` | 3 |
| `codex-tui` | `vscode` | `azure` | `0.159.0` | 4 |
| `codex-tui` | `vscode` | `azure` | `0.159.2` | 1 |
| `codex-tui` | `vscode` | `azure` | `0.159.3` | 5 |
| `codex-tui` | `vscode` | `azure` | `0.160.0` | 3 |
| `codex-tui` | `vscode` | `azure` | `0.160.1` | 1 |
| `codex-tui` | `vscode` | `azure` | `0.161.0` | 4 |
| `codex-tui` | `vscode` | `azure` | `0.162.0` | 2 |
| `codex-tui` | `vscode` | `azure` | `0.162.1` | 9 |
| `codex-tui` | `vscode` | `azure` | `0.163.0` | 15 |
| `codex-tui` | `vscode` | `azure` | `0.164.0` | 7 |
| `codex-tui` | `vscode` | `azure` | `0.165.0` | 4 |
| `codex-tui` | `vscode` | `azure` | `0.166.0` | 18 |
| `codex-tui` | `vscode` | `azure` | `0.167.0` | 3 |
| `codex-tui` | `vscode` | `azure` | `0.167.1` | 2 |
| `codex-tui` | `vscode` | `azure` | `0.167.2` | 2 |
| `codex-tui` | `vscode` | `azure` | `0.169.0` | 4 |
| `codex-tui` | `{subagent}` | `astra_foundry` | `0.164.0` | 3 |
| `codex-tui` | `{subagent}` | `astra_foundry` | `0.166.0` | 3 |
| `codex-tui` | `{subagent}` | `astra_foundry` | `0.167.2` | 3 |
| `codex-tui` | `{subagent}` | `astra_foundry` | `0.169.0` | 2 |
| `codex-tui` | `{subagent}` | `azure` | `0.118.0` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.120.0` | 2 |
| `codex-tui` | `{subagent}` | `azure` | `0.122.0` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.125.0` | 4 |
| `codex-tui` | `{subagent}` | `azure` | `0.130.0` | 1 |
| `codex-tui` | `{subagent}` | `azure` | `0.144.3` | 1 |
| `codex-tui` | `{subagent}` | `azure` | `0.144.4` | 1 |
| `codex-tui` | `{subagent}` | `azure` | `0.145.0` | 11 |
| `codex-tui` | `{subagent}` | `azure` | `0.147.0` | 13 |
| `codex-tui` | `{subagent}` | `azure` | `0.148.0` | 1 |
| `codex-tui` | `{subagent}` | `azure` | `0.149.0` | 5 |
| `codex-tui` | `{subagent}` | `azure` | `0.150.1` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.151.0` | 3 |
| `codex-tui` | `{subagent}` | `azure` | `0.152.1` | 7 |
| `codex-tui` | `{subagent}` | `azure` | `0.153.1` | 5 |
| `codex-tui` | `{subagent}` | `azure` | `0.153.4` | 42 |
| `codex-tui` | `{subagent}` | `azure` | `0.154.0` | 22 |
| `codex-tui` | `{subagent}` | `azure` | `0.155.1` | 8 |
| `codex-tui` | `{subagent}` | `azure` | `0.156.0` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.157.1` | 7 |
| `codex-tui` | `{subagent}` | `azure` | `0.158.0` | 4 |
| `codex-tui` | `{subagent}` | `azure` | `0.159.0` | 4 |
| `codex-tui` | `{subagent}` | `azure` | `0.159.2` | 2 |
| `codex-tui` | `{subagent}` | `azure` | `0.159.3` | 11 |
| `codex-tui` | `{subagent}` | `azure` | `0.160.0` | 13 |
| `codex-tui` | `{subagent}` | `azure` | `0.160.1` | 4 |
| `codex-tui` | `{subagent}` | `azure` | `0.161.0` | 9 |
| `codex-tui` | `{subagent}` | `azure` | `0.162.0` | 3 |
| `codex-tui` | `{subagent}` | `azure` | `0.162.1` | 37 |
| `codex-tui` | `{subagent}` | `azure` | `0.163.0` | 29 |
| `codex-tui` | `{subagent}` | `azure` | `0.164.0` | 12 |
| `codex-tui` | `{subagent}` | `azure` | `0.165.0` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.166.0` | 17 |
| `codex-tui` | `{subagent}` | `azure` | `0.167.0` | 8 |
| `codex-tui` | `{subagent}` | `azure` | `0.167.1` | 3 |
| `codex-tui` | `{subagent}` | `azure` | `0.167.2` | 5 |
| `codex-tui` | `{subagent}` | `azure` | `0.168.0` | 2 |
| `codex-tui` | `{subagent}` | `azure` | `0.169.0` | 4 |
| `codex_cli_rs` | `cli` | `<missing>` | `0.46.0` | 4 |
| `codex_cli_rs` | `cli` | `azure` | `0.106.0` | 3 |
| `codex_cli_rs` | `cli` | `azure` | `0.107.0` | 1 |
| `codex_cli_rs` | `cli` | `azure` | `0.111.0` | 4 |
| `codex_cli_rs` | `cli` | `azure` | `0.112.0` | 5 |
| `codex_cli_rs` | `cli` | `azure` | `0.114.0` | 8 |
| `codex_cli_rs` | `cli` | `azure` | `0.116.0` | 9 |
| `codex_cli_rs` | `cli` | `azure` | `0.117.0` | 7 |
| `codex_cli_rs` | `vscode` | `<missing>` | `0.40.0` | 4 |
| `codex_cli_rs` | `{subagent}` | `azure` | `0.116.0` | 7 |
| `codex_cli_rs` | `{subagent}` | `azure` | `0.117.0` | 8 |
| `codex_exec` | `exec` | `azure` | `0.139.0` | 3 |
| `codex_exec` | `exec` | `azure` | `0.144.3` | 2 |
| `codex_exec` | `exec` | `azure` | `0.144.6` | 1 |
| `codex_exec` | `exec` | `azure` | `0.145.0` | 13 |
| `codex_exec` | `exec` | `azure` | `0.148.0` | 3 |
| `codex_exec` | `exec` | `azure` | `0.149.0` | 2 |
| `codex_exec` | `exec` | `azure` | `0.151.0` | 1 |
| `codex_exec` | `exec` | `azure_direct` | `0.145.0` | 1 |
| `codex_exec` | `{subagent}` | `azure` | `0.145.0` | 1 |
| `codex_exec` | `{subagent}` | `azure` | `0.148.0` | 1 |
| `codex_exec` | `{subagent}` | `azure` | `0.151.0` | 1 |
| `ssh_network_diagnostic` | `vscode` | `azure` | `0.162.1` | 3 |
| `ssh_network_diagnostic` | `{subagent}` | `azure` | `0.162.1` | 3 |

### Model distribution

Counts below are `turn_context` records, not token usage or distinct sessions.

| `turn_context.model` | Records |
|---|---:|
| `gpt-6-luna` | 4286 |
| `gpt-5.6-luna` | 2057 |
| `gpt-6-astra` | 714 |
| `gpt-6.1-sol` | 584 |
| `gpt-5.4` | 516 |
| `gpt-5.6-sol` | 450 |
| `gpt-5.5` | 349 |
| `gpt-5.3-codex` | 113 |
| `codex-auto-review` | 40 |
| `gpt-5.6-terra` | 11 |
| `gpt-5-codex` | 6 |

### Environment classification and delegation

Use one Source for the shared root and environment rules on `model_provider` for
new sessions. Keep provider labels literal by default (`azure`, `astra_foundry`,
`azure_direct`, or unknown); user-friendly labels can be confirmed separately.
`originator/source` classify entrypoints/subagents and must not be used as a backend identifier.

Historical caveat: the current wrapper's resume path can reuse a saved provider ID
while redirecting its process-local provider definition to Foundry. Thus an old
`azure` label cannot prove that a specific historical request used the normal proxy.
Model IDs are also shared between environments. Preserve this uncertainty in the
UI instead of asserting account/provider routing that the stored evidence cannot establish.

A completed read-only delegation preflight from the coordinator used:
- Requested model: `gpt-6.1-sol`.
- Observed child `turn_context.model`: `gpt-6.1-sol`.
- Observed child `session_meta.model_provider`: `astra_foundry`.
- Tool execution and final marker completed successfully.

This proves model override works here but does **not** switch to the standard
environment. After the owner explicitly approved the standard destination and
project-context scope, a fresh ordinary-Codex process completed a second preflight:

| Evidence | Observed result |
|---|---|
| Launch | Ordinary `codex --no-daemon exec`, explicit `model_provider="azure"`, fresh task |
| `session_meta.model_provider` | `azure` |
| `turn_context.model` | `gpt-6.1-sol` |
| `originator` / `source` | `codex_exec` / `exec` |
| Tool execution | `pwd` and `git status --short --branch`, both exit 0 |
| Completion | `turn.completed`, final preflight marker, process exit 0 |

Use this ordinary-process method for the coding workers. This preflight occurred
after the inventory snapshot and is not included in the tables above. It verifies
the configured provider/model and a completed agent tool loop, not upstream model
deployment telemetry. Do not classify the `exec` entrypoint as a separate environment.

## Claude Code parser contract

The checked-in Claude Code tests use wholly synthetic project transcripts,
child transcripts, and prompt history drawn from the contract in SPEC §5.4.
The public [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference)
describes resume, and [Agent SDK cost tracking](https://code.claude.com/docs/en/agent-sdk/cost-tracking)
describes cumulative output usage and cache token fields. Public
[history examples](https://github.com/anthropics/claude-code/issues/19995)
show the prompt, workspace and timestamp fields. Local capture checks stay
outside the repository; no captured bytes or account details are part of
these tests. Capture preserves the public `display` field name and masks its
value just like other prompt text.

For primary transcripts, the filename identifies the file's session and a
valid record `sessionId` identifies the owner of its events and usage. Copied
rows cannot replace either session's workspace. A nested subagent's session ID
can identify its parent, so subagent rows stay in their child session.
Response fragments can advance a globally deduplicated output count only for
the same input/cache basis. Prompt history is kept separate from transcripts.

Assistant records can share a producer `message.id` across JSONL lines
with distinct record UUIDs (§5.4). Text events preserve that ID separately
from the event dedupe key; token accounting continues to use its existing
message ID rules. Normalized text blocks share the physical record's sequence and key stem
(`claude:event:<record identity>:`); the final numeric component orders the
blocks. The Overview rejoins assistant text across records when the ID is
available, or within one physical record otherwise, before masking and
excerpting it. Public v5 replays v3 and v4 file checkpoints. The integrated
v7 also replays locally indexed v6 files for this repair. A retained
resume copy can backfill a missing ID on a matching assistant record UUID
for the same owner, even if the original file is no longer present. The
backfill leaves the stored text, order, event keys and token accounting intact.

For inherited transcript display, parser v11 records references only from
complete Claude primary rows with a recorded owner different from the file UUID
and a valid producer event UUID. The destination's physical record/block order
is separate from the original's event sequence. In an ordinary sanitized local
primary file, 680 of 1,616 rows had both valid UUID fields. The bounded
52-file sample did not contain a matched resume copy. Copy cases use synthetic
fixtures for the SPEC §5.4 contract. A filename, parent hint or timestamp alone
does not identify copied content, and subagent linkage is not inheritance.

Codex context samples use cache-inclusive `last_token_usage.input_tokens`
and `info.model_context_window` for the sampled model. A subsequent
different model starts with no inherited capacity. Claude context samples
sum fresh input, cache reads and cache creation from the assistant usage
record; its capacity comes from a local model rule when available.
These measurements do not replace token-event accounting or dedupe.

Copilot session records are read from `session-state/<session-id>/events.jsonl`.
The normalized stream keeps typed turn/shutdown evidence and uses
`user.message.data.content`, never `transformedContent`. Per-model
`modelMetrics.<model>.usage` snapshots retain their file position; the
app-owned store subtracts earlier exact calls to avoid double counting.
Per-call and child-event accounting are covered by synthetic fixtures.
Observed `session.usage_record` events can put the explicit model in
`data.usage.model` with no model at the event-data level. Parser v5
reads that field before falling back to session metadata. Replaying a
v4 file fills previously skipped calls; earlier native checkpoints
continue to supply only the usage not already represented by calls.
Parser v6 retains valid parent-call counters as unpriced when neither the
event nor the session supplies a model. A sanitized local capture confirmed
the nested numeric usage shape with a model; the bounded recent-file pass
did not locate a model-less parent call. The missing-model, replay and
later-checkpoint cases use synthetic variations of that envelope. Parser
v7 replays older checkpoints. After subtracting named calls and previously
covered anonymous calls, the store counts a model-less call only once when
exactly one model's cumulative remainder covers all its counters. Later
covering checkpoints can reconcile an earlier partial sample. The call
stays unpriced at its original time; ambiguous coverage does not set a
model. During verified v5/v6 prefix replay, only the matching old unknown
stub is removed after decoding the same call successfully. Parser v8 also
replays v7 files: a candidate model's remaining usage excludes checkpoint
volume credited before the call's file position. After reserving a unique
match, retry pending calls against the smaller remainder. With parser v9,
an unchanged v8 source also replays. The store can subtract an entire batch
when its components exactly match the models' free counters and there is a
complete allocation of whole calls after accounting for earlier snapshots.
The allocation is only a coverage check; calls still have no model or price.
If the limited search cannot prove coverage, keep the separate counts.
Event-backed Copilot workspaces expose the native title as top-level
`name`, with an optional top-level `summary`. The observed strings used
plain scalars, single or double quotes, and literal `|-` blocks. The
sanitized title fixtures keep only those shapes; every value is replaced
with fixed synthetic text. This is a small scalar subset, not arbitrary YAML
or optional metadata DB support. Prefer a usable `name` over the summary.

A native `workspace.yaml` updated timestamp does not establish that a
supported event stream is present. The default source can retain workspace
metadata, plan files and auxiliary directories without `events.jsonl`.
Count those as workspace-only in native comparisons. Do not infer a
transcript, tokens or an App-importable event log from the sidecar.

A stable read-only copy of Copilot's `session-store.db` can expose
`assistant_usage_events` for independent numeric comparisons. Its
coverage is not identical to the supported JSONL streams: an overlapping
session can have additional accounting records only in the database.
Compare the same time window and session identities without treating
database-only activity as an event that the JSONL adapter imported.

Claude parser v5 also records a typed turn-end hint on assistant text
when `message.stop_reason` is `end_turn`. A turn end does not end the
session. An absent stop reason is ordinary assistant activity.

Tool results can contain a string or an array of text blocks. Field order
is not assumed: `tool_use_id`, `is_error` and the outer record identity can
appear after the large body. Oversized records can retain a tool-result
preview of at most 2 KiB across all text blocks via bounded reads of the
same line. Unrelated payload fields do not consume this preview budget. A v2
overflow that lost the JSON envelope wrote an empty marker keyed by source,
relative file path and physical sequence. In-place v3 replay reconciles that
marker when it recovers the same line.

## Local Codex port

Ordinary and compressed captures were sanitized before comparison; privately
derived details remain in the local format report. The local adapter keeps
session metadata, turn model and last-usage counters, and treats compressed
files as immutable. A session can have usage and task events without usable
transcript messages in that channel. The local writer therefore chooses a
transcript based on usable text and supersedes fallback content transactionally.
Only sanitized format notes and synthetic fixtures are tracked. Raw
captures and detailed native accounting evidence stay local.

The native Codex `session_index.jsonl` can repeat an `id` and includes
`updated_at`; it is not a start-time or token-usage ledger. For a
fixed-window inventory check, deduplicate native IDs and check that the
supported rollout headers resolve those same IDs. Matching a header
does not prove that the whole file was imported or that its usage totals
match. Do not compare a native updated-session count with a count of
sessions having token events in the window.

## Scope of native accounting verification

Claude Code's `stats-cache.json` can contain dated `dailyActivity`
and `dailyModelTokens`, plus aggregate session/model counters. A cache
whose coverage ends before the audit window is unavailable as a reference
for that window; its missing days do not mean zero sessions or zero usage.
Distinct session counts, cache-inclusive token sums, and priced-record
coverage are separate checks. A native Copilot shutdown total used by
the fallback importer is a consistency reference, not an independent
CLI-wide accounting ledger.

In the 0.1.0 fixed-window spot check, the Codex itemized usage sum was
within 1% of the native cumulative delta. The remaining differences came
from rollouts whose first cumulative balance already exceeded their first
itemized record. The importer keeps the itemized usage and does not assign
that unexplained opening balance to the window.

The sampled Claude statistics cache had no dated coverage of the selected
window or separate daily cache counters. Raw response records agreed
with the index; the independent CLI comparison remains open. In Copilot,
the overlapping native SQLite rows exceeded the 1% tolerance. The extra
rows matched an already represented call's model and counters within a
millisecond, but used different turn indices and had no common event ID.
Counting each matched event once explained the difference in a diagnostic
projection. It does not establish the CLI's counting rule and is not a
production deduplication rule. Keep the raw comparison open pending
independent confirmation.

## Local source availability for M0

2026-11-17: the real, sandboxed and hardened App's Sources panel successfully
enumerated the default Claude Code, Codex and Copilot directories (top-level entry
counts 46, 70 and 55 at that observation). This verifies directory access, not
session discovery or parser/accounting accuracy. No session contents were opened.
The Grok default directory was absent; the owner confirmed Grok is not installed
and asked to ignore it for now (DEV-008). No Grok fixture or compatibility result
is claimed.

## Optional Claude thinking blocks

A bounded schema-only inventory found `message.content[].type = thinking` in
Claude Code project JSONL and subagent files. The sampled `thinking` text was
empty. A real sanitized capture preserved the empty string and its record
shape; no sample content was retained in this repository. Nonempty, oversized,
and opaque cases are exercised with synthetic fixtures. The adapter accepts
only a complete nonempty text field in a Claude assistant thinking block.
Signatures and opaque/redacted data are ignored. The sampled Codex and Copilot
files did not provide a verified nonempty counterpart for this feature.

## Tool output archive evidence

Sanitized samples confirmed Claude string/text-block-array tool results, Codex
output arrays containing `input_text` strings, and longer Copilot result
content strings. A separate schema-only check found Claude persisted-output
markers naming a same-session `tool-results` text file. No raw paths or text
were retained here. The archive and source-view paths use these shapes. The
source reader derives only a validated filename inside the verified session's
sidecar directory; it never opens the path printed in the record.

## Tool input lookup

Private read-only fixture capture on 2026-11-22 confirmed Claude
`message.content[].tool_use.input` objects, Codex function-call argument strings,
and Copilot tool-start argument objects. Committed checks use synthetic fixtures
only. Claude parser v9 records an address for the argument object rather than
using command/path text as the full input. Codex v5 and Copilot v3 record an
address when clipping arguments. Their existing preview and event keys are
unchanged. An authorized replay adds addresses to older live records; it cannot
restore argument bodies from deleted originals.

## Structured file and command evidence

Private sanitized captures on 2026-11-22 confirmed Claude Bash command strings,
Read/Write/Edit file paths, Edit before/after strings, block-level tool result
IDs and booleans, and numeric completion duration in some single-result
envelopes. Copilot captures confirmed Bash command and View/Edit path fields
and tool completion IDs with explicit success booleans. Prior Codex sanitized
captures verified the string argument envelope; specific exec/patch and
completion variants here follow SPEC §5.5 and synthetic replay tests rather than
a fresh positive live sample. No missing duration or exit code is inferred.

Claude parser 10, Codex 6 and Copilot 4 add bounded action fields without changing
the original transcript keys or token arithmetic. The next authorized replay
fills these summaries for old live sources. Matching Claude resume copies and
immutable Copilot records can fill missing evidence without replacing the text.
