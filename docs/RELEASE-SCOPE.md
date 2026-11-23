# Agent Dashboard 0.1.0 release scope

The 0.1.0 candidate is a local, read-only app for Apple silicon Macs
running macOS 27. It indexes the following local records:

| Source | Supported input |
| --- | --- |
| Claude Code | Local project session records and supported subagent records. |
| Codex | Local rollouts from Codex CLI and the desktop app, including supported compressed rollouts. |
| GitHub Copilot CLI | Local session event streams. A workspace that has only metadata is not an indexed transcript or usage source. |
| Grok Build | Not supported in 0.1.0. The format capture and adapter are deferred under DEV-008. |

Search covers English and Chinese text in the indexed records. The app
shows session and project history, token usage, and estimated cost. A
cost is an estimate from public API list prices; usage without a known
model and effective rate remains unpriced.

Cloud sessions and transcript export are outside this release. The app
does not change an agent's source files or make network requests.

The broader product spec still includes Grok Build as a planned source.
For 0.1.0, the data acceptance checklist applies to the three supported
sources above; the counting tolerance and per-agent pricing checks
still apply. The [release checklist](SPEC.md#155-release-checklist)
and [distribution checks](RELEASE-VERIFY.md) determine release readiness.
