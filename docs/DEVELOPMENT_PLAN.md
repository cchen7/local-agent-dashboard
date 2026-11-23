# Development plan

## Roles and current scope

The coordinator owns task sequencing, shared decisions, code review, and PR merges.
Coding agents own one assigned worktree and return a scoped change with verification
evidence. The product owner resolves changes to confirmed product decisions.

2026-11-17: the owner asked the coordinator to launch standard-environment
`gpt-6.1-sol` coding agents. This supersedes the earlier plan for manual agent launch.
The coordinator also owns EXP-1. M0 local acceptance is now complete; consult CHECKPOINT.md and the actual PR state before starting M1.

The first commit establishes the previously uncommitted specification, repository
instructions, and this handover. It is the prerequisite for linked worktrees, not
an M0 acceptance result. All subsequent implementation changes go through PR review.

## First development wave

| Task | Branch | Worktree relative to the main checkout | Ownership | Prerequisites |
|---|---|---|---|---|
| [M0 foundation](tasks/M0-FOUNDATION.md) | `feat/m0-foundation` | `.worktrees/m0-foundation` | Xcode project, App skeleton, Swift package, domain contracts, store migration and tests | Can start; app verification waits for Xcode |
| [M0 tooling](tasks/M0-TOOLING.md) | `feat/m0-tooling` | `.worktrees/m0-tooling` | Guardrails, fixture-capture tool and synthetic tests | Can start independently |
| EXP-1 | Coordinator | Main checkout | Metadata-only Codex environment exploration; `FORMATS.md` | Required before M1 |

Both coding branches start at the same reviewed documentation baseline. Only the
foundation agent edits `Package.swift`, package source/test targets, the Xcode
project, App files and localization. Only the tooling agent edits `Tools/`.
Neither changes product decisions, another worktree, global configuration, agent
source directories, or the other agent's branch.

Agents place proposed decisions and results in their own `docs/reports/<TASK>.md`.
The coordinator incorporates accepted decisions into `DECISIONS.md` and changes
to behavior into `SPEC.md`. This avoids concurrent edits to shared documents.
The coordinator owns `FORMATS.md` until the EXP-1 handover is complete.

## Dependency order

1. Bootstrap → M0 foundation and M0 tooling in parallel; coordinator completes EXP-1.
2. Merge reviewed tooling. Foundation brings current `origin/main` into its own
   branch and runs the combined guardrails, package tests, and app checks.
3. Close M0 only after the signed application's source-directory reads or bookmark
   fallback have been exercised on this Mac. Compilation alone does not prove this.
4. M1: capture and review sanitized Claude/Codex fixtures first; freeze the minimal
   adapter/store/checkpoint contracts; then allocate separate Claude, Codex and
   ingest tasks. Session list/detail integration follows working ingestion.
5. M2: repeat capture-before-parser for Copilot and Grok; add Sources/settings,
   path mappings, onboarding and health reporting.
6. M3: search/query syntax, deterministic insights, Projects and status inference.
7. M4: pricing engine/table/tools, token aggregation, charts and menu bar; fill real
   prices only from official vendor pages. Do not use the SPEC's zero-price example.
8. M5: retention/archive, masking and exclusions, responsiveness, performance and release.

Do not pre-create every future branch from today's empty skeleton. Create each
wave from the accepted `main` after its contracts and prerequisites are available.

## Review and merge gate

- PRs target `main`, identify requirement IDs, and explain behavior and evidence.
  The coordinator is the merger; coding agents do not merge their own PRs.
- Review the full diff and relevant callers, boundaries and tests. Parser and
  accounting changes need sanitized fixtures and exact hand-computed golden totals.
- Re-run relevant checks at the actual PR head. When the base changes, verify the
  integrated result before merging. A historical green run is not sufficient.
- All applicable existing checks must pass. A skipped check is recorded with its
  cause; it is never called passed. Missing Xcode keeps app acceptance pending.
- UI evidence uses synthetic data, the three SPEC window sizes, dark then light
  mode, and Figma node comparisons. No real session screenshots in a public PR.
- No raw source logs, credentials, local environment dumps, or real conversation
  text in commits, PRs, fixtures or reports. Aggregate field values/counts are okay.
- Prefer squash merge for a scoped task PR after approval. Keep worktrees and
  branches while there is uncommitted work; do not force-push or delete them as cleanup.

For any new or changed search field, editable form, shortcut or UI test, map the
change to the [fixed input QA matrix](reports/FIXED-INPUT-QA.md) during review.
Include the Dashboard and menu bar search fields, saved searches, source rules,
thresholds, privacy rules, and any new settings input. Report actual Apple Pinyin
and ABC results separately from prefilled functional tests; an unverified input
case remains open for release.

## Remaining development and acceptance review

Use the exact integrated candidate for release checks. A feature passing on a
previous branch is useful evidence but does not close the combined release gate.

| Goal | Remaining acceptance and development work |
|---|---|
| G1 · discovery and ingest | Verify installed-source access, onboarding, permission recovery, re-scan, watcher latency and exact counts on the combined app. Grok capture and adapter support stay deferred until a real source is available (DEV-008). Source settings and path/environment rules follow the form tests in the input matrix. |
| G2–G4 · search, sessions and projects | Verify the combined flow through search, filters, saved groups, grouping, transcript/tool navigation, archived search, Overview and Projects. Keep real Pinyin input and ABC shortcuts as separate acceptance cases. |
| G5–G7 · usage, menu bar and cost | Verify period, metric and filters, exact cost spot checks, pricing fallback and re-quote, and native menu panel search and actions. Include General’s clock and optional menu readout in release checks. Treat any local approval notification according to §11.5; apply the input matrix to new fields and shortcuts. |
| M5 · release | Verify archive and rebuild integrity, exclusion and retention behavior, both appearances and both UI languages, all §13 budgets, and the §15.5 checklist on the combined candidate. Track Developer ID signing and notarization separately from the local ad-hoc test build. |

Include search-filter token edits next to a Chinese composition in the
Apple Pinyin release checks, plus removal and focus shortcuts under ABC.
Grok fork display still needs real format evidence.

## Known gates and questions

| Item | Current disposition |
|---|---|
| Xcode | Xcode 27.2 is installed. Use command-local `DEVELOPER_DIR`; actual M0 build and signed/UI evidence is in the report. No global developer-directory change is needed. |
| GRDB version | The dependency is approved but no exact version is specified. Foundation selects a compatible release using official/versioned docs and commits an exact pin plus `Package.resolved`. |
| FTS registration | M0's schema requires `agentdash` to be registered before migration. GRDB-specific registration belongs in ADStore; reusable pure token splitting can live in ADCore. Do not create ADStore → ADSearch or use `unicode61` while claiming CJK acceptance. |
| Codex environments | See `FORMATS.md`. A model ID does not identify the execution environment; independently verify provider and model when launching a worker. |
| Status precedence | Owner-approved correction is in SPEC §10.4 and decision DEV-002. |
| Retention/rebuild | Before M5, resolve how rebuilding `token_minute` preserves rollups for already-expired `token_events` (§6.4 vs §6.5). Do not silently lose retained history. |
| Historical price changes | Before M4, clarify backdated effective prices vs the statement that historical costs never change. Show recomputation impact; do not rewrite old price entries. |

The latter two questions do not block M0. Ask the owner before implementing behavior
that changes their confirmed retention or pricing expectations.
