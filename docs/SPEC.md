# Agent Dashboard — Development Specification (for coding agents)

| Item | Value |
|---|---|
| Version | 1.1 (2026-11-17; status precedence clarified with product-owner approval; decisions D-1, D-2, D-4, D-5, D-6 confirmed, see §17 and DECISIONS.md) |
| Product owner | Xin Chen |
| Platform | macOS 27 only, Apple silicon (arm64) only |
| Design | Figma "Agent Dashboard – macOS 原型": https://www.figma.com/design/X48cH7JgDwxYzOWtzhtJkw |
| One-liner | A fully local, zero-network, read-only native macOS app that collects every local coding agent's sessions and token usage, gives one place to search and read them, draws a live token-usage chart, and estimates cost from vendor list prices. |

---

## 0. How to use this document (read first)

1. **This document is the single source of truth.** The Figma prototype defines look and layout only. If they disagree, this document wins. §18 lists where the prototype must be adjusted.
2. **MUST / MUST NOT / SHOULD / MAY** follow RFC 2119.
3. Every requirement has an ID (`SEC-`, `FR-`, `NFR-`, `ADP-`, `EXP-`). Reference IDs in commit messages, test names and PR descriptions.
4. **The hard constraints in §2 are never negotiable.** When in doubt, choose the option with fewer permissions, fewer dependencies and read-only behavior.
5. If something is not covered here, make the most conservative decision, record it in `docs/DECISIONS.md` (one short paragraph with the reason) and keep going. Do not stop and wait.
6. Do not add features that are not specified. In particular, never add AI/LLM capabilities (SEC-6).
7. **The agents' on-disk formats are undocumented and change between versions.** §5 was compiled from public sources in November 2026. **Before implementing each adapter, verify it against real files on the developer machine** (fixture capture, §15.2). When reality differs, real files win; update this document, `docs/FORMATS.md` and the tests.
8. Run the acceptance checklist in §15 before closing each milestone (§16).

---

## 1. Product overview

### 1.1 User and pain points

The user runs several coding agents side by side — Claude Code, Codex (CLI and desktop app), GitHub Copilot CLI and Grok Build. Sessions are numerous and scattered across directories and each agent's own storage; some agents also run in separate environments. Pain points:

- **Can't find things:** which agent and which session discussed X?
- **Can't see the state:** for each session — **which directory**, **what it is about**, **what the latest progress is**.
- **Can't control usage:** how fast tokens are burning right now, how much was used today/this week/this month, what that costs, which agent and which project use the most.

### 1.2 Goals (v1)

- G1 Auto-discover each agent's local sessions and usage data; index incrementally and in near real time.
- G2 **Unified full-text search** across agents, directories and environments; must work well for both Chinese and English.
- G3 **Read-only** session view: directory, branch, environment, main topics, latest progress, full transcript.
- G4 Per-project (directory) aggregation: "what have all agents done in this project lately?"
- G5 Live token-throughput chart (car-dyno style) with multiple periods; peak, total (cache included), cache hit rate, share, and comparison with the previous period.
- G6 A compact menu bar panel.
- G7 Cost estimates from vendor API list prices; the price table is a static file that an agent can update periodically (§8.4–8.5).

### 1.3 Non-goals (v1)

- Any network feature: auto-update, crash reporting, analytics, fetching prices or exchange rates.
- Any AI feature (summaries, Q&A, semantic or vector search).
- Telemetry (OpenTelemetry etc.): not received, not parsed. Only the session files agents keep on disk are read.
- Modifying, deleting or moving any agent file; launching or resuming agents (only "Copy Resume Command").
- Saving or sharing session transcripts from the dashboard.
- Cloud sessions (Copilot cloud agent, Codex cloud, anything running remotely).
- Reconciling with real bills: cost is an estimate from API list prices; subscription spend differs.
- Gemini CLI / Antigravity and Cursor (the user does not use them).
- Older macOS versions, Intel Macs, Mac App Store distribution.

---

## 2. Hard constraints (MUST, never broken)

| ID | Constraint | How it is enforced |
|---|---|---|
| SEC-1 | **Zero network.** The app never opens or accepts a network connection, including localhost. | App Sandbox ON; entitlements MUST NOT contain `com.apple.security.network.client` or `com.apple.security.network.server`. Without them the kernel denies network access. Checked in CI (§14.4). |
| SEC-2 | No networking APIs in code. | CI grep forbids: `URLSession`, `NSURLConnection`, `import Network`, `NWConnection`, `NWListener`, `CFSocket`, `CFStream`, `socket(`, `getaddrinfo`, `WKWebView`, `SFSafariViewController`. |
| SEC-3 | **Read-only** access to agent files. | Open with read-only APIs (`FileHandle(forReadingFrom:)` etc.). Read other apps' SQLite files only from a snapshot copy (§6.6). No file locks, no timestamp changes. |
| SEC-4 | No third-party SDKs. Dependency allow-list: GRDB.swift (pinned). A zstd decoder (BSD, vendored as source) is allowed **only if** `.jsonl.zst` files actually exist on the machine. | `Package.resolved` committed; CI checks the dependency list. |
| SEC-5 | No child processes (`Process`, `posix_spawn`), no Apple Events. | CI grep. Opening other apps only via `NSWorkspace` URLs (§11.2). |
| SEC-6 | No embedded AI: no model calls of any kind, including the on-device Foundation Models framework (not needed here, and Apple Intelligence is not enabled on the user's China-region Mac) and NaturalLanguage embeddings/classifiers. "Main topics" and "latest progress" use deterministic rules (§10). | Code review; CI grep for `FoundationModels`, `NLEmbedding`, `CoreML`, `CreateML`. |
| SEC-7 | Session content lives only in the app's own sandbox container. No Spotlight indexing, no iCloud/CloudKit, no shared locations. | No Core Spotlight; no iCloud entitlements. |
| SEC-8 | No session content in logs. | `os.Logger` only; every content interpolation uses `privacy: .private`; no custom log files. |

---

## 3. Platform and stack

| Item | Decision |
|---|---|
| Deployment target | macOS 27.0; `ARCHS = arm64`. **No `#available` checks or back-compat branches.** |
| Toolchain | Swift 6.x bundled with Xcode 27; Swift 6 language mode, `StrictConcurrency = complete`. |
| UI | SwiftUI first (`NavigationSplitView`, `MenuBarExtra` with `.window` style, `Settings` scene, `.searchable(text:tokens:)`). Wrap `NSTableView` via `NSViewRepresentable` if very long transcripts need it. |
| Charts | Swift Charts (`LineMark`, `AreaMark`, `BarMark`, `RuleMark`, `PointMark`, `.interpolationMethod(.monotone)`). |
| Storage | SQLite (WAL) via GRDB.swift; FTS5 with a custom tokenizer (§9.2). |
| File watching | FSEvents (`FSEventStreamCreate`, `kFSEventStreamCreateFlagFileEvents`, latency 0.3–0.5 s). |
| Compression | Apple `Compression` (LZFSE) for archived large tool outputs. |
| Launch at login | `SMAppService.mainApp`. |
| Tests | Swift Testing (unit) + XCTest (performance, UI smoke). |
| Distribution | Developer ID signing + Hardened Runtime + notarization (notarization is uploaded from the developer machine; the app itself never connects). Personal use, not on the App Store. |

---

## 4. Architecture

### 4.1 Layers

```
┌──────────────────────────── App (SwiftUI) ────────────────────────────┐
│ MainWindow: Sessions / Projects / Token Usage   MenuBarPanel   Settings │
│ Onboarding                         ViewModels (@Observable, @MainActor) │
└───────────────▲───────────────────────────────────────▲───────────────┘
                │ ValueObservation (GRDB)                │ queries
┌───────────────┴──────────────┐   ┌────────────────────┴───────────────┐
│ Insights (title, topics,      │   │ Search (query parser → FTS5 SQL,    │
│ latest progress, status,      │   │ ranking, grouping by session,       │
│ files & commands)             │   │ snippets & highlights)              │
└───────────────▲──────────────┘   └────────────────────▲───────────────┘
                │                                       │
┌───────────────┴───────────────────────────────────────┴───────────────┐
│ Store (GRDB DatabasePool, migrations, FTS5, rollups, archive, pricing) │
└───────────────▲───────────────────────────────────────────────────────┘
                │ normalized records (idempotent upserts)
┌───────────────┴───────────────────────────────────────────────────────┐
│ Ingest (sources, FSEvents, incremental tailer, checkpoints, dedupe)    │
└───────────────▲───────────────────────────────────────────────────────┘
                │ one adapter per agent
┌───────────────┴───────────────────────────────────────────────────────┐
│ Adapters: ClaudeCode | Codex | Copilot | GrokBuild | (more later)      │
└───────────────────────────────────────────────────────────────────────┘
```

### 4.2 Modules (local Swift package `AgentDashKit`)

| Module | Responsibility | Depends on |
|---|---|---|
| `ADCore` | Domain models (`Source`, `Session`, `Event`, `TokenEvent`, `AgentKind`, `SessionStatus`, …), time and path utilities | — |
| `ADAdapters` | Discovery rules and parsers per agent; emit normalized records | ADCore |
| `ADStore` | Database, migrations, writes, queries, rollups, archive | ADCore, GRDB |
| `ADIngest` | Source lifecycle, FSEvents, tailer, checkpoints, scheduling | ADCore, ADAdapters, ADStore |
| `ADSearch` | Query syntax, FTS query building, ranking, snippets | ADCore, ADStore |
| `ADInsights` | Titles, keywords, latest progress, status inference | ADCore, ADStore |
| `ADPrivacy` | Secret-masking rules, excluded paths | ADCore |
| `ADPricing` | Price table loading and validation, model matching, cost calculation (shared by the app and `Tools/pricing`) | ADCore |

The app target depends only on `AgentDashKit` and never touches SQL directly.

### 4.3 Concurrency

- `IngestCoordinator` is an `actor` that owns all sources and tailers. Parsing runs in background tasks: serial per file, parallel across files (concurrency = number of performance cores).
- All writes go through GRDB `DatabasePool`'s single writer, batched (≤ 500 records or ≤ 200 ms per transaction).
- The UI subscribes with `ValueObservation`; view models are `@MainActor @Observable`.
- Closing the window leaves the app running in the menu bar; ingestion continues.

---

## 5. Data sources and adapters

### 5.1 The Source model (handles "agents with their own environments")

A **Source** = one agent kind + one root directory + one environment label. An agent kind can have several sources.

```swift
struct Source {
  var id: Int64
  var agent: AgentKind                    // .claudeCode / .codex / .copilot / .grokBuild / ...
  var label: String                       // display name, e.g. "Claude Code", "Codex · work"
  var rootURL: URL                        // e.g. ~/.claude
  var environment: String                 // "Local", "Docker: devbox", "VM: ubuntu", "Synced from MacBook", ...
  var pathMappings: [PathMapping]         // in-environment path → host path, e.g. /workspace → ~/code
  var environmentRules: [EnvironmentRule] // tag sessions inside one root by record fields (EXP-1)
  var access: AccessKind                  // .defaultLocation (sandbox exception) / .bookmark(Data)
  var enabled: Bool
}
struct PathMapping { var from: String; var to: String }   // longest prefix wins
struct EnvironmentRule { var field: String; var equals: String; var environment: String }
// e.g. field "model_provider", equals "azure", environment "Work"
```

Scenarios covered (FR-SRC-1):

1. **Default locations:** `~/.claude`, `~/.codex`, `~/.copilot`, `~/.grok` are discovered automatically.
2. **Custom config directories:** the user set `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `COPILOT_HOME`, `GROK_HOME`, etc. A sandboxed app cannot read the user's shell environment, so the user adds that directory in Settings.
3. **Containers / VMs / dev containers:** if the agent's data directory is mounted or synced onto the host (bind mount, shared folder, sync folder), the user adds it as a Source with an environment label and path mappings. A container `cwd` such as `/workspace/api` is shown as the mapped host path.
4. **Desktop apps / other entry points:** Codex desktop app and Copilot App share the CLI's directory. The record's origin field (Codex `originator`, Copilot `producer`) distinguishes them; the UI shows them as entry points of the same agent.
5. **Data not on this Mac** (remote servers, cloud sandboxes): not supported in v1 (no network). The user may sync the directory locally and use scenario 3.
6. **Several environments mixed in one directory:** e.g. several Codex profiles sharing `~/.codex`. `environmentRules` tag sessions by record fields (such as `model_provider` or `originator`); rules are editable in Settings.

#### 5.1.1 Exploration task EXP-1: the user's two Codex environments (do this on the developer machine before M1)

Background: the user's Codex has two environments. It is unclear whether they keep separate session storage; it looks like they share one. Codex supports several ways to separate environments:

- A different `CODEX_HOME`: separate login, config and session history.
- Profiles inside one `CODEX_HOME`: `~/.codex/<name>.config.toml`, selected with `--profile`; sessions go to the same `sessions/` folder.
- The desktop app and the CLI share `~/.codex`; records differ by `originator`.

Steps (in a terminal on the developer machine, not inside the app):

1. Find all possible Codex roots: `ls -d ~/.codex*`; search `~/.zshrc`, `~/.zprofile`, `~/.bashrc` etc. for `CODEX_HOME` and for aliases containing `codex`; run `find ~ -maxdepth 5 -type f -name 'rollout-*.jsonl' -not -path '*/.codex/*'` to find sessions outside the default root.
2. List profiles: `ls ~/.codex/*.config.toml`, plus `model_provider` and `[model_providers.*]` in `config.toml`.
3. Tabulate the distinguishing fields across all rollouts: combinations and counts of `session_meta` `originator`, `source`, `model_provider`, `cli_version`; distribution of `turn_context.model`.
4. Implement according to the result:
   - A second root exists → add it as a second Source; confirm the environment label with the user.
   - One root, but fields distinguish the environments → generate default `environmentRules` from the findings.
   - Records cannot be told apart → document it in `docs/FORMATS.md` and let the user assign environments by `cwd` prefix.
5. Write the findings to the "Codex environments" section of `docs/FORMATS.md`. Attach the table to the PR (**field values and counts only — never session content**).

### 5.2 Discovery and access (FR-SRC-2)

- Default locations are read through the read-only entitlement `com.apple.security.temporary-exception.files.home-relative-path.read-only` (§12.1).
- Other directories are picked with `NSOpenPanel` (`canChooseDirectories = true`, `showsHiddenFiles = true`) and stored as security-scoped bookmarks. Bookmarks are resolved at launch; a stale bookmark is flagged red in Settings with a "Grant access again" action.
- The first-run onboarding (§11.7) lists the detected locations and their session-file counts.

### 5.3 General parsing rules (all adapters)

| ID | Rule |
|---|---|
| ADP-1 | **Tolerant:** unknown record types, missing fields and malformed lines never crash or stop ingestion. Unknown records are stored as `kind = unknown` (raw JSON truncated to 2 KB) and counted in the Settings → Sources health panel. |
| ADP-2 | **Incremental:** for append-only JSONL, remember `(inode, size, offset)` per file and read only new bytes. Do not consume a final line without a trailing newline yet. If the file shrinks or the inode changes, treat it as rewritten and re-parse from the start (dedupe keys keep it idempotent). |
| ADP-3 | **Idempotent:** every normalized record has a deterministic `dedupe_key`; writes use `INSERT … ON CONFLICT DO NOTHING/UPDATE`. Parsing the same file twice yields identical results. |
| ADP-4 | **Parser versions:** each adapter has `parserVersion`. When it changes, files that still exist are re-parsed automatically. |
| ADP-5 | **Time:** store UTC epoch milliseconds as integers. Records without a timestamp inherit the previous record's. Transcript order follows file order (`seq`); statistics use timestamps. |
| ADP-6 | **Performance:** skip large useless records with a substring check before JSON decoding (e.g. Claude `file-history-snapshot`). Decode only the fields you need; ignore the rest. |
| ADP-7 | **Truncation:** searchable text keeps at most 2 KB per tool output; the archive keeps up to 64 KB compressed (configurable); anything beyond is read from the original file on demand while it still exists. |

### 5.4 Adapter: Claude Code (ADP-CC)

| Item | Details |
|---|---|
| Root | `~/.claude` (user may add other roots, e.g. a custom `CLAUDE_CONFIG_DIR`) |
| Session files | `projects/<encoded-path>/<session-uuid>.jsonl` — one file per session, append-only |
| Subagents | Newer versions: `projects/<…>/<session-uuid>/subagents/agent-*.jsonl` with `agent-*.meta.json` (`agentType`, `description`). Older versions: `projects/<…>/agent-*.jsonl`. Index both separately and link `parent_session_id` when the parent ID is known. |
| Large tool outputs | `projects/<…>/<session-uuid>/tool-results/*.txt`: not indexed; read on demand when viewing. |
| Prompt history | `~/.claude/history.jsonl`: one line per prompt the user typed (timestamp + project path). Index as "prompt history" records so prompts stay searchable after transcripts are cleaned up. |
| Directory | **Never derive the path from the folder name** (`/` and `.` both become `-`; it cannot be reversed). Use each record's `cwd`; same for `gitBranch` and `version` (take the latest non-null value; `cwd` can change mid-session — record the change). |
| Record types | `user`: string `message.content` is a typed prompt (but `isMeta = true` means injected context, not user input); array content holds `tool_result` blocks (`is_error` = failure). `assistant`: `message.content` has `text` / `thinking` / `tool_use`; plus `message.usage`, `message.model`, `message.id`, `requestId`, `stop_reason`. `summary`: compaction summary (no timestamp). `system`: hook output, errors. `file-history-snapshot`, `attachment`, `queue-operation` and others: skip or store as unknown. |
| Tokens | `message.usage`: `input_tokens` → `input_fresh`; `cache_read_input_tokens` → `cache_read`; `cache_creation_input_tokens` → `cache_write`; `output_tokens` → `output`. If `usage.cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` exist, map them to `cache_write` / `cache_write_1h` (their sum should equal `cache_creation_input_tokens`) so they can be priced separately. |
| ⚠️ Trap 1 | **One API response is split across several lines** (one per content block), and every line repeats the same `message.id` and the same `usage`. **Dedupe by `message.id`** (fallback `requestId`, then `uuid`), otherwise totals are 2–3× too high. |
| ⚠️ Trap 2 | **Resuming a session copies the whole previous conversation into the new file.** Dedupe events globally by `uuid` and tokens by `message.id`. Mark the new session "continued from <original>" and collapse the inherited part in the transcript. |
| ⚠️ Trap 3 | Timestamps are not guaranteed to be in order (see ADP-5). |
| ⚠️ Trap 4 | **Claude Code deletes transcripts older than 30 days by default** (`cleanupPeriodDays`). The app must archive (§6.4). |
| Thinking | Not indexed by default (Settings toggle). |
| Status signals | `stop_reason = tool_use` with no later matching `tool_result` → tool running or waiting for approval; `end_turn` → turn finished; API-error records → failed. |
| Resume command | `cd "<cwd>" && claude --resume <sessionId>` |

### 5.5 Adapter: Codex (CLI and desktop app) (ADP-CX)

| Item | Details |
|---|---|
| Root | `~/.codex` (user may add the directory a `CODEX_HOME` points to; see EXP-1) |
| Session files | `sessions/YYYY/MM/DD/rollout-<time>-<uuid>.jsonl`; `archived_sessions/rollout-*.jsonl` (archived sessions, flat). Some versions may write compressed `.jsonl.zst` — **check whether any exist on the machine first**; only then add zstd (SEC-4) and treat those files as immutable. |
| Validation | The first line must have `type = session_meta`; otherwise skip the file. |
| Envelope | `{ "timestamp", "type", "payload" }` |
| `session_meta` | `payload.id` (session id), `cwd`, `originator` (CLI vs desktop app etc.), `cli_version`, `source`, `model_provider`, and git info when present (commit, branch, repository URL). |
| `turn_context` | `model`, `effort`, `approval_policy`, `sandbox_policy`, `cwd`: the model used per turn. |
| Transcript text | **Use `event_msg`:** `user_message` (`payload.message`) and `agent_message` (`payload.message`). `response_item` records with `type = message` are model-facing copies (assistant ones duplicate `agent_message`; user ones are mostly injected environment context). **Never index both channels or every reply appears twice.** Fall back to `response_item` only for sessions that have no `event_msg` at all. |
| Tools | `response_item` `function_call` / `custom_tool_call` (`name`, `arguments` as a JSON string, `call_id`) paired with `*_output` by `call_id`. `exec_command` → command; `apply_patch` → file changes (parse patch headers for paths and +/- line counts). MCP calls: join `namespace` and `name` into `mcp__<server>__<tool>`. |
| Other events | `task_started`, `task_complete` (`last_agent_message`, `duration_ms`), `exec_command_end`, `patch_apply_end`, error events, `compacted` (compaction summary). |
| Tokens | `event_msg` with `payload.type = token_count`: **use only `info.last_token_usage`** (this response); `info.total_token_usage` is for reconciliation only. `input_tokens` **includes** cached input: `input_fresh = input_tokens − cached_input_tokens`, `cache_read = cached_input_tokens`, `output = output_tokens`, `reasoning = reasoning_output_tokens` (part of output — do not add it again). |
| ⚠️ Trap | `info` may be `null`: such events carry no tokens (still read their `rate_limits`). If `total_token_usage.total_tokens` equals the previous event's, it is a duplicate emission — skip. **Never sum `total_token_usage` across events** (grows quadratically). |
| Rate limits | `rate_limits` on `token_count` events: `primary` / `secondary` with `used_percent`, `window_minutes`, `resets_at`, plus `plan_type` etc. Store in `rate_limit_snapshots` for the headroom readout (§11.4). |
| Context | `info.model_context_window` + latest input size → context usage %. |
| Metadata DB | `~/.codex/state.sqlite` (thread titles, git info; schema as found locally). **Optional:** read from a snapshot (§6.6) to enrich titles; failures must not affect ingestion. |
| Resume command | `cd "<cwd>" && codex resume <id>` |

### 5.6 Adapter: Grok Build (ADP-GK)

| Item | Details |
|---|---|
| Root | `~/.grok` (`GROK_HOME` can relocate it; user may add custom roots) |
| Session folders | `sessions/<URL-encoded cwd>/<session-id>/` — one folder per session, grouped by working directory. Session ids are usually UUIDv7. |
| Directory | URL-decode the group folder name to get `cwd`. If the encoded name exceeds 255 bytes, the group folder is "slug + hash" and the original path is stored in a `.cwd` file inside it — **when `.cwd` exists, it wins**. |
| `summary.json` | Session index: summary and generated title, model ID, created/updated timestamps, message counts, parent reference for forked or restored sessions → title, model, times, parent/child links. Rewritten as a whole; handle as "rewritten" per ADP-2. |
| `updates.jsonl` | **Authoritative conversation log** (ACP session-update stream: conversation + tool calls), append-only → transcript, tool calls, incremental reads. Messages may arrive as streamed chunks; join by message id before indexing. |
| `chat_history.jsonl` | Raw messages sent to the model; duplicates `updates.jsonl` — **do not index**; fallback only when `updates.jsonl` is missing. |
| `signals.json` | Session-level token usage and tool/turn counters (cumulative). |
| `plan.json` | Todo list (pending / in progress / completed / cancelled) → show current todos under "latest progress". |
| Skip | `rewind_points.jsonl` (file snapshots, large), `feedback.jsonl`, `compaction_checkpoints/`. `subagents/` holds only subagent metadata; child sessions live in the normal sessions tree and are linked through the parent reference. |
| Tokens (preferred) | If `updates.jsonl` or `chat_history.jsonl` carries per-response usage fields (names as found locally), record per call with `precision = call`. |
| Tokens (fallback) | `signals.json` is cumulative. While the app runs, diff it on every change and record the delta at that time (`precision = snapshot`). Deltas accumulated while the app was not running are recorded at the `summary.json` updated time (`precision = checkpoint`). A decrease means the session was rewound — never emit negative values. Whether input includes cached tokens must be verified locally and written to `docs/FORMATS.md`. |
| ⚠️ Trap | `/rewind` truncates the conversation; `/fork` copies it into a new session → dedupe events by id, mark the new session "forked from <original>", collapse the inherited part. |
| Resume command | `cd "<cwd>" && grok --resume <session-id>` |

### 5.7 Adapter: GitHub Copilot CLI (ADP-CP)

| Item | Details |
|---|---|
| Root | `~/.copilot` (user may add the directory a `COPILOT_HOME` points to). The macOS Copilot App uses the same layout; `producer` and similar fields tell the entry points apart. |
| Session files | `session-state/<session-id>/events.jsonl` (append-only during a session; may be recreated on restart); sibling `workspace.yaml` (user-renamed title etc.; fields as found locally), plans, checkpoints. |
| Metadata DB | `session-store.db` (SQLite): **optional**, snapshot read for enrichment. |
| Envelope | `{ "type", "data", "id", "timestamp", "parentId", "agentId"? }` |
| Main events | `session.start` (`sessionId`, `copilotVersion`, `startTime`, `context.cwd`, …), `session.resume`, `session.context_changed`, `user.message` (`content` is what the user typed; `transformedContent` includes injected context — **index `content` only**), `assistant.message`, `assistant.turn_start` / `turn_end`, `tool.execution_start` (`toolName`, `arguments`) / `tool.execution_complete` (success), `session.task_complete` (`summary`, `success` — the agent's own completion summary, used directly as "latest progress"), `session.compaction_complete`, `session.model_change`, `subagent.started` / `completed`, `skill.invoked`, `session.shutdown`. |
| Tokens (preferred) | Per-call `session.usage_record` events (field names as found locally); dedupe by event `id`. |
| Tokens (fallback) | `data.modelMetrics` on `session.shutdown` (and `session.usage_checkpoint`): per model `usage.inputTokens / outputTokens / cacheReadTokens / cacheWriteTokens / reasoningTokens`. **These are cumulative:** a resumed session appends more shutdown events, so diff consecutive events per model and keep only increases; ignore repeated event ids and decreasing values. Fallback data has session-level time precision; record it at the shutdown time with `precision = checkpoint` (drawn with hatching, §11.4). |
| ⚠️ Accounting | `inputTokens` **includes** cache reads and writes: `input_fresh = inputTokens − cacheReadTokens − cacheWriteTokens`; `reasoningTokens` is part of `outputTokens`. Records stamped with `agentId` (subagents) are already included in the parent totals — **do not count them twice**. |
| Resume command | `cd "<cwd>" && copilot --resume <sessionId>` |

### 5.8 Future adapters (not in v1; keep the interface ready)

Possible later: VS Code Copilot Chat (`~/Library/Application Support/Code/User/workspaceStorage/<hash>/chatSessions/`; no per-request token counts stored locally, estimate only), Aider, OpenCode. **Explicitly out of scope:** Gemini CLI / Antigravity, Cursor. Adding an agent = one new type conforming to `AgentAdapter` + fixtures + tests, **without changing core logic in other modules**.

```swift
protocol AgentAdapter: Sendable {
  static var kind: AgentKind { get }
  static var parserVersion: Int { get }
  /// Find this agent's session files (and optional sidecar files) under a root
  func discover(root: URL) async throws -> [SourceFile]
  /// Parse one file from a checkpoint and emit normalized records; must be idempotent
  func parse(_ file: SourceFile, from checkpoint: Checkpoint?) -> AsyncThrowingStream<NormalizedRecord, Error>
  /// Text for "Copy Resume Command"
  func resumeCommand(for session: SessionRecord) -> String?
}
```

---

## 6. Data storage (decided)

### 6.1 Decision and rationale

**Decision:** raw data always stays in each agent's own directory, read-only. The app keeps **its own SQLite database** (WAL mode, accessed through GRDB) holding normalized sessions, events, token records, rollups, an FTS5 full-text index, and a **long-term archive** of sessions whose source files have been deleted.

| Option | Verdict | Reason |
|---|---|---|
| SQLite + GRDB + FTS5 | ✅ chosen | Local and mature; FTS5 supports custom tokenizers (Chinese), snippets and bm25 ranking; fast bulk writes; `ValueObservation` suits a live UI. |
| SwiftData / Core Data | ❌ | No full-text search; hard to control bulk inserts and aggregate queries at millions of rows. |
| Core Spotlight | ❌ | Puts private content into a system-wide index; violates SEC-7. |
| Re-scan raw files every time | ❌ | Slow, and Claude Code deletes raw transcripts after 30 days by default, so history would be lost. |
| Whole-database encryption (SQLCipher) | ❌ (v1) | The raw data is already plaintext on this Mac; the database sits in the sandbox container, which macOS (14+) protects from other apps without user consent; FileVault covers the disk. §12 adds masking and exclusions. |

### 6.2 Location and files

```
~/Library/Containers/<bundle-id>/Data/Library/Application Support/AgentDashboard/
  ├── index.sqlite          # the only database (archive, index, rollups)
  ├── index.sqlite-wal
  ├── index.sqlite-shm
  └── snapshots/            # temporary copies of other apps' SQLite files; deleted after use
```

Settings live in `UserDefaults`; security-scoped bookmarks live in the `sources` table.

### 6.3 Schema (initial migration `v1`)

```sql
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE sources (
  id INTEGER PRIMARY KEY,
  agent TEXT NOT NULL,                 -- claude_code | codex | copilot | grok_build | ...
  label TEXT NOT NULL,
  root_path TEXT NOT NULL,
  environment TEXT NOT NULL DEFAULT 'Local',
  path_mappings_json TEXT NOT NULL DEFAULT '[]',
  env_rules_json TEXT NOT NULL DEFAULT '[]',    -- EnvironmentRule list (EXP-1)
  access_kind TEXT NOT NULL,           -- default_location | bookmark
  bookmark BLOB,
  enabled INTEGER NOT NULL DEFAULT 1,
  last_scan_at INTEGER, status TEXT, last_error TEXT,
  UNIQUE(agent, root_path)
);

CREATE TABLE source_files (
  id INTEGER PRIMARY KEY,
  source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  rel_path TEXT NOT NULL,
  role TEXT NOT NULL,                  -- session | subagent | prompt_history | sidecar | metadata_db
  inode INTEGER, size INTEGER, mtime_ns INTEGER,
  read_offset INTEGER NOT NULL DEFAULT 0,
  last_seq INTEGER NOT NULL DEFAULT -1,  -- preserve file order across restarts (ADP-2/5)
  previous_ts INTEGER,                 -- preserve inherited UTC timestamp across restarts
  parser_version INTEGER NOT NULL,
  state TEXT NOT NULL,                 -- ok | partial | error | gone
  unknown_records INTEGER NOT NULL DEFAULT 0,
  last_error TEXT,
  UNIQUE(source_id, rel_path)
);

CREATE TABLE projects (
  id INTEGER PRIMARY KEY,
  key TEXT NOT NULL UNIQUE,            -- normalized repository URL if known, else root path
  root_path TEXT,                      -- host path (after path mapping)
  display_name TEXT NOT NULL,          -- default: last path component
  repo_url TEXT,
  first_seen_at INTEGER, last_active_at INTEGER,
  pinned INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE sessions (
  id INTEGER PRIMARY KEY,
  agent TEXT NOT NULL,
  native_id TEXT NOT NULL,             -- the agent's own session id
  source_id INTEGER NOT NULL REFERENCES sources(id),
  file_id INTEGER REFERENCES source_files(id),
  project_id INTEGER REFERENCES projects(id),
  parent_session_id INTEGER REFERENCES sessions(id),      -- subagents
  resumed_from_session_id INTEGER REFERENCES sessions(id), -- resume / fork
  entrypoint TEXT,                     -- cli | desktop | app | ... (from originator/producer)
  environment TEXT NOT NULL,
  cwd TEXT, git_branch TEXT, git_sha TEXT,
  title TEXT, title_source TEXT,       -- agent | first_prompt | user
  first_prompt TEXT,
  started_at INTEGER, last_event_at INTEGER, ended_at INTEGER,
  status TEXT NOT NULL,                -- running | waiting | completed | failed | unknown
  status_reason TEXT,                  -- e.g. pending_tool_approval | turn_ended | error
  model_primary TEXT, cli_version TEXT,
  turn_count INTEGER DEFAULT 0, message_count INTEGER DEFAULT 0, tool_count INTEGER DEFAULT 0,
  tokens_input_fresh INTEGER DEFAULT 0, tokens_cache_read INTEGER DEFAULT 0,
  tokens_cache_write INTEGER DEFAULT 0, tokens_cache_write_1h INTEGER DEFAULT 0,
  tokens_output INTEGER DEFAULT 0, tokens_reasoning INTEGER DEFAULT 0,
  cost_micro_usd INTEGER DEFAULT 0,    -- list-price estimate (§8.4), 1e-6 USD
  context_window INTEGER, context_used INTEGER,
  latest_summary TEXT,                 -- the agent's own latest summary, if any
  source_deleted_at INTEGER,           -- when the agent cleaned up the raw file
  UNIQUE(agent, native_id)
);
CREATE INDEX sessions_last_event ON sessions(last_event_at DESC);
CREATE INDEX sessions_project ON sessions(project_id, last_event_at DESC);
CREATE INDEX sessions_status ON sessions(status);

CREATE TABLE events (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL,                -- order within the file
  ts INTEGER NOT NULL,                 -- UTC ms
  kind TEXT NOT NULL,                  -- user | assistant | tool_call | tool_result | summary | system | error | prompt_history | unknown
  tool_name TEXT,
  text TEXT,                           -- searchable text (truncated per ADP-7)
  meta_json TEXT,                      -- small structured fields: command, path, +/- lines, exit code, duration, inherited flag, ...
  blob_id INTEGER REFERENCES blobs(id),
  dedupe_key TEXT NOT NULL UNIQUE
);
CREATE INDEX events_session_seq ON events(session_id, seq);
CREATE INDEX events_ts ON events(ts);

CREATE VIRTUAL TABLE events_fts USING fts5(
  text, tool_name,
  content='events', content_rowid='id',
  tokenize='agentdash'                 -- custom tokenizer, §9.2
);
-- keep events_fts in sync with events via insert/update/delete triggers

CREATE TABLE blobs (                   -- compressed archive of large tool outputs
  id INTEGER PRIMARY KEY,
  codec TEXT NOT NULL DEFAULT 'lzfse',
  raw_len INTEGER NOT NULL,
  data BLOB NOT NULL
);

CREATE TABLE file_touches (
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  path TEXT NOT NULL, op TEXT NOT NULL,         -- read | edit | write | delete
  count INTEGER NOT NULL, lines_added INTEGER DEFAULT 0, lines_removed INTEGER DEFAULT 0,
  last_ts INTEGER NOT NULL,
  PRIMARY KEY(session_id, path, op)
);

CREATE TABLE commands (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  ts INTEGER NOT NULL, command TEXT NOT NULL,
  exit_code INTEGER, duration_ms INTEGER, status TEXT
);

CREATE TABLE token_events (
  id INTEGER PRIMARY KEY,
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  agent TEXT NOT NULL, project_id INTEGER, model TEXT,
  ts INTEGER NOT NULL,
  input_fresh INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
  cache_write INTEGER NOT NULL DEFAULT 0, cache_write_1h INTEGER NOT NULL DEFAULT 0,
  output INTEGER NOT NULL DEFAULT 0, reasoning INTEGER NOT NULL DEFAULT 0,
  precision TEXT NOT NULL DEFAULT 'call',        -- call | snapshot | checkpoint
  cost_micro_usd INTEGER NOT NULL DEFAULT 0,     -- 1e-6 USD
  price_status TEXT NOT NULL DEFAULT 'unpriced', -- priced | approx | unpriced
  price_ref TEXT,                                -- matched price entry: model id + effectiveFrom
  dedupe_key TEXT NOT NULL UNIQUE
);
CREATE INDEX token_events_ts ON token_events(ts);

CREATE TABLE token_minute (            -- per-minute rollup; charts query this table
  bucket INTEGER NOT NULL,             -- UTC minute (epoch / 60)
  agent TEXT NOT NULL, project_id INTEGER NOT NULL DEFAULT 0, model TEXT NOT NULL DEFAULT '',
  input_fresh INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL,
  cache_write_1h INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL,
  cost_micro_usd INTEGER NOT NULL, unpriced_tokens INTEGER NOT NULL,
  calls INTEGER NOT NULL, has_coarse INTEGER NOT NULL DEFAULT 0,   -- contains snapshot/checkpoint data
  PRIMARY KEY(bucket, agent, project_id, model)
);
-- hour/day statistics aggregate token_minute in SQL; add materialized token_hour / token_day only if NFRs require it

CREATE TABLE rate_limit_snapshots (
  ts INTEGER NOT NULL, agent TEXT NOT NULL, limit_id TEXT NOT NULL,
  window TEXT NOT NULL,                -- primary | secondary
  window_minutes INTEGER, used_percent REAL, resets_at INTEGER, plan_type TEXT,
  PRIMARY KEY(agent, limit_id, window, ts)
);

CREATE TABLE session_keywords (
  session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  term TEXT NOT NULL, weight REAL NOT NULL,
  PRIMARY KEY(session_id, term)
);
CREATE TABLE term_df (term TEXT PRIMARY KEY, df INTEGER NOT NULL);   -- document frequency for keywords

CREATE TABLE saved_searches (id INTEGER PRIMARY KEY, name TEXT NOT NULL, query TEXT NOT NULL, sort TEXT);
CREATE TABLE app_meta (key TEXT PRIMARY KEY, value TEXT);   -- incl. pricing_hash, pricing_source, pricing_updated_at
```

### 6.4 Archive and retention (FR-STO-1)

- When an agent deletes a raw file (file gone, parent folder still present), mark the session `source_deleted_at`, **keep its content in the database**, and show an "Archived" marker in the UI.
- Retention setting: forever (default) / 365 / 180 / 90 days. Expired sessions are deleted with their events and token records; rollup tables are kept so long-range charts stay continuous.
- Settings shows the database size and offers: "Clear a project's data", "Clear a source's data", "Clear everything".

### 6.5 Two kinds of rebuild

| Action | What it does | Data loss? |
|---|---|---|
| Rebuild index | Rebuild `events_fts`, `token_minute` and keywords from the `events` / `token_events` tables | No |
| Full rescan | Re-parse raw files (idempotent upserts); archived sessions are kept | No |

### 6.6 Reading other apps' SQLite (Codex `state.sqlite`, Copilot `session-store.db`)

A WAL-mode database still needs to write its `-shm` file even when opened read-only, which the read-only sandbox exception does not allow. Copy `x.sqlite`, `-wal` and `-shm` into `snapshots/`, open the copy with `mode=ro`, delete it afterwards. Refresh at most every 60 s. Failures are only shown in the health panel and never block ingestion.

---

## 7. Ingestion pipeline (near real time)

1. **Launch:** resolve every source's access → run `discover` on each root → diff against `source_files` → queue new and changed files, **most recently modified first** so recent sessions appear quickly.
2. **Watch:** one FSEvents stream per root. Use validated, private root-relative file hints to debounce per file (JSONL 300 ms; whole-file JSON rewrites 1 s). Rescan the root on lost, coalesced or ambiguous events. File hints are not authorization to open a path.
3. **Read:** JSONL incrementally per ADP-2; rewritten JSON files are re-parsed and upserted by dedupe key.
   JSONL checkpoints retain file identity, parser version, previous timestamp and bounded decoder state. Only complete lines advance the position. A batch that loses a race to another scan cannot change indexed records or the checkpoint.
4. **Write:** batch normalized records; in the same transaction update `sessions` aggregates, `token_minute`, `file_touches`, `commands`, and cost fields.
5. **Derive:** after new events, recompute status after a 2 s debounce (§10.4) and keywords after 30 s (§10.2).
6. **Timers:** every 15 s re-evaluate status of running/waiting sessions (silence alone changes status); every 60 s refresh metadata-DB snapshots.
7. **Progress:** during the first full index, the toolbar shows progress (files done / total, MB/s) and can be paused.

Target: **≤ 2 s** from an agent writing a file to the UI updating (NFR-2).

---

## 8. Data model, token and cost accounting

### 8.1 Token fields

| Field | Meaning |
|---|---|
| `input_fresh` | Input that did not hit the cache |
| `cache_read` | Input served from cache |
| `cache_write` | Input written to cache (5-minute cache, or all cache writes when the agent does not split them) |
| `cache_write_1h` | Input written to the 1-hour cache (only when the record splits it out; otherwise 0) |
| `output` | Output (**includes** reasoning tokens) |
| `reasoning` | Reasoning tokens; a subset of `output`, for display only, never added again |
| **total** | `input_fresh + cache_read + cache_write + cache_write_1h + output` |

### 8.2 Display rules (confirmed: totals include cache)

- Every "total" **includes cache reads and cache writes**.
- Every total can be broken down into fresh input / cache write / cache read / output (tooltip, segmented bar under the total readout, detail table).
- Cache hit rate = `cache_read ÷ (input_fresh + cache_read + cache_write + cache_write_1h)`.
- Cache savings = Σ `cache_read × (model input price − cache read price)` (requires the price table).
- Input : output = `(total − output) : output`.
- Chart metric switch: **Tokens (default) / Output only / Cost**. Readouts, curves and the table all follow the selected metric.

### 8.3 Throughput (tok/min)

- Each `token_event` lands in the minute of its timestamp.
- Smoothing happens only at display time (raw data unchanged): 1H uses a 3-minute moving average; 24H uses 5-minute buckets converted to tok/min.
- Data with `precision` other than `call` (Copilot and Grok Build fallbacks) is excluded from peak calculations and drawn separately with hatching.

### 8.4 Cost (FR-COST)

- Cost = an **estimate from the vendors' public API list prices**. The UI always labels it "estimated at list price". Subscription plans (Claude, ChatGPT, Copilot, SuperGrok, …) are billed differently.
- Each `token_event` gets its cost when written, stored as integer micro-USD (1e-6 USD); rollups accumulate it.
- Formula (prices are USD per million tokens):
  `cost = (input_fresh × input + cache_read × cacheRead + cache_write × cacheWrite5m + cache_write_1h × cacheWrite1h + output × output) ÷ 1,000,000`. Reasoning tokens are already inside `output`.
- If a cache price is missing in the table, price cache reads and writes at the input price and mark `approx`.
- Tiers: if a call's prompt tokens (`input_fresh + cache_read + cache_write + cache_write_1h`) exceed a tier's `whenPromptTokensAbove`, the whole call uses that tier. Data with non-`call` precision can only use base prices and is marked `approx`.
- No matching model → `unpriced`: cost 0, tokens counted as "unpriced tokens"; the UI warns and Settings lists those models.
- Copilot: sessions record the underlying model (claude-*, gpt-*, …); price them at that vendor's list price as an "API-equivalent cost". If records contain Copilot's own billing units (e.g. premium request counts), show them separately; never mix them into USD.
- When the price table changes (file hash differs), recompute the cost of all `token_events` and rollups in the background; the UI shows "Recalculating with new prices".
- Display currency: USD by default; may switch to a currency that the price table lists with a static rate (e.g. CNY), showing the rate date. **Exchange rates are never fetched.**

### 8.5 Price table interface (static file, updated periodically by an agent)

Price tables are UTF-8 JSON. Validation rejects duplicate decoded object member
names before decoding prices or aliases.

**Load order:**

1. External file `~/.config/agent-dashboard/pricing.json` (preferred). Read through a read-only sandbox exception (§12.1) and watched with FSEvents; edits apply immediately.
2. The bundled `pricing.json` (copied from the repository's `pricing/pricing.json` at build time), used when the external file is missing or invalid.
3. If validation fails, keep using the last valid table and show the errors in Settings → Pricing.

**Files in the repository:**

```
pricing/
├── pricing.json           # the only price data to maintain (updated by an agent)
├── pricing.schema.json    # JSON Schema
└── UPDATE_PLAYBOOK.md     # instructions for the agent that updates prices
Tools/pricing/             # command-line tools (Swift, reuse ADPricing)
├── validate               # schema, effective dates, match conflicts; prints the impact on historical cost
├── models-seen            # scan local agent records; list model IDs seen, their token volume, priced or not
└── install                # after validation, copy to ~/.config/agent-dashboard/pricing.json
```

**Format** (all prices in the example are 0 — **not real prices; do not copy**):

```json
{
  "$schema": "./pricing.schema.json",
  "schemaVersion": 1,
  "currency": "USD",
  "unit": "per_million_tokens",
  "updatedAt": "2026-11-17",
  "displayCurrencies": [
    { "code": "CNY", "ratePerUSD": 0, "asOf": "2026-11-17" }
  ],
  "aliases": { "<alias found in agent records>": "<canonical model id>" },
  "models": [
    {
      "id": "anthropic/claude-opus",
      "vendor": "anthropic",
      "displayName": "Claude Opus",
      "match": ["claude-opus-*"],
      "prices": [
        {
          "effectiveFrom": "2026-01-01",
          "input": 0, "output": 0,
          "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0,
          "tiers": [
            { "whenPromptTokensAbove": 200000, "input": 0, "output": 0,
              "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0 }
          ],
          "source": "<official vendor pricing page URL>",
          "checkedAt": "2026-11-17"
        }
      ]
    }
  ]
}
```

**Rules:**

- Prices are always `currency` (USD) per million tokens. `input`, `output`, `source`, `checkedAt` are required; the rest is optional.
- `match` holds glob patterns applied to the normalized model ID (lower-case, provider prefixes such as `anthropic/`, `openai/`, `xai/` removed). When several entries match, the most specific wins (most non-wildcard characters); ties go to the earlier entry. `aliases` are applied before `match`.
- `prices` are chosen by `effectiveFrom`: the latest entry not later than the call's date (UTC). **Updates only append new entries; existing entries are never edited**, so historical costs never change.
- A time-limited price can specify `effectiveUntil` (exclusive UTC date, strictly after `effectiveFrom`). If the selected entry has expired and no newer entry applies, mark usage unpriced. Do not fall back to an older rate.
- Within a model, `effectiveFrom` values are unique; `tiers` are sorted by threshold ascending.

**`UPDATE_PLAYBOOK.md` must describe these steps** (for the agent that updates prices):

1. Run `Tools/pricing/models-seen` to get the models actually used on this Mac.
2. Take prices only from official vendor pricing pages (Anthropic, OpenAI, xAI; for Copilot, the underlying model's vendor). No third-party aggregators.
3. Price changed → append a new `prices` entry (`effectiveFrom` = the vendor's effective date, or today if unknown). New model → add a `models` entry.
4. Update `updatedAt`; update `displayCurrencies` static rates and dates if needed.
5. Run `validate`: no errors, and `models-seen` reports no unpriced models (explain in the PR if a model has no public price). Then run `install`.
6. Open a PR listing the changed prices, their source links, and the historical-cost impact printed by `validate`.

---

## 9. Search

### 9.1 Behavior (FR-SR)

- Toolbar search field; searches as you type (150 ms debounce); Return pins the query.
- Results are grouped by session: "12 matches in 6 sessions". Each session shows its best snippet with highlighted terms.
- Opening a session scrolls the transcript to the first match; "3 of 12" with up/down arrows jumps between matches (already in the prototype).
- Sort: relevance (default) / most recent / token volume.
- A query can be saved as a "Smart Group" in the sidebar.

### 9.2 Chinese tokenization (must be done right)

FTS5's built-in `unicode61` treats a run of Chinese characters as one token, so searching "登录" misses "修复登录问题". Wrap `unicode61` with GRDB's `FTS5WrapperTokenizer`:

- CJK runs: split into **overlapping bigrams** (keep single characters for length-1 runs). "修复登录问题" → 修复 / 复登 / 登录 / 录问 / 问题. Queries use the same tokenizer, so "登录" matches; longer queries become an ordered bigram phrase, i.e. substring matching.
- Latin text and code identifiers: lower-case; besides the whole token, also emit the parts of `camelCase`, `snake_case`, `kebab-case` (`verifyAndRotate` → verifyandrotate / verify / and / rotate) so partial names match.
- Paths: split on `/` and `.`, and also keep the whole file name (`auth.ts`).
- Unit tests MUST cover: two-character Chinese words, long Chinese sentences, mixed Chinese/English, camelCase, paths, emoji.

### 9.3 Query syntax (full table in Appendix B)

Free text plus filters; filters render as tokens in the search field (`.searchable(text:tokens:)`):

`agent:claude` `project:payments-api` `dir:~/code/x` `env:work` `status:running` `role:user|assistant|tool` `tool:Bash` `file:auth.ts` `model:opus` `after:2026-11-01` `before:2026-11-15` `in:7d` `"exact phrase"` `-exclude` `A OR B`

### 9.4 Ranking

`score = best bm25(events_fts) within the session + 0.1·ln(1 + matches in session) + 0.3·exp(−age_in_days / 14)`; weights live in constants so they are easy to tune. With `role:user`, prompt-history records are searched too.

---

## 10. Session insights (deterministic rules only, no AI)

### 10.1 Title (first line of "what is it about")

Priority: title set by the user in this app → title/summary provided by the agent (Codex metadata DB title, Copilot `workspace.yaml` title, Claude `summary` record, Grok Build `summary.json` title) → first meaningful user prompt (skip slash commands, injected context, empty messages), truncated to 80 characters. `title_source` records the origin; the UI notes "from agent" or "from first prompt" in small text.

### 10.2 Main topics (keywords)

- Corpus: user prompts (weight 2), assistant text (weight 1), touched file names (weight 1.5).
- Tokens: English words (length ≥ 3, stop words removed, including common programming stop words), identifier parts, Chinese bigrams (Chinese stop bigrams removed, e.g. 我们, 这个, 一下, 可以, 需要, 然后). Stop-word lists are resource files.
- Scoring: TF-IDF with `tf = ln(1 + count)`, `idf = ln(N / (1 + df))`, N = number of sessions, `df` kept in `term_df`.
- Keep the top 5; skip a term that is a substring of a higher-ranked term.
- Shown as chips; clicking a chip searches for it.

### 10.3 Latest progress ("what are the latest updates")

Shown on the session Overview tab and on the project page:

1. The agent's own latest summary, if any (Copilot `session.task_complete.summary`, Codex `task_complete.last_agent_message`, Claude compaction summary, Grok Build `summary.json` summary). For Grok Build, also show in-progress and just-completed todos from `plan.json`.
2. The last user prompt (first 200 characters).
3. The last assistant reply (first 300 characters).
4. The last 5 actions: files changed (with +/- lines), commands run (with result and duration).
5. Current branch and last activity time.

### 10.4 Status inference

A sandboxed app cannot see other processes, so **status is inferred from file content and activity time only**; hovering the status shows the evidence. All thresholds are configurable.

| Status | Condition (evaluated in order; first match wins) |
|---|---|
| failed | The last turn ended with an error (API error, Codex turn failure/error event, last tool result is an error with no later action) |
| completed | An explicit session end event (e.g. Copilot `session.shutdown`) with no later resumed activity; or the turn ended normally and the session has been silent for > 30 min |
| waiting | A tool call has no result, has been pending for at most 10 minutes, and the session has been silent for > 15 s (reason: **possibly needs approval**, inferred); or the turn ended and the session has been silent for 60 s – 30 min inclusive (reason: **waiting for your reply**) |
| running | Last record within 60 s; or a tool call is in flight for at most 10 minutes, provided no earlier condition matched |
| unknown | None of the above |

Evaluate current activity only: a historical end/error event must not override later
resumed activity. A normal assistant turn end is not an explicit session end.
Silence alone does not prove an approval request; the badge and hover evidence must
say "possibly needs approval" unless the source has an explicit approval signal.
Track concurrent explicit approvals by call ID. A tool result clears only its
matching scoped approval; an unscoped request is tracked separately.
An unanswered tool older than 10 minutes, with no newer activity or other signal,
becomes `unknown`. At exactly 15 s the silence-based approval inference does not apply.

"Needs input" in the menu bar = waiting with reason "possibly needs approval",
an explicit "needs approval" signal, or "waiting for your reply"; preserve the
inference qualification in the displayed evidence.

### 10.5 Files and commands

Extracted from tool calls: Claude `Read`/`Edit`/`Write`/`MultiEdit`/`Bash`, Codex `exec_command`/`apply_patch`, Grok Build tool calls in `updates.jsonl`, Copilot `tool.execution_*`. Line counts: Claude `Edit` diffs `old_string` vs `new_string` by line; Codex `apply_patch` counts `+`/`-` lines in the patch.

### 10.6 Context usage

Shown only when determinable: "latest request's total input ÷ model context window". Codex provides `model_context_window`; for other agents use the local "model → context window" table in Settings (user-editable, prefix match on model name). Otherwise show "—".

---

## 11. UI specification

Design: Figma file `X48cH7JgDwxYzOWtzhtJkw`. Read node sizes and styles with Figma's design-context tooling.

| Frame | Node |
|---|---|
| 01 · Sessions (default 1120×720) | window `11:2624` |
| 02 · Token Usage (default) | window `11:3422` |
| 03 · Menu Bar | panel `31:847` |
| 04 · Projects (default) | window `55:2454` |
| Minimum window 960×600 | `43:959`, `43:1365` |
| Large window 1440×900 | `45:1641`, `45:2077` |
| Responsive rules panel (Chinese) | `46:2400` |
| Local components | `10:37` |

### 11.1 Window and navigation

- Main window: three-column `NavigationSplitView` (sidebar / list / detail); the Token Usage page uses two columns (sidebar / content).
- Sidebar (after the §18 adjustments):
  - **Library:** Sessions, **Projects**, Token Usage
  - **Agents:** discovered agents with session counts
  - **Environments:** only when there is more than one
  - **Status:** Running / Waiting / Completed / Failed
  - **Smart Groups:** saved searches
- Window default 1120×720, minimum 960×600, no maximum; remember last size and position.

### 11.2 Sessions page

**List:** each row = agent avatar (initials + agent color), title, relative time, `project · branch`, matching snippet (when searching), status badge, tokens and estimated cost. Archived sessions show a small archive icon. A "Group by project" toggle.

**Detail:**

- Header: avatar, title, `agent · full path · branch · environment`, status badge (hover shows inference evidence).
- Meta grid: Started, Turns, Tokens · Cost (two lines in one cell: total tokens including cache / list-price cost estimate; hover shows the breakdown), Context window.
- Live activity bar (running only): current action + command + elapsed time + "last event 3s ago". **No process ID** (the sandbox cannot see it).
- Two tabs: **Overview** | **Transcript**.
  - Overview: main-topic chips, latest progress (§10.3), touched files (top 10, with +/-), commands run (top 10), mini token chart for this session.
  - Transcript: as in the prototype — user / assistant messages; tool calls collapsed into one row (icon + name + argument summary + result on the right), expandable to full input/output; inherited parts collapsed; match highlighting and navigation. Render Markdown with `AttributedString(markdown:)`, code blocks in monospace; never load external images.
    Read bounded pages in file order, with the event row ID breaking sequence ties. Seek straight to a selected match without reading intervening pages. Pages are scoped to one session; restart paging when the file order changes.
- Bottom buttons:
  - **Copy Resume Command** (primary; replaces the prototype's old "Open in Terminal"): copies the command from §5 / Appendix C.
  - **Show in Finder** (reveals the session's record file).
  - MAY: "Open folder in Terminal" using only `NSWorkspace.shared.open(_:withApplicationAt:configuration:)`, no Apple Events. If the sandbox does not allow it, skip it and record the decision in `docs/DECISIONS.md`.

### 11.3 Projects page (answers "which directory, and what is going on there")

- List: project name, path, agents used (icons), session count, last activity, tokens and cost for the selected period, latest session title. Projects can be pinned.
- Detail:
  - Header: project name, full path, repository URL (if known), branches.
  - Meta grid: Sessions, Agents, Tokens · Cost, Last activity. Main-topics line below it.
  - **Latest updates timeline**: recent actions from **all agents** in this project merged by time (who, which session, what was done).
  - Tabs: Sessions | Latest updates. The Sessions tab lists this project's sessions (filter by agent / status).
  - Token chart for this project (reuse the Token Usage components with a project filter).
  - Buttons: Show in Finder, Open Latest Session.
- Project identity: if a repository URL is known, the normalized URL is the key (worktrees of the same repository group together, with the worktree name as a tag); otherwise `cwd`. Claude worktree paths look like `<repo>/.claude/worktrees/<name>` and belong to the main repository.

### 11.4 Token Usage page

**Periods** (FR-TK-1): segmented control `1H | 24H | 7D | 30D | 90D | All`, plus a "Custom…" date-range picker. Buckets and units:

| Period | Bucket | Main chart | Y unit |
|---|---|---|---|
| 1H | 1 minute (3-minute smoothing for display) | curves (dyno style) | tok/min |
| 24H | 5 minutes | curves | tok/min |
| 7D | 1 hour | curves | tok/h |
| 30D / 90D | 1 day | bars stacked by agent + cumulative dashed line | tok/day |
| All / Custom | automatic, keep ≤ 500 points | automatic | automatic |

30D and 90D remain exact rolling durations for totals and comparisons. Their
daily chart bars use calendar days in the display time zone, including days that
are shorter or longer than 24 hours. Count only events inside the report range.

The page subtitle states the range explicitly, e.g. "Today 00:00–15:12 · all agents" or "Last 24 hours", so "Today" and "24H" are never confused.

**Readouts** (4 cards, following period and metric):

- Peak throughput: value + time + "all agents combined". With the Cost metric: peak spend rate ($/h).
- Total for the period (cache included): value + change vs the previous period of equal length (up to the same relative time). Caption: cache hit rate + input : output. A thin segmented bar at the bottom shows fresh input / cache write / cache read / output.
- Estimated cost (list price): amount (switchable currency) + change. Caption: cache savings. If there are unpriced tokens, show "N tokens unpriced", linking to Settings → Pricing.
- Limit headroom:
  - With Codex rate-limit data, show used % and reset time for the primary/secondary windows.
  - For other agents use the user-defined "redline" (tok/min per agent): headroom = 1 − (current top agent rate ÷ its redline).
  - Without either, show "Not set" with a link to Settings.

**Main chart** (Swift Charts):

- One colored curve per agent; **thick white line = all agents combined** (area fill + glow); grey dashed line = cumulative for the period (right Y axis).
- Swift Charts has one Y scale: scale the cumulative series into the left axis range, and label the trailing axis with custom `AxisMarks` that map back to real values.
- Redline: dashed red `RuleMark`, per agent or only for the selected agent.
- Peak chips: one small label at each curve's maximum ("TOTAL PEAK 88.2k @ 10:27", …), placed with a simple collision-avoidance search (8 directions × 3 distances; pick the least obstructed) so they never overlap curves, other chips or the NOW line.
- NOW vertical line + current combined value + current cumulative value.
- Hover: values of every agent at that time (`chartOverlay`).
- Non-`call` precision data is drawn as hatched bars, with a legend note "session-level precision".
- Live updates on new data or every 5 s; append only, never recompute the whole chart.

**Metric switch:** Tokens (default) / Output only / Cost (§8.2). With Cost, the Y axis is $/h ($/day for 30D and longer) and the dashed line is cumulative cost. **Filters:** agent menu (in the prototype) and a new project menu.

**Detail table:** group by **agent (default) / project / model**; columns: name, peak, peak time, total (cache included), cache hit rate, cost, share bar, sessions; a totals row at the bottom. In narrow windows hide "peak time" first, then "cache hit rate".

### 11.5 Menu bar panel

Per prototype `31:847`:

- Header: app name + "4 running · 2 waiting · 128 sessions today" + Live badge.
- Search field: Return opens the main window with the query.
- Three readouts: Now (tok/min + active agents), Today (total + estimated cost), Headroom.
- Today's mini chart + legend.
- Active sessions (max 6, then scroll): title, project, status and duration, current rate or "Needs input". Clicking opens the main window on that session.
- Footer: Open Dashboard ⌘D, Settings… ⌘,, Quit ⌘Q.
- MAY: option to show current tok/min next to the menu bar icon.
- SHOULD: local notification (UserNotifications, local only) when a session starts needing approval; off by default.

### 11.6 Settings window

| Tab | Content |
|---|---|
| General | Launch at login, menu bar display, time format |
| Sources | Source list (agent, path, environment, status, files, sessions, last scan, unknown records, errors); add / remove / rescan; edit path mappings and environment rules |
| Thresholds | Per-agent redline (tok/min); status-inference thresholds; model → context-window table |
| Storage | Database size; archive retention; tool-output size limit; rebuild index; full rescan; clear by project / source / all |
| Privacy | Secret masking (default on); index thinking blocks (default off); excluded paths or projects (globs) |
| Pricing | Active file (external / bundled), `updatedAt`, number of model entries, validation errors; unpriced models with token volume (one-click copy, to hand to an agent); display currency |
| About | Version; statement that the app has no network permission, listing the entitlements actually present in the signature |

Launch at login is off until the user requests it in General. Use
`SMAppService.mainApp` and show the observed macOS registration status,
including any required approval in System Settings. Disabling it unregisters
future sign-in launches without quitting the app. The App ships no helper
and requests no new entitlement for this feature.

### 11.7 First-run onboarding

Three steps: ① privacy promise (zero network, read-only, data stays on this Mac) → ② detected agent directories with file counts; add other directories (containers, VMs, other `CODEX_HOME`s) with environment labels → ③ start indexing with progress; recent sessions appear first and the user can enter the main window immediately.

### 11.8 Responsive rules (final in Figma `46:2400`)

- Window default 1120×720, minimum 960×600, no maximum, remember last size.
- Sidebar 240 default, draggable 200–300, collapsible.
- Toolbar search field fills the remaining width, minimum ≈ 200.
- Session list width: 300 at minimum window / 356 default / 420 large (interpolated with window width; remember user drags).
- Session detail narrower than 480: meta grid becomes 2×2 instead of 1×4.
- Token page content narrower than 760: readout captions hidden.
- Main chart minimum height 220; if it does not fit, the whole page scrolls.
- Detail table: name and share columns split the free width; narrow windows hide columns as in §11.4.
- Menu bar panel fixed width 360; active sessions scroll after 6.
- Everything is in points; Retina scaling is handled by the system.

### 11.9 Visual style

- Follow system light/dark appearance. The prototype is dark; dark mode is the primary QA target, light mode must work.
- Use semantic system colors: `labelColor`, `secondaryLabelColor`, `tertiaryLabelColor`, `windowBackgroundColor`, etc.
- Agent colors: Claude Code = orange (systemOrange), Codex = mint (systemMint), Grok Build = blue (systemBlue), Copilot = purple (systemPurple), combined = white (labelColor), redline = red (systemRed). Future agents use systemTeal / systemIndigo / systemPink / systemBrown in order.
- Fonts: SF Pro; code and commands in SF Mono.
- Icons: SF Symbols.

### 11.10 Keyboard shortcuts

⌘F search · ⌘1 Sessions · ⌘2 Projects · ⌘3 Token Usage · ⌘R rescan · ⇧⌘C copy resume command · ⌘G / ⇧⌘G next / previous match · ⌘, Settings · ⌘D (in the menu bar panel) open the main window.

### 11.11 Empty and error states

Every list and chart needs: first indexing in progress, no data, no search results, source without permission ("Grant access again" button), parse errors ("View details" opens the health panel).

### 11.12 Localization

All user-facing strings go through a String Catalog (`Localizable.xcstrings`). Ship English and Simplified Chinese; macOS picks the language from the user's settings. Dates and numbers use the user's locale and time zone (the user is in Asia/Shanghai); "today" starts at local midnight.

---

## 12. Privacy and security

### 12.1 Entitlements (complete list — add nothing else)

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>   <!-- extra folders; access remains read-only in code -->
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
<key>com.apple.security.temporary-exception.files.home-relative-path.read-only</key>
<array>
  <string>/.claude/</string>
  <string>/.codex/</string>
  <string>/.copilot/</string>
  <string>/.grok/</string>
  <string>/.config/agent-dashboard/</string>   <!-- pricing.json (§8.5) -->
</array>
```

- `/.config/agent-dashboard/` is only used to read the price table; the app never writes there.
- Temporary-exception entitlements need a justification only in App Store review; this app is distributed with Developer ID for personal use and is not reviewed.
- **Verify in M0** that the signed app can read these directories. If not, fall back to onboarding: let the user pick each directory with `NSOpenPanel` (pre-navigated, hidden files shown) and store bookmarks.
- Hardened Runtime ON with no exceptions.

### 12.2 Secret masking (default on)

Mask common secret formats at display time (e.g. `sk-…`, `ghp_…`, `github_pat_…`, `AKIA…`, `xox[bp]-…`, `-----BEGIN … PRIVATE KEY-----`, and `.env`-style assignments to variables whose names end in KEY, TOKEN, SECRET or PASSWORD) as `••••••`; click to reveal temporarily. Rules live in `ADPrivacy` with unit tests. v1 masks only in the UI and keeps the original text in the index (so users can still search their own config keys); "also strip at index time" is a setting.

### 12.3 Exclusions

Settings accepts globs (e.g. `~/work/client-a/**`). Matching sessions are not indexed; already-indexed data is removed immediately.

Rules start with an absolute path or `~/`, expanded against the explicitly
provided host home. `*` and `?` match within a component; `?` consumes one
Unicode scalar. A standalone `**` matches zero or more complete components.
Other characters are literal. Matching is case-sensitive and preserves
Unicode spelling. Rules reject dot components, repeated interior separators
and NUL, and ignore trailing separators. Validate all rules before saving
(at most 64 rules, each at most 4,096 UTF-8 bytes).

For recorded workspace paths, collapse redundant separators and remove `.`
components without accessing the filesystem. With active rules, a relative path,
an implementation-defined `//` prefix, NUL or a `..` component is indeterminate.
Defer indexing when the workspace is indeterminate; only a confirmed match
triggers removal. With no exclusion rules, no path is excluded.

### 12.4 Proving zero network

- CI: entitlement check (§14.4).
- Manual check before each release: watch the app for 30 minutes with Activity Monitor or a network monitor — no connections. In Console, filter `subsystem:com.apple.sandbox.reporting`; there must be no network violations from this app (any violation means some code tried to connect and must be removed).

---

## 13. Performance budgets (NFR)

| ID | Metric | Target |
|---|---|---|
| NFR-1 | Cold start to showing existing data | < 1 s |
| NFR-2 | File write → UI update | ≤ 2 s |
| NFR-3 | First full index | ≥ 50 MB/s of raw logs on Apple silicon; 5 GB of raw logs in < 3 min |
| NFR-4 | Search latency at 1M events | P95 < 150 ms |
| NFR-5 | Switching Token Usage periods | < 100 ms |
| NFR-6 | Memory with 1M events | < 400 MB with the window open; < 150 MB menu-bar only |
| NFR-7 | Idle CPU | < 1% average (no polling when nothing changes) |
| NFR-8 | Database size | ≤ 35% of raw log size (after tool-output truncation) |
| NFR-9 | Opening a session with 50k messages | first screen < 300 ms; 60 fps scrolling (paged from the database) |
| NFR-10 | Recomputing cost for 1M token records after a price change | < 10 s, UI stays usable |

Use `Tools/synthgen` to generate synthetic data for performance tests (§15.3).

---

## 14. Engineering conventions

### 14.1 Repository layout

```
AgentDashboard/
├── AgentDashboard.xcodeproj
├── App/                       # SwiftUI app target: entry, windows, menu bar, settings, onboarding, views
│   ├── AgentDashboard.entitlements
│   └── Resources/             # stop-word lists, secret-masking rules, default context-window table, Localizable.xcstrings
├── Packages/AgentDashKit/
│   ├── Package.swift
│   ├── Sources/ADCore … ADPricing
│   └── Tests/
│       ├── Fixtures/<agent>/  # sanitized or synthetic samples only — never real sessions
│       └── *Tests/
├── pricing/                   # pricing.json, pricing.schema.json, UPDATE_PLAYBOOK.md (§8.5)
├── Tools/
│   ├── fixture-capture/       # local CLI: turns real files into sanitized fixtures
│   ├── synthgen/              # synthetic data for performance tests
│   ├── pricing/               # validate / models-seen / install (§8.5)
│   ├── check-entitlements.sh
│   └── forbid-apis.sh
├── docs/
│   ├── SPEC.md                # this document
│   ├── DECISIONS.md
│   └── FORMATS.md             # observed agent formats, updated as versions change
├── AGENTS.md                  # entry point for coding agents
└── CLAUDE.md                  # one line: @AGENTS.md (so Claude Code loads the same rules)
```

### 14.2 Code conventions

- Swift 6 strict concurrency; no force unwraps or `try!` in parsers.
- Doc comments on public types and functions.
- Dependencies point downward only (§4.2); no cycles.
- All user-facing strings in the String Catalog (§11.12).
- Display times in the user's local time zone.

### 14.3 Commits

One change per commit; reference requirement IDs, e.g. `feat(ADP-CX): count tokens from last_token_usage`. Every parser change ships with fixtures and tests.

### 14.4 CI checks (local scripts; can run in any CI)

1. `check-entitlements.sh`: fail if `codesign -d --entitlements - --xml <App>` contains `network`, or any key not listed in §12.1.
2. `forbid-apis.sh`: grep for the forbidden symbols in SEC-2, SEC-5 and SEC-6.
3. Dependency check: only allow-listed packages in `Package.resolved`.
4. Unit tests and performance tests (with baselines; > 20% regression fails).

---

## 15. Testing and acceptance

### 15.1 Unit tests (required)

- Every adapter: normal session, resumed session, subagents, compaction, malformed lines, unknown records, half-written last line, rewritten file, empty file.
- **Golden token tests:** per adapter, fixtures with hand-computed expected totals covering every "trap" in §5; **results must match exactly**.
- Tokenizer: every case in §9.2.
- Query parser: every example in Appendix B.
- Status inference: boundary values for each status.
- Keywords: stable output on a fixed corpus.
- Secret masking: positive and negative cases per rule.
- Path mapping: longest prefix, trailing slashes, case.
- Pricing: match priority, aliases, effective-date selection, tiers, approximation when cache prices are missing, unpriced models, currency conversion; correct recomputation after a price-table change; `validate` catches duplicate effective dates and match conflicts.
- Environment rules (from EXP-1): sessions in one root land in the right environment.

### 15.2 Fixture capture (required before implementing an adapter)

1. On the developer machine (the user's own Mac), run `Tools/fixture-capture` against real files.
2. The tool sanitizes: replaces all text with placeholder text of the same length, rewrites paths to `/Users/dev/...`, removes secret patterns, keeps structure and numbers.
3. Each fixture gets a `.sanitized` marker file; fixtures without one must not be committed.
4. Record observed format differences in `docs/FORMATS.md`.

### 15.3 Performance tests

`Tools/synthgen` provides a small smoke corpus and a benchmark profile:
4 agents, 2,000 sessions, 1,000,000 raw JSONL records and 5,000,000,000 raw
bytes. Records include headers and usage; bytes exclude the manifest.
Use temporary generated files for §13 and report the formats the App
actually imports. Synthetic Grok samples do not replace real format capture.

### 15.4 UI smoke test (XCUITest)

Launch → onboarding → sessions appear → search a Chinese word → open a session → jump to a match → Projects page → Token Usage → switch periods and metric → open the menu bar panel.

### 15.5 Release checklist

- [ ] All §14.4 checks pass
- [ ] Manual zero-network check (§12.4) passes
- [ ] On the user's real data for all four agents: session counts and token totals match each CLI's own statistics on spot checks (within 1%; record reasons for differences in FORMATS.md)
- [ ] Sessions remain viewable and searchable after their raw files are deleted
- [ ] Minimum / default / large window screenshots match Figma
- [ ] Light mode works
- [ ] Cost: for each agent, 3 sessions hand-priced from the price table match the app

---

## 16. Milestones

| Milestone | Scope | Exit criteria |
|---|---|---|
| M0 Skeleton and guardrails | Project, modules, entitlements, CI scripts, migrations, empty window + menu bar; verify the sandbox read exceptions | §14.4 passes; installed agents' default directories are readable (or the fallback works). Report unavailable sources explicitly; the owner-confirmed absent Grok installation is deferred locally (DEV-008). |
| M1 Claude Code + Codex | EXP-1 first; two adapters, full + incremental ingestion, session list, basic detail, Codex environment tagging | Golden tests pass; NFR-2 met; EXP-1 findings in FORMATS.md |
| M2 Copilot + Grok Build + Sources settings | Two adapters, source management, path mappings, environment rules, health panel, onboarding | Golden tests pass; custom-directory sources work |
| M3 Search and insights | Tokenizer, query syntax, snippets, match navigation, Overview tab, Projects page, status inference | NFR-4 met; Chinese search tests pass |
| M4 Token Usage, cost, menu bar | All periods, readouts, chart, table, metric switch, limits; price-table interface and `Tools/pricing`, cost calculation and recomputation; first real `pricing.json` filled from official vendor pages; menu bar panel | NFR-5 and NFR-10 met; matches Figma |
| M5 Polish and release | Responsive rules, archive and retention, masking and exclusions, launch at login, performance tuning, signing and notarization | Every box in §15.5 checked |

---

## 17. Decision log

**Confirmed by the product owner (2026-11-17):**

| ID | Question | Decision |
|---|---|---|
| D-1 | What are the "separate environments"? | The user's Codex has two environments that appear to share one session directory (unconfirmed). Complete EXP-1 (§5.1.1) first and implement according to its findings. |
| D-2 | Which agents in v1? | Claude Code, Codex (CLI and desktop app), GitHub Copilot CLI (including the Copilot App), Grok Build. Not Gemini CLI / Antigravity, not Cursor. |
| D-4 | Token accounting | Totals include cache reads and writes. Add cost estimates from vendor list prices; the price table is a static file an agent updates periodically (§8.4–8.5). |
| D-5 | Telemetry | Ignore telemetry; read only session data agents keep locally; open no ports. |
| D-6 | On-device models | Not used: not needed for this project, and the user's China-region Mac does not have on-device AI enabled. |

**Defaults still in effect (no objection raised; can change any time):**

| ID | Question | Default |
|---|---|---|
| D-3 | Keep sessions after agents delete their raw files? | Yes, forever by default; configurable |
| D-7 | Default redline | None; the user sets it per agent; Codex shows real limits first |
| D-8 | Distribution | Developer ID signing + notarization, personal use, not on the App Store |
| D-9 | Cost display currency | USD by default; switchable to currencies with a static rate in the price table (e.g. CNY) |
| D-10 | Copilot cost basis | API-equivalent cost at the underlying model vendor's list price; Copilot's own billing units shown separately |

---

## 18. Prototype adjustments

Figma sync status (2026-11-17): items 1, 2, 4, 5, 6, 7 and 9 are in the prototype. Item 8: cost readout, cost column and 90D / All are drawn; the metric switch is not. Item 3: only the "Overview | Transcript" tabs are drawn; for the Overview content, follow §11.2 and the project page's latest-updates timeline. Items 10 and 11 are not drawn; implement them from this document. The minimum-size Token Usage window already hides the "peak time" column.

**P1 — implement the adjusted design:**

1. Agents are Claude Code, Codex, Copilot CLI and Grok Build: every Gemini CLI in the original prototype becomes Grok Build (keeps blue); Cursor Agent is removed.
2. Sidebar gets a "Projects" entry and the Projects page (§11.3). The session list can group by project.
3. Session detail gets an "Overview" tab: main topics, latest progress, files and commands (§10).
4. Live activity bar drops the process ID and shows "last event N s ago"; the status badge shows its evidence on hover.
5. "Open in Terminal" becomes "Copy Resume Command"; "Reveal Transcript" becomes "Show in Finder". Omit the transcript share control.
6. Detail header shows the full path and environment; archived sessions are marked; the meta grid's Tokens cell becomes "Tokens · Cost".
7. Token page: periods add 90D, All and Custom; subtitle states the exact range; 30D and longer use bars.
8. Token page: readouts are Peak throughput / Total (cache included) / Estimated cost / Limit headroom; metric switch (Tokens / Output only / Cost) and project filter; detail table adds cache hit rate and cost columns and can group by agent / project / model.
9. Menu bar "Today" readout shows estimated cost.
10. Limit headroom shows real Codex limits; "Not set" when no redline is configured.
11. New Settings window (including the Pricing tab, §11.6), first-run onboarding (§11.7), empty and error states (§11.11).

**P2 — can come later:**

12. Search filters shown as tokens in the search field; "Smart Groups" in the sidebar.
13. "Environments" sidebar section when there is more than one (after the Codex environments are confirmed).
14. Clickable active sessions in the menu bar panel; optional local notification when approval is needed.

---

## Appendix A: References (format sources, checked November 2026)

- Claude Code session management (official): https://code.claude.com/docs/en/session-management
- Claude Code JSONL structure and token dedupe traps: https://turnlog.dev/claude-code-jsonl/
- Claude Code transcript location and 30-day cleanup: https://promptconduit.dev/blog/claude-code-transcripts-location
- Codex rollout format, token_count and rate_limits: https://tokenuse.app/docs/development/tools/codex/
- Codex parser notes: https://github.com/crispierry/codex-log-viewer/blob/main/docs/parser-schema-notes.md
- Codex profiles and CODEX_HOME (multiple environments): https://continuumcode.ai/guides/codex-config/
- Codex profile file structure: https://codexinsider.com/config/profiles/
- Grok Build sessions (official): https://docs.x.ai/build/features/sessions
- Grok Build session storage layout (mirror of the grok-build source docs): https://github.com/open-grok/open-grok/blob/main/crates/codegen/xai-grok-pager/docs/user-guide/17-sessions.md
- Copilot CLI configuration directory (official): https://docs.github.com/en/copilot/reference/copilot-cli-reference/cli-config-dir-reference
- Copilot CLI usage counting rules: https://usekibble.com/blog/where-github-copilot-keeps-its-usage-logs
- Copilot CLI / App session analysis (usage_record): https://copilot-session-usage.readthedocs.io/en/stable/how-to/copilot-cli-provider.html
- Accessing files from the macOS App Sandbox (official): https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox
- App Sandbox temporary exception entitlements (official): https://developer.apple.com/library/archive/documentation/Miscellaneous/Reference/EntitlementKeyReference/Chapters/AppSandboxTemporaryExceptionEntitlements.html

## Appendix B: Search syntax

| Syntax | Meaning | Example |
|---|---|---|
| plain text | Full-text match (Chinese by bigrams, English by words and identifier parts) | `登录 middleware` |
| `"…"` | Exact phrase | `"refresh token"` |
| `-term` | Exclude | `auth -test` |
| `A OR B` | Either | `redis OR memcached` |
| `agent:` | claude / codex / copilot / grok | `agent:codex` |
| `project:` | Project name (prefix match) | `project:payments` |
| `dir:` | Path prefix | `dir:~/code/api` |
| `env:` | Environment label | `env:work` |
| `status:` | running / waiting / completed / failed | `status:waiting` |
| `role:` | user / assistant / tool | `role:user refactor` |
| `tool:` | Tool name | `tool:Bash docker` |
| `file:` | Touched file (substring) | `file:auth.ts` |
| `model:` | Model name (substring) | `model:opus` |
| `after:` / `before:` | Date (local time zone) | `after:2026-11-01` |
| `in:` | Recent window | `in:7d`, `in:24h` |

## Appendix C: Resume command templates

| Agent | Template |
|---|---|
| Claude Code | `cd "<cwd>" && claude --resume <sessionId>` |
| Codex | `cd "<cwd>" && codex resume <id>` |
| Grok Build | `cd "<cwd>" && grok --resume <session-id>` |
| Copilot CLI | `cd "<cwd>" && copilot --resume <sessionId>` |

`<cwd>` is the host path after path mapping. For sessions from a container or VM, prepend a comment reminding the user to run it inside that environment. Verify each CLI's resume flags against its local `--help` output during M1/M2.
