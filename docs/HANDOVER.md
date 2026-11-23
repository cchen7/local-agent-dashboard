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

Use the authorized development environment for the assigned worktree. A model
override need not change the provider; check the recorded provider and model
before handing off a task. Keep credentials, opaque history, private launcher
settings and runtime checkpoints outside the public repository. Do not modify
global configuration.

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
