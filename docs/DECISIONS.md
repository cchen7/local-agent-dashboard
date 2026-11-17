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

## DEV-003 — Missing full Xcode (2026-11-17)

The current developer directory is Command Line Tools; `xcodebuild -version`
failed. Swift 6.4.2 is available. The owner will install Xcode 27. Proceed with
independent tooling/package work; do not mark app build, UI, signed sandbox access
or the M0 milestone as verified until the required execution evidence exists.

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
