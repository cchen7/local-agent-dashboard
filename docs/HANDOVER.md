# Handover

## Start here

Read `AGENTS.md`, SPEC §0 and §2, `DECISIONS.md`, `FORMATS.md`, then the assigned
task below. This is a new repository; do not infer that missing tools or tests ran.
The coordinator manages `main` and all PR merges.

| Agent task | Working directory from repository root | Branch | Assignment |
|---|---|---|---|
| Foundation | `.worktrees/m0-foundation` | `feat/m0-foundation` | [M0-FOUNDATION](tasks/M0-FOUNDATION.md) |
| Tooling | `.worktrees/m0-tooling` | `feat/m0-tooling` | [M0-TOOLING](tasks/M0-TOOLING.md) |

These are linked Git worktrees: files and indexes are separate, while refs and Git
configuration are shared. Do not change shared Git configuration, check out `main`,
or manipulate another task's branch. See the [Git 2.54 worktree reference](https://github.com/git/git/blob/v2.54.0/Documentation/git-worktree.adoc).

Check `pwd`, `git branch --show-current`, `git status --short` and
`git worktree list` before editing. If the directory/branch does not match your
assignment, stop editing and report it. Preserve any pre-existing changes.

## Launch and environment

The requested model is `gpt-6.1-sol` in the normal `codex` environment. An agent
spawned from a Foundry-backed parent can inherit `astra_foundry` even when its
model is overridden. A completed preflight established this locally.

The coordinator must start a fresh normal Codex task/process with the ordinary
provider, rather than resume or fork the Foundry conversation. Verify both
`session_meta.model_provider` and `turn_context.model`, plus completed tool execution,
before assigning coding work. Do not copy credentials, auth files, or opaque
encrypted conversation history between environments. Do not modify global config.

Run from the assigned worktree. Standard CLI shape (use the locally verified
ordinary provider ID, not a guessed provider):

```sh
codex --no-daemon --model gpt-6.1-sol -c 'model_provider="azure"'
```

The coordinator records actual launch/session status in a local checkpoint.
This document is not proof that a coding worker has started or completed.

## Foundation prompt

```text
You own feat/m0-foundation in .worktrees/m0-foundation. Verify your cwd and branch.
Read AGENTS.md, docs/SPEC.md §0/§2 and relevant sections, docs/DECISIONS.md,
docs/FORMATS.md, and docs/tasks/M0-FOUNDATION.md. Implement only that assignment.
Do not edit Tools or another worktree. Preserve existing changes. Do not launch
other agents, install Xcode, change global configuration, or touch agent sources.
Write tests first for store/accounting behavior. Report actual checks and blockers
in docs/reports/M0-FOUNDATION.md. Prepare a scoped PR to main; do not merge it.
```

## Tooling prompt

```text
You own feat/m0-tooling in .worktrees/m0-tooling. Verify your cwd and branch.
Read AGENTS.md, docs/SPEC.md §0/§2 and relevant sections, docs/DECISIONS.md,
docs/FORMATS.md, and docs/tasks/M0-TOOLING.md. Implement only that assignment.
Own Tools and docs/reports/M0-TOOLING.md; do not edit App, package manifests or
another worktree. Use synthetic data only while developing the capture tool.
Do not read real session content into model context, change global configuration,
or launch other agents. Report checks and gaps; prepare a PR to main, never merge.
```

## Return to the coordinator

Provide branch/commit/PR, owned files, requirement IDs, behavior changes, actual
commands and results, and unresolved questions. Put temporary builds/test data
outside the repository. If a required tool is unavailable, finish independent work
and leave the affected acceptance checks explicitly pending.
