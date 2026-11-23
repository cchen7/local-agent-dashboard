# Agent Dashboard

A local, read-only macOS dashboard for coding-agent sessions and token usage.
The application never accesses the network or calls a model.

The 0.1.0 candidate runs on Apple silicon with macOS 27. It indexes local
Claude Code, Codex (CLI and desktop), and GitHub Copilot CLI sessions.
Grok Build is not supported in 0.1.0. See the
[release scope](docs/RELEASE-SCOPE.md) for the supported records and limits.

Development starts with [AGENTS.md](AGENTS.md) and [the specification](docs/SPEC.md).
See [the development plan](docs/DEVELOPMENT_PLAN.md) for milestones and review gates,
and [the handover](docs/HANDOVER.md) for worktrees and task prompts.

Release status: local candidate under review. See
[release verification](docs/RELEASE-VERIFY.md) for signing, verification,
and first-install checks before distribution.
