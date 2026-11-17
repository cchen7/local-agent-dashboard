# Agent Dashboard

A local, read-only macOS dashboard for coding-agent sessions and token usage.
The application never accesses the network or calls a model.

Development starts with [AGENTS.md](AGENTS.md) and [the specification](docs/SPEC.md).
See [the development plan](docs/DEVELOPMENT_PLAN.md) for milestones and review gates,
and [the handover](docs/HANDOVER.md) for worktrees and task prompts.

Current stage: M0 foundation validated; M1 data ingestion is next. The native shell
and store build with Xcode 27, but the app does not index sessions yet. See
[CHECKPOINT.md](CHECKPOINT.md) for verification and the next handover.
