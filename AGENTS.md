# AGENTS.md — Agent Dashboard

Instructions for coding agents (Codex, Claude Code, Copilot CLI, Grok Build, …) working in this repository.

## What we are building

A native macOS app (macOS 27, Apple silicon only) that reads the local session records of the user's coding agents — Claude Code, Codex (CLI and desktop app), GitHub Copilot CLI and Grok Build — and turns them into a **read-only** dashboard:

- unified full-text search across agents, projects and environments (Chinese and English);
- per-session and per-project views: directory, main topics, latest progress, full transcript;
- a live token-throughput chart with multiple periods, cache-inclusive totals, and cost estimated from vendor list prices;
- a menu bar panel.

The app is **fully local and never touches the network.**

## Read before you write code

1. `docs/SPEC.md` is the single source of truth. Always read §0 (how to use the spec) and §2 (hard constraints), then the sections for your task.
2. The design is in Figma: https://www.figma.com/design/X48cH7JgDwxYzOWtzhtJkw (frame and node IDs in SPEC §11). The spec wins when they disagree; SPEC §18 lists the adjustments.
3. `docs/FORMATS.md` records what agent files really look like on this machine. It overrides SPEC §5 where they differ.
4. `docs/DECISIONS.md` records decisions made during implementation. Read it so you don't re-decide.

## Hard rules (never break; details in SPEC §2)

- **No network, ever.** No `network.client` / `network.server` entitlements. No `URLSession`, `Network` framework, sockets, `WKWebView`, update frameworks, analytics or crash reporters. This includes localhost.
- **Read-only.** Never write, move, delete, lock or touch files under `~/.claude`, `~/.codex`, `~/.copilot`, `~/.grok` or any user-added source — not in the app, not in tests, not in tools. Read other apps' SQLite files only from a snapshot copy.
- **No AI.** No model calls of any kind, including Apple's on-device Foundation Models, NaturalLanguage embeddings, Core ML. Topics, titles and status come from deterministic rules (SPEC §10).
- **Entitlements are frozen** to the list in SPEC §12.1. **Dependencies are frozen** to GRDB.swift (pinned); zstd only if `.jsonl.zst` files really exist.
- **No child processes, no Apple Events.**
- **Session content stays private:** never put it in logs (`os.Logger` with `privacy: .private`), commits, PR descriptions, issues, fixtures or screenshots shared outside this machine.

Changing any of these needs explicit approval from the product owner. Do not implement it; raise it as a question in the PR.

## Workflow

1. Take the next task from the current milestone (SPEC §16). Keep changes small and focused.
2. **Before writing or changing an adapter:** capture sanitized fixtures from real files with `Tools/fixture-capture` (SPEC §15.2), compare them with SPEC §5, and record differences in `docs/FORMATS.md`.
3. **Before M1:** complete exploration task **EXP-1** (SPEC §5.1.1) on the user's two Codex environments. Report field values and counts only.
4. Write or extend tests first for parsers and accounting. Golden token tests must match hand-computed totals **exactly**.
5. Implement within the module boundaries in SPEC §4.2. Dependencies point downward only; the app target never runs SQL directly.
6. Run the checks below. Fix everything before you commit.
7. Update `docs/FORMATS.md`, `docs/DECISIONS.md` and, when behavior changes, `docs/SPEC.md`.
8. Commit with requirement IDs, e.g. `feat(ADP-CX): count tokens from last_token_usage`.

## Commands

These are created in milestone M0. Keep this section accurate if names or paths change.

```bash
# Build the app
xcodebuild -project AgentDashboard.xcodeproj -scheme AgentDashboard \
  -destination 'platform=macOS,arch=arm64' build

# Package unit tests (adapters, store, search, insights, pricing)
swift test --package-path Packages/AgentDashKit

# App tests (UI smoke, performance)
xcodebuild test -project AgentDashboard.xcodeproj -scheme AgentDashboard \
  -destination 'platform=macOS,arch=arm64'

# Guardrails — must pass before every commit
Tools/check-entitlements.sh path/to/AgentDashboard.app
Tools/forbid-apis.sh
Tools/check-dependencies.sh

# Developer-tool tests (synthetic inputs only)
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/tests -v

# Price table
Tools/pricing/validate pricing/pricing.json
Tools/pricing/models-seen
Tools/pricing/install
```

For local ad-hoc App validation, follow the build/re-sign/test-without-building
procedure in `docs/reports/M0-FOUNDATION.md`; inspect the actual frozen entitlements
and runtime flag. If the UI host cannot expose a menu entry, a skipped test is not
acceptance: run its documented manual-entry mode and obtain the real panel/reopen
assertions. Visual review may use the owner's authorized Computer Use tool.

## Code map

| Path | What lives there |
|---|---|
| `App/` | SwiftUI app: windows, menu bar panel, settings, onboarding, views, entitlements, resources |
| `Packages/AgentDashKit/Sources/ADCore` | Domain models and utilities |
| `…/ADAdapters` | One adapter per agent (`AgentAdapter` protocol) |
| `…/ADStore` | GRDB database, migrations, FTS5, rollups, archive |
| `…/ADIngest` | Sources, FSEvents, incremental tailing, checkpoints |
| `…/ADSearch` | Query syntax, ranking, snippets, CJK tokenizer |
| `…/ADInsights` | Titles, keywords, latest progress, status inference |
| `…/ADPrivacy` | Secret masking, exclusions |
| `…/ADPricing` | Price table loading, matching, cost calculation |
| `Packages/AgentDashKit/Tests/Fixtures/` | Sanitized or synthetic fixtures only |
| `pricing/` | `pricing.json`, schema, `UPDATE_PLAYBOOK.md` |
| `Tools/` | fixture-capture, synthgen, pricing tools, guardrail scripts |
| `docs/` | `SPEC.md`, `FORMATS.md`, `DECISIONS.md` |

## Conventions

- Swift 6 language mode, strict concurrency `complete`. Deployment target macOS 27, arm64 only — no `#available` branches.
- SwiftUI first; AppKit only where SwiftUI cannot do it. Swift Charts for charts.
- Parsers are tolerant: unknown records are kept and counted, never crash (SPEC ADP-1…ADP-7). No force unwraps or `try!` in parsers.
- Every write is an idempotent upsert keyed by a deterministic dedupe key.
- Times are stored as UTC milliseconds and shown in the user's local time zone (Asia/Shanghai).
- User-facing strings go through `Localizable.xcstrings` (English and Simplified Chinese).
- Use semantic system colors and SF Symbols; agent colors are fixed in SPEC §11.9.

## Token and cost accounting traps (read SPEC §5 and §8 before touching them)

- Claude Code repeats the same `usage` on every line of one response — dedupe by `message.id`. Resumed sessions copy history — dedupe events by `uuid`.
- Codex: use `last_token_usage` only; never sum `total_token_usage`; `input_tokens` includes cached input; index `event_msg` text, not `response_item` copies.
- Copilot CLI: prefer per-call `session.usage_record`; `session.shutdown` metrics are cumulative — diff them; `inputTokens` includes cache reads and writes; subagent records are already in the parent total.
- Grok Build: `updates.jsonl` is the authoritative log; `signals.json` is cumulative — diff it; rewinds and forks need dedupe.
- Totals always include cache reads and writes. Cost is a list-price estimate stored in micro-USD.

## Definition of done

- Builds without new warnings; all tests pass; guardrail scripts pass.
- New or changed parsing has sanitized fixtures and golden tests.
- UI work is compared against Figma at minimum (960×600), default (1120×720) and large (1440×900) window sizes, in dark mode first, then light mode.
- Performance-sensitive work meets the budgets in SPEC §13.
- Docs updated (`FORMATS.md`, `DECISIONS.md`, `SPEC.md` when behavior changed).
- The PR description lists requirement IDs and any decisions taken.

## When unsure

- Choose the most conservative option (fewer permissions, fewer dependencies, read-only), write it down in `docs/DECISIONS.md`, and keep going.
- Stop and ask the product owner only for: a new entitlement, a new dependency, anything involving network or AI, or a change to a confirmed decision (SPEC §17, D-1 to D-6).

## Recurring task: updating prices

When asked to update prices, follow `pricing/UPDATE_PLAYBOOK.md` (summary in SPEC §8.5): run `models-seen`, take prices only from official vendor pricing pages, **append** new effective-dated entries (never edit old ones), run `validate`, run `install`, and open a PR listing the changes and their sources. This task may use the network on the developer machine to read vendor pages; the app itself never does.

## Tool-specific notes

- Claude Code reads `CLAUDE.md`; it contains the single line `@AGENTS.md`, so these rules apply there too.
