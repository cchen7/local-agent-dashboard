# Coordinator checkpoint

## Current handover

- SPEC, development plan, task ownership and PR review gate are established.
- Owner approved the status-inference precedence clarification in SPEC §10.4.
- EXP-1 completed; metadata counts and caveats are in `docs/FORMATS.md`.
- Full Xcode 27 is not installed/selected; owner will install it. No M0 app
  build, UI or signed sandbox-access acceptance has run.
- Standard Codex preflight completed with provider `azure`, model `gpt-6.1-sol`,
  successful tool calls and process exit 0. Direct parent spawn retained Foundry.
- Two ordinary Codex workers completed both development and review-fix turns.
- [Tooling PR #1](https://github.com/cchen7/local-agent-dashboard/pull/1) is merged.
- [Foundation PR #2](https://github.com/cchen7/local-agent-dashboard/pull/2) remains
  Draft and includes the merged tooling. Combined API/dependency checks, 40 tool
  tests and 13 package test functions (20 tokenizer cases) passed.
- Figma default Sessions context/screenshot and window node sizes were verified.
  Actual window nodes are `11:2624` (1120×720), `43:961` (960×600), `45:1643`
  (1440×900); minimum/large SPEC frame IDs include surrounding wallpaper. Menu
  panel `31:847` is 360 points wide. No native UI comparison has run yet.

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
2. Read `docs/reports/M0-FOUNDATION.md` and recheck Draft PR #2/current branch state.
3. After Xcode 27 is available, run the actual app build and UI tests, inspect the
   signed artifact, verify sandbox source access/bookmark fallback, and compare
   the three window sizes in dark then light mode. Keep acceptance pending until
   that execution evidence exists. Do not start M1 or close M0 prematurely.
4. The coordinator owns PR creation/review/merge. No raw sessions, credentials,
   runtime output archives or real-session screenshots may be published.

Validation so far: metadata-only discovery, standard-agent preflight, local
worktree creation, Markdown file/link/whitespace checks, and Git diff checks.
These are setup checks, not app or package test results.
