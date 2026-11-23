# Coordinator checkpoint

## Historical M0 state

M0 local acceptance is complete; PR #2 is ready for final review/merge. Read its
actual GitHub state before proceeding. The implementation is an empty native shell
and storage baseline, not the complete dashboard.

- Xcode 27.2 and macOS SDK 27.2 installed/initialized by owner; use command-local
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Real App build/build-for-testing passed without compiler/metadata warnings.
- Actual App signature passed exact entitlements and Hardened Runtime checks.
- Full-Xcode package tests passed (13 functions, including 20 tokenizer cases).
- Tool tests passed (40, zero skipped); API/dependency guards passed.
- Navigation/Settings and six size/appearance geometry cases passed automatically.
- Six real synthetic-window screenshots were captured with the explicitly
  authorized Computer Use tool and inspected. No runner recording access was added.
- The menu entry is not exposed to XCTest on this desktop. The owner opened it in
  manual-entry mode; actual panel width and Open Dashboard assertions passed.
  The unattended skip is recorded separately and is never counted as a pass.
- Signed App directory access succeeded for Claude/Codex/Copilot (metadata only).
  Grok is not installed; owner explicitly deferred it locally.
- EXP-1 findings and compressed Codex evidence are in `docs/FORMATS.md`.

Evidence and exact commands: `docs/reports/M0-FOUNDATION.md`.
Private local runtime details: main checkout `.worktrees/COORDINATOR-LOCAL.md`.
No real adapters or source fixtures have been implemented/captured yet.

## Worktrees

| Path relative to main checkout | Branch | Purpose |
|---|---|---|
| Main checkout | `main` | Coordinator and accepted baseline |
| `.worktrees/m0-foundation` | `feat/m0-foundation` | PR #2 foundation and UI acceptance |
| `.worktrees/m0-tooling` | `feat/m0-tooling` | Merged PR #1 tooling, retained |

Recheck branch/status before editing. Preserve uncommitted changes and retained
worktrees; do not force-reset or delete them as cleanup.

## Next stage

After PR #2 is merged, create M1 worktrees from accepted `main`. First extend and
review the compressed fixture-capture path, then capture/sanitize representative
Claude/Codex data locally before writing adapters. Golden accounting tests must be
hand-computed and exact. Keep raw session content and credentials out of model
context, logs, commits and PRs. Grok remains deferred until real local data exists.

Use the authorized development environment for each worktree. See the repository
README and release tags for the shipped product, rather than this M0 checkpoint.
