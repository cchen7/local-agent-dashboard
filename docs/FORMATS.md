# Observed formats

## Evidence boundary

The public notes describe record shapes and accounting rules. Local capture paths, launcher configuration, model inventories, session identifiers and raw transcripts are not needed to implement an adapter and are not included here. Checked-in parser tests use synthetic data.

## Codex environments (EXP-1)

- The CLI and desktop app can write to one root. Treat separate roots as separate sources; when profiles share a root, label records using explicitly configured environment rules.
- Modern rollouts start with `session_meta`. Older first records were observed with `id,timestamp` (sometimes also a null `instructions`) and no `type`. Do not silently treat these as supported modern rollouts.
- Ordinary JSONL and compressed `.jsonl.zst` files were observed in both the source and archive layout. Compressed envelopes can include `ordinal` alongside `type,timestamp,payload`. Tolerate unknown fields. This evidence is why the package includes a bounded, vendored zstd decoder.
- `session_meta.originator` and `source` identify an entry point; `source` can also be a structured subagent object with `thread_spawn` or `other`. Neither field identifies an account or backend. `model_provider` may be missing, and a resumed session can retain an old provider label even if its launcher has changed.
- `turn_context.model` identifies the recorded model. Counts of turn-context records are neither token totals nor distinct session counts. Do not infer model routing or credentials from these fields.

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

For Claude Code, the local response records matched the index; an independent
CLI comparison still needs a statistics source covering the same window with
cache counters. This is a known limitation of the 0.1.0 validation.

For the six overlapping Copilot samples, the app totals matched the native
reference. Where raw SQLite rows disagreed, the CLI's own cumulative accounting
snapshots corroborated the event stream, including the cache components. Do not
deduplicate arbitrary calls merely because they have similar timestamps or
counter values.

## Source access and scope

The sandboxed app can verify access to local Claude Code, Codex and Copilot CLI
directories without opening session content. A successful directory check is
not evidence that a transcript was indexed or that its accounting matches.
Grok Build format capture and adapter acceptance are deferred.

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
