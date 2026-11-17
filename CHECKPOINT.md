# Coordinator checkpoint

## Current handover

- SPEC, development plan, task ownership and PR review gate are established.
- Owner approved the status-inference precedence clarification in SPEC §10.4.
- EXP-1 completed; metadata counts and caveats are in `docs/FORMATS.md`.
- Full Xcode 27 is not installed/selected; owner will install it. No M0 app
  build, UI or signed sandbox-access acceptance has run.
- Standard Codex preflight completed with provider `azure`, model `gpt-6.1-sol`,
  successful tool calls and process exit 0. Direct parent spawn retained Foundry.

## Worktrees

| Relative path | Branch | Assignment |
|---|---|---|
| Main checkout | `main` | Coordinator, shared docs, code review, PR merge |
| `.worktrees/m0-foundation` | `feat/m0-foundation` | `docs/tasks/M0-FOUNDATION.md` |
| `.worktrees/m0-tooling` | `feat/m0-tooling` | `docs/tasks/M0-TOOLING.md` |

Run `git worktree list`, `git status` and check each branch before continuing;
do not overwrite another agent's changes. Runtime process/session IDs and the
latest worker status belong in ignored `.worktrees/COORDINATOR-LOCAL.md`.

## Resume

1. Read `AGENTS.md`, `docs/DEVELOPMENT_PLAN.md`, `docs/HANDOVER.md`, and the local
   coordinator note. Reconcile pending owner answers and actual process state.
2. Inspect worker diffs and their `docs/reports/M0-*.md`; verify relevant checks.
3. Review tooling first; then integrate it into the foundation branch and verify
   the combined result. Keep app acceptance pending until Xcode evidence exists.
4. The coordinator owns PR creation/review/merge. No raw sessions, credentials,
   runtime output archives or real-session screenshots may be published.

Validation so far: metadata-only discovery, standard-agent preflight, local
worktree creation, Markdown file/link/whitespace checks, and Git diff checks.
These are setup checks, not app or package test results.
