# M0-TOOLING — Guardrails and safe fixture capture

## Read and own

Read SPEC §0, §2, §5.3, §12, §14.4 and §15.2; FORMATS and DECISIONS.
Requirement anchors: SEC-1…8, ADP-1…7, M0.

Branch `feat/m0-tooling`; worktree `.worktrees/m0-tooling`.
Own `Tools/` and `docs/reports/M0-TOOLING.md`. Do not edit the Swift package, App,
Xcode project, shared documentation or another worktree. Synthetic tool fixtures
and tool tests live under `Tools/tests/`, not in the other agent's package targets.

## Deliver

1. `Tools/forbid-apis.sh`: inspect production app/package sources for the forbidden
   network, process/Apple Events and AI APIs. Do not scan `.worktrees/`, vendored
   build caches or prose references as production code. Exercise both allowed
   source and injected forbidden examples; comments/fixtures must not hide real use.
2. `Tools/check-entitlements.sh <app>`: inspect the signed artifact, reject network
   or unknown keys, validate the allowed paths and required sandbox values. Fail
   clearly for missing/unsigned app or missing prerequisites; never report success
   by silently skipping artifact inspection.
3. Dependency allow-list validation: GRDB is the only currently selected dependency.
   Verify exact pin and lockfile consistency when the package exists. Source-vendored
   zstd is conditionally allowed by SPEC, not permission for a new package or runtime.
   Report absent package/lockfile as an unmet integration prerequisite.
4. `Tools/fixture-capture`: a documented local command taking explicit input/output
   paths, reading source files without modification, sanitizing into a separate
   destination and producing `.sanitized` markers only after validation. Reject
   same-file/inside-source outputs, including symlink aliases; never overwrite input.
5. Tests first for capture safety and sanitization. Preserve schema/numeric accounting
   values and useful deterministic identifier relationships; replace content, paths,
   sensitive metadata and secrets. Document how Unicode length and schema-string
   allow-lists work. Unknown strings must not leak simply because a field is new.

Use existing runtimes/standard libraries; no global installation. Build and test
the capture tool exclusively on synthetic input. Do not include raw real session
content in prompts, tool output or the repository. Actual capture for adapters is
a later step after the tool's sanitization has been reviewed.

## Verification and return

- Demonstrate pass/fail behavior of each guardrail with synthetic cases, including
  a forbidden API, extra entitlement, and unapproved dependency.
- Demonstrate source unchanged, output isolated, secret removal, stable IDs,
  preserved token numbers, Unicode handling and marker failure behavior.
- Document each command's usage and exit codes. Before Foundation is merged, signed
  app and real package integration checks remain pending; tool tests are not those checks.
- Record commands/results and limitations in `docs/reports/M0-TOOLING.md`.
  Prepare a scoped PR to `main`; do not merge. The coordinator integrates and reviews.
