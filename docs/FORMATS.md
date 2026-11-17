# Observed formats

## Evidence boundary

2026-11-17: coordinator completed EXP-1 by streaming local metadata. No raw
conversation text, credentials, session IDs or copied source files are included.
Ordinary JSONL was scanned at 2026-11-17T07:27:03.780525+00:00; compressed JSONL at
2026-11-17T07:29:51.500657+00:00. Live files can continue growing after these observations.

Only fields, record shapes and counts were extracted. The scan used existing
Python 3.15.2 `compression.zstd`; it installed nothing and did not change the
original files. This is format discovery, not adapter/fixture acceptance.

## Codex environments (EXP-1)

### Locations and launchers

- One discovered Codex root: `~/.codex`, with `sessions/` and `archived_sessions/`.
- No `CODEX_HOME` override was present in the coordinator shell. No `*.config.toml`
  profile files were found. Only base `config.toml` was present.
- Shell entrypoint inspection plus a home-directory search to file depth 5 found
  no extra `rollout-*.jsonl` locations. Search excluded Library, media directories,
  Trash, build/dependency/Git directories and other agents' default roots.
  This bounded search cannot establish that no deeper/custom/synced root exists.
- Ordinary `codex` resolves to CLI 0.169.0. Its current base config selects
  `model_provider = azure`, `model = gpt-6.1-sol`, via the existing standard proxy.
- `codex-astra` is a wrapper around the same CLI. Its current code retains the
  same `CODEX_HOME`, overrides the provider map for that process, chooses
  `astra_foundry` for fresh sessions, and defaults to `gpt-6-astra`.
- The former mixed launcher is retired in the currently inspected source.
  All three model IDs in the Foundry wrapper route through Foundry; selecting Sol
  there does not switch to the normal proxy. No launcher or global config changed.

### File inventory

| Files | Count | Interpretation |
|---|---:|---|
| Uncompressed rollout JSONL | 174 | 156 begin with `session_meta`; 18 are legacy headers |
| Compressed `.jsonl.zst` | 586 | 584 active-tree files and 2 archived-tree files; all begin with `session_meta` |
| Distinct modern session IDs across both encodings | 742 | IDs counted privately, not exported |
| Modern session IDs appearing in more than one scanned file | 0 | Metadata-only duplicate check |

The 18 legacy first records have keys `id,timestamp` (17 files), or
`id,instructions,timestamp` with null `instructions` (1 file), and no `type`.
Under the current SPEC these fail the Codex adapter's first-record validation.
Count/report them as unsupported legacy files; do not silently claim full coverage
or add an undocumented legacy parser. Raise a scoped compatibility question before
changing the validation rule.

Compressed records have `ordinal` in addition to `type,timestamp,payload`.
Unknown envelope fields must be tolerated. SEC-4's condition for a source-vendored
zstd decoder is now satisfied by observed files; a new package is still not allowed.
Capture and sanitize decompressed fixtures before implementing this path.

### Provider counts (modern files)

| `session_meta.model_provider` | Sessions |
|---|---:|
| `<missing>` | 8 |
| `astra_foundry` | 16 |
| `azure` | 717 |
| `azure_direct` | 1 |

### Origin / source / provider / CLI version combinations

`{subagent}` denotes the shape of an object, not its private parent IDs. A current
spawn uses `source.subagent.thread_spawn` with parent/depth/agent-path metadata.
Other helper sessions use `source.subagent.other`. Do not require `source` to be a string.

| originator | source | model_provider | cli_version | Count |
|---|---|---|---|---:|
| `Codex Desktop` | `vscode` | `azure` | `0.105.0` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.116.0-alpha.10` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.129.0-alpha.15` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.131.0-alpha.9` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.142.4` | 1 |
| `Codex Desktop` | `vscode` | `azure` | `0.142.5` | 6 |
| `Codex Desktop` | `vscode` | `azure` | `0.153.4` | 1 |
| `Codex Desktop` | `{subagent}` | `azure` | `0.131.0-alpha.9` | 1 |
| `Codex Desktop` | `{subagent}` | `azure` | `0.142.5` | 1 |
| `Codex Desktop` | `{subagent}` | `azure` | `0.144.3` | 2 |
| `codex-tui` | `cli` | `astra_foundry` | `0.164.0` | 2 |
| `codex-tui` | `cli` | `astra_foundry` | `0.166.0` | 2 |
| `codex-tui` | `cli` | `astra_foundry` | `0.169.0` | 1 |
| `codex-tui` | `cli` | `azure` | `0.115.0` | 2 |
| `codex-tui` | `cli` | `azure` | `0.118.0` | 13 |
| `codex-tui` | `cli` | `azure` | `0.120.0` | 4 |
| `codex-tui` | `cli` | `azure` | `0.122.0` | 3 |
| `codex-tui` | `cli` | `azure` | `0.125.0` | 5 |
| `codex-tui` | `cli` | `azure` | `0.128.0` | 3 |
| `codex-tui` | `cli` | `azure` | `0.129.0` | 1 |
| `codex-tui` | `cli` | `azure` | `0.130.0` | 10 |
| `codex-tui` | `cli` | `azure` | `0.134.0` | 4 |
| `codex-tui` | `cli` | `azure` | `0.137.0` | 1 |
| `codex-tui` | `cli` | `azure` | `0.139.0` | 9 |
| `codex-tui` | `cli` | `azure` | `0.141.0` | 2 |
| `codex-tui` | `cli` | `azure` | `0.142.0` | 8 |
| `codex-tui` | `cli` | `azure` | `0.142.5` | 6 |
| `codex-tui` | `cli` | `azure` | `0.144.3` | 3 |
| `codex-tui` | `cli` | `azure` | `0.144.4` | 8 |
| `codex-tui` | `cli` | `azure` | `0.144.6` | 4 |
| `codex-tui` | `cli` | `azure` | `0.145.0` | 20 |
| `codex-tui` | `cli` | `azure` | `0.147.0` | 11 |
| `codex-tui` | `cli` | `azure` | `0.148.0` | 1 |
| `codex-tui` | `cli` | `azure` | `0.149.0` | 4 |
| `codex-tui` | `cli` | `azure` | `0.150.1` | 3 |
| `codex-tui` | `cli` | `azure` | `0.151.0` | 2 |
| `codex-tui` | `cli` | `azure` | `0.152.1` | 5 |
| `codex-tui` | `cli` | `azure` | `0.153.1` | 3 |
| `codex-tui` | `cli` | `azure` | `0.153.4` | 26 |
| `codex-tui` | `cli` | `azure` | `0.154.0` | 17 |
| `codex-tui` | `cli` | `azure` | `0.155.1` | 4 |
| `codex-tui` | `cli` | `azure` | `0.156.0` | 4 |
| `codex-tui` | `cli` | `azure` | `0.160.1` | 3 |
| `codex-tui` | `cli` | `azure` | `0.162.1` | 5 |
| `codex-tui` | `vscode` | `azure` | `0.157.1` | 4 |
| `codex-tui` | `vscode` | `azure` | `0.158.0` | 3 |
| `codex-tui` | `vscode` | `azure` | `0.159.0` | 4 |
| `codex-tui` | `vscode` | `azure` | `0.159.2` | 1 |
| `codex-tui` | `vscode` | `azure` | `0.159.3` | 5 |
| `codex-tui` | `vscode` | `azure` | `0.160.0` | 3 |
| `codex-tui` | `vscode` | `azure` | `0.160.1` | 1 |
| `codex-tui` | `vscode` | `azure` | `0.161.0` | 4 |
| `codex-tui` | `vscode` | `azure` | `0.162.0` | 2 |
| `codex-tui` | `vscode` | `azure` | `0.162.1` | 9 |
| `codex-tui` | `vscode` | `azure` | `0.163.0` | 15 |
| `codex-tui` | `vscode` | `azure` | `0.164.0` | 7 |
| `codex-tui` | `vscode` | `azure` | `0.165.0` | 4 |
| `codex-tui` | `vscode` | `azure` | `0.166.0` | 18 |
| `codex-tui` | `vscode` | `azure` | `0.167.0` | 3 |
| `codex-tui` | `vscode` | `azure` | `0.167.1` | 2 |
| `codex-tui` | `vscode` | `azure` | `0.167.2` | 2 |
| `codex-tui` | `vscode` | `azure` | `0.169.0` | 4 |
| `codex-tui` | `{subagent}` | `astra_foundry` | `0.164.0` | 3 |
| `codex-tui` | `{subagent}` | `astra_foundry` | `0.166.0` | 3 |
| `codex-tui` | `{subagent}` | `astra_foundry` | `0.167.2` | 3 |
| `codex-tui` | `{subagent}` | `astra_foundry` | `0.169.0` | 2 |
| `codex-tui` | `{subagent}` | `azure` | `0.118.0` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.120.0` | 2 |
| `codex-tui` | `{subagent}` | `azure` | `0.122.0` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.125.0` | 4 |
| `codex-tui` | `{subagent}` | `azure` | `0.130.0` | 1 |
| `codex-tui` | `{subagent}` | `azure` | `0.144.3` | 1 |
| `codex-tui` | `{subagent}` | `azure` | `0.144.4` | 1 |
| `codex-tui` | `{subagent}` | `azure` | `0.145.0` | 11 |
| `codex-tui` | `{subagent}` | `azure` | `0.147.0` | 13 |
| `codex-tui` | `{subagent}` | `azure` | `0.148.0` | 1 |
| `codex-tui` | `{subagent}` | `azure` | `0.149.0` | 5 |
| `codex-tui` | `{subagent}` | `azure` | `0.150.1` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.151.0` | 3 |
| `codex-tui` | `{subagent}` | `azure` | `0.152.1` | 7 |
| `codex-tui` | `{subagent}` | `azure` | `0.153.1` | 5 |
| `codex-tui` | `{subagent}` | `azure` | `0.153.4` | 42 |
| `codex-tui` | `{subagent}` | `azure` | `0.154.0` | 22 |
| `codex-tui` | `{subagent}` | `azure` | `0.155.1` | 8 |
| `codex-tui` | `{subagent}` | `azure` | `0.156.0` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.157.1` | 7 |
| `codex-tui` | `{subagent}` | `azure` | `0.158.0` | 4 |
| `codex-tui` | `{subagent}` | `azure` | `0.159.0` | 4 |
| `codex-tui` | `{subagent}` | `azure` | `0.159.2` | 2 |
| `codex-tui` | `{subagent}` | `azure` | `0.159.3` | 11 |
| `codex-tui` | `{subagent}` | `azure` | `0.160.0` | 13 |
| `codex-tui` | `{subagent}` | `azure` | `0.160.1` | 4 |
| `codex-tui` | `{subagent}` | `azure` | `0.161.0` | 9 |
| `codex-tui` | `{subagent}` | `azure` | `0.162.0` | 3 |
| `codex-tui` | `{subagent}` | `azure` | `0.162.1` | 37 |
| `codex-tui` | `{subagent}` | `azure` | `0.163.0` | 29 |
| `codex-tui` | `{subagent}` | `azure` | `0.164.0` | 12 |
| `codex-tui` | `{subagent}` | `azure` | `0.165.0` | 6 |
| `codex-tui` | `{subagent}` | `azure` | `0.166.0` | 17 |
| `codex-tui` | `{subagent}` | `azure` | `0.167.0` | 8 |
| `codex-tui` | `{subagent}` | `azure` | `0.167.1` | 3 |
| `codex-tui` | `{subagent}` | `azure` | `0.167.2` | 5 |
| `codex-tui` | `{subagent}` | `azure` | `0.168.0` | 2 |
| `codex-tui` | `{subagent}` | `azure` | `0.169.0` | 4 |
| `codex_cli_rs` | `cli` | `<missing>` | `0.46.0` | 4 |
| `codex_cli_rs` | `cli` | `azure` | `0.106.0` | 3 |
| `codex_cli_rs` | `cli` | `azure` | `0.107.0` | 1 |
| `codex_cli_rs` | `cli` | `azure` | `0.111.0` | 4 |
| `codex_cli_rs` | `cli` | `azure` | `0.112.0` | 5 |
| `codex_cli_rs` | `cli` | `azure` | `0.114.0` | 8 |
| `codex_cli_rs` | `cli` | `azure` | `0.116.0` | 9 |
| `codex_cli_rs` | `cli` | `azure` | `0.117.0` | 7 |
| `codex_cli_rs` | `vscode` | `<missing>` | `0.40.0` | 4 |
| `codex_cli_rs` | `{subagent}` | `azure` | `0.116.0` | 7 |
| `codex_cli_rs` | `{subagent}` | `azure` | `0.117.0` | 8 |
| `codex_exec` | `exec` | `azure` | `0.139.0` | 3 |
| `codex_exec` | `exec` | `azure` | `0.144.3` | 2 |
| `codex_exec` | `exec` | `azure` | `0.144.6` | 1 |
| `codex_exec` | `exec` | `azure` | `0.145.0` | 13 |
| `codex_exec` | `exec` | `azure` | `0.148.0` | 3 |
| `codex_exec` | `exec` | `azure` | `0.149.0` | 2 |
| `codex_exec` | `exec` | `azure` | `0.151.0` | 1 |
| `codex_exec` | `exec` | `azure_direct` | `0.145.0` | 1 |
| `codex_exec` | `{subagent}` | `azure` | `0.145.0` | 1 |
| `codex_exec` | `{subagent}` | `azure` | `0.148.0` | 1 |
| `codex_exec` | `{subagent}` | `azure` | `0.151.0` | 1 |
| `ssh_network_diagnostic` | `vscode` | `azure` | `0.162.1` | 3 |
| `ssh_network_diagnostic` | `{subagent}` | `azure` | `0.162.1` | 3 |

### Model distribution

Counts below are `turn_context` records, not token usage or distinct sessions.

| `turn_context.model` | Records |
|---|---:|
| `gpt-6-luna` | 4286 |
| `gpt-5.6-luna` | 2057 |
| `gpt-6-astra` | 714 |
| `gpt-6.1-sol` | 584 |
| `gpt-5.4` | 516 |
| `gpt-5.6-sol` | 450 |
| `gpt-5.5` | 349 |
| `gpt-5.3-codex` | 113 |
| `codex-auto-review` | 40 |
| `gpt-5.6-terra` | 11 |
| `gpt-5-codex` | 6 |

### Environment classification and delegation

Use one Source for the shared root and environment rules on `model_provider` for
new sessions. Keep provider labels literal by default (`azure`, `astra_foundry`,
`azure_direct`, or unknown); user-friendly labels can be confirmed separately.
`originator/source` classify entrypoints/subagents and must not be used as a backend identifier.

Historical caveat: the current wrapper's resume path can reuse a saved provider ID
while redirecting its process-local provider definition to Foundry. Thus an old
`azure` label cannot prove that a specific historical request used the normal proxy.
Model IDs are also shared between environments. Preserve this uncertainty in the
UI instead of asserting account/provider routing that the stored evidence cannot establish.

A completed read-only delegation preflight from the coordinator used:
- Requested model: `gpt-6.1-sol`.
- Observed child `turn_context.model`: `gpt-6.1-sol`.
- Observed child `session_meta.model_provider`: `astra_foundry`.
- Tool execution and final marker completed successfully.

This proves model override works here but does **not** switch to the standard
environment. A fresh ordinary-Codex preflight is required before standard workers
can be described as verified. Its first launch was blocked by automatic approval
review pending explicit approval of the existing proxy destination and project
context; no standard-process success is claimed by this report.

## Adapter fixture status

Claude, Codex, Copilot and Grok adapter fixtures have not yet been captured or
approved. M0-TOOLING must first deliver and validate the sanitizer. EXP-1 does not
waive capture-before-parser, accounting golden tests, or read-only source access.
