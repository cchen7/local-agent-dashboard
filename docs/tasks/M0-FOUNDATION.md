# M0-FOUNDATION — Native skeleton and storage contracts

## Read and own

Read SPEC §0, §2–4, §6–8, §9.2, §11–16; FORMATS and DECISIONS.
Requirement anchors: SEC-1…8, ADP-3/5, FR-SRC-1/2, M0.

Branch `feat/m0-foundation`; worktree `.worktrees/m0-foundation`.
Own `AgentDashboard.xcodeproj`, `App/`, `Packages/AgentDashKit/`, and
`docs/reports/M0-FOUNDATION.md`. Do not edit `Tools/` or shared planning documents.

## Deliver

1. Swift 6 strict-concurrency package with the eight modules and only the dependency
   edges in §4.2. Select a compatible GRDB release, pin it exactly, commit the lockfile.
   Verify external API use via Context7 or official version-specific docs.
2. Minimal Sendable domain/source/checkpoint/normalized-record contracts needed by
   later adapters and ingestion. Explain exported contracts in your report; do not
   speculate about agent formats or implement adapters in this task.
3. ADStore v1 schema/migrations and public store boundary. Register `agentdash`
   before migration; keep the dependency direction described in DEV-004. Include
   meaningful tests for fresh/reopened DBs, idempotent writes, FTS trigger sync and
   the required basic tokenizer cases. All DB tests use temporary synthetic data.
4. Native app target: macOS 27, arm64, sandbox and hardened runtime; exact §12.1
   entitlements, empty window/navigation/menu bar/settings entry points and English/
   Simplified Chinese String Catalog. No SQL directly in App, no networking.
5. A narrow source-access verification path for M0: signed app can read default
   locations, or the bookmark fallback works. Never write to a source to test this.
   Source counts/access status are enough; do not show real transcript content.

No ingestion, vendor parsers, pricing table population, live token dashboard or full
search UI in this task. `.jsonl.zst` is observed, but decoder implementation belongs
to the Codex adapter task; do not add an unreviewed compression package to M0.

## Verification and return

- Run package tests. Create the documented shared scheme and keep it buildable.
- Once Xcode is installed, use the build/app-test commands in AGENTS. Use a
  task-specific DerivedData path under an approved temporary directory.
- Bring reviewed tooling from `origin/main` into this branch and run all applicable
  guardrails against the actual signed app. Before tools exist, report that gap.
- Compare skeleton UI geometry to Figma per §11/§18 at 960×600, 1120×720 and
  1440×900, dark then light, with synthetic/empty data only.
- Xcode/signing/access failures are blockers to M0 acceptance, not evidence of a
  product failure or permission to change entitlements/global configuration.
- Record exact commands, results and skips in `docs/reports/M0-FOUNDATION.md`.
  Prepare a draft PR if required verification remains blocked. Never merge it.
