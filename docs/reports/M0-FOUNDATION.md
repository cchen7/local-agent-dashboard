# M0 foundation acceptance — 2026-11-17

M0's local foundation has been validated. This is an empty native shell and storage
baseline; vendor adapters, ingestion, populated session/project views, token charts,
pricing and release qualification belong to later milestones.

## Implementation

- macOS 27 / arm64 Xcode project, shared scheme, Swift 6 complete concurrency,
  eight-module package with the SPEC §4.2 dependency direction.
- Exact GRDB.swift 7.11.1 pin, revision
  `b83108d10f42680d78f23fe4d4d80fc88dab3212`, identical package/Xcode locks.
- App-owned WAL database, v1 migrations and FTS triggers. ADStore registers
  `agentdash` before migration on every connection; pure token splitting is in ADCore.
- Idempotent source/file/record writes and atomic record/checkpoint updates.
  Same-session corrections update rows; inherited records retain their first owner.
  `last_seq` and `previous_ts` preserve file ordering and timestamp inheritance.
- Native empty Sessions/Projects/Token Usage navigation, Settings and menu panel,
  English/Simplified Chinese catalog, directory-access verification only.
- Native outer-window minimum is 960×600. Settled toolbar chrome is measured instead
  of hardcoding its height; unchanged native properties are not repeatedly assigned.
- Test-only `--synthetic` launches select one of the three SPEC sizes and app-local
  dark/light appearance. They never resolve or read the user's source roots.

The store boundary does not yet maintain usage rollups, pricing, insights or
retention. No vendor parser or real fixture was introduced in M0.

## Execution evidence

Xcode 27.2 (27B52), macOS SDK 27.2, Apple silicon. Commands selected Xcode through
`DEVELOPER_DIR`; the global developer-directory setting was not changed.

| Check | Observed result |
|---|---|
| App build and build-for-testing | Passed with no compiler or metadata-extraction warnings |
| Actual App signature | Exact frozen entitlements, valid signature and Hardened Runtime passed the guard |
| Package tests with full Xcode | 13 test functions, including 20 tokenizer cases, passed |
| Developer-tool tests | 40 passed, zero skipped |
| API/dependency guards | 18 production source files passed; exact GRDB pin and locks consistent |
| Native UI navigation and Settings | Sessions/Projects/Token Usage switching and two Settings reopen cycles passed |
| Native UI geometry | All six combinations of 960×600, 1120×720, 1440×900 and dark/light passed |
| Menu panel/reopen | User opened the visible menu entry; XCTest asserted the real 360-point Dialog, clicked Open Dashboard and verified the main window returned |
| Visual review | Six actual synthetic-window screenshots captured through the owner's already-authorized Computer Use tool and inspected |
| Real default-source access | Claude Code, Codex and Copilot directory enumeration succeeded; no session content opened |
| Grok | Default root absent; owner confirmed not installed and deferred local validation |

The normal unattended UI run reported **2 passed, 1 skipped, 0 failures** on this
Mac because the native menu entry was not exposed to XCTest. That skip is not a
pass. The same menu test was separately executed in explicit manual-entry mode and
**passed its real panel and reopening assertions**. Changes to that feature still
require manual entry validation when the automation host cannot locate the item.

No additional screen-recording permission was granted to the runner. Failed runner
screenshots were replaced by an explicitly approved native Computer Use review;
the failure was not converted into a passing automated screenshot claim.

## Native visual review

Compared the M0 shell with the relevant Figma window structure and SPEC §11/§18:

| Window | Figma window node | Dark | Light |
|---|---|---|---|
| 960×600 | `43:961` inside frame `43:959` | Captured and inspected | Captured and inspected |
| 1120×720 | `11:2624` | Captured and inspected | Captured and inspected |
| 1440×900 | `45:1643` inside frame `45:1641` | Captured and inspected | Captured and inspected |

The native toolbar/sidebar/three-column structure remains usable at all sizes;
empty-state text wraps without clipping or overflow. The initial minimum dark
capture is an inactive-window state; the other five were raised before capture.
The cursor halo in some images belongs to the capture interaction, not App UI.

This is a comparison of M0 chrome, navigation and empty layouts, not pixel parity
with the populated prototype. Session rows, transcript/overview content, charts and
full responsive list-width interpolation remain their planned later-milestone work.
The current bounded native list uses a 356-point ideal width.

Native captures are local JPEG files (2× pixels per point) under
`/private/tmp/agentdash-m0-visual/captures/`; `manifest.json` records dimensions and
SHA-256 hashes. They contain only synthetic empty windows. They are not committed.

## Source-access evidence

The normal signed, sandboxed, hardened App was launched independently of the UI
runner. Sources → Verify Access reported top-level entry counts:

| Source | Result |
|---|---|
| Claude Code | Readable, 46 entries |
| Codex | Readable, 70 entries |
| Copilot CLI | Readable, 55 entries |
| Grok Build | Directory not found; owner-confirmed local deferral |

Counts describe that observation, not session totals. The available default roots
worked through the frozen read-only exceptions, so the fallback was not required.
Valid bookmark-grant persistence is not claimed as executed; invalid-bookmark and
synthetic-directory cases were checked separately. Source management/bookmark
lifecycle coverage is completed in M2.

## Reproduction and local artifacts

Use a task-specific directory outside the repository for all build products.
The current test workflow uses SyntheticQA rather than the original M0 Debug
bundle. Its separate bundle identifier and early entry point protect the
normal app's preferences and index from accidental launches.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project AgentDashboard.xcodeproj -scheme AgentDashboard -configuration SyntheticQA \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/agentdash-m0-xcode-worker/ui-fix/DerivedData \
  -clonedSourcePackagesDirPath /private/tmp/agentdash-m0-xcode-worker/packages \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build-for-testing

codesign --force --sign - --options runtime \
  --entitlements App/AgentDashboard.entitlements \
  /private/tmp/agentdash-m0-xcode-worker/ui-fix/DerivedData/Build/Products/SyntheticQA/AgentDashboard.app

Tools/check-synthetic-launch.sh \
  /private/tmp/agentdash-m0-xcode-worker/ui-fix/DerivedData/Build/Products/SyntheticQA/AgentDashboard.app
```

Then use `xcodebuild test-without-building` with the generated SyntheticQA
`.xctestrun` file. Keep `--synthetic` explicit at launch. The guard verifies the
signed bundle identity and compiled refusal before testing the no-argument
exit. It will not launch a normal build. Do not use discovery or capture tools
that may implicitly launch the dashboard without the test arguments.
Xcode ad-hoc builds omit the runtime flag, and test builds add testing entitlements;
explicit re-signing/readback is necessary for this local M0 validation. App Debug
uses `ENABLE_DEBUG_DYLIB=NO` to avoid the real library-validation launch failure.
No security exceptions were added. Release Developer ID/notarization remains M5.

Ordinary UI tests neither request recording permission nor capture screenshots.
For visual review, a local copy of the `.xctestrun` target's environment sets
`AGENTDASH_VISUAL_REVIEW_DIR` to a fresh directory beneath
`/private/tmp/agentdash-m0-visual/`. The geometry test emits
`AGENTDASH_VISUAL_REVIEW_READY <case>` and waits for `<case>.ack`. The coordinator
captures and inspects the actual window before writing that acknowledgment.
Normal tests do not wait. Never create acknowledgments without inspecting images.

For the menu host limitation, set `AGENTDASH_MANUAL_MENU_REVIEW=1` in a local test
configuration. If the native entry is unavailable to XCTest, the test waits for a
person to open the **real** panel, then retains all width/reopening assertions.
No fake panel or weakened assertion substitutes for the feature.

Key local evidence:

- `agentdash-m0-xcode/package-tests.log`: full-Xcode package tests.
- `agentdash-m0-xcode/UI-CUA-review2.xcresult`: six serialized native geometry/visual handoffs.
- `agentdash-m0-xcode/UI-manual-menu.xcresult`: actual panel and reopening assertions passed.
- `agentdash-m0-xcode/UI-unattended-final.xcresult`: two passed and one explicitly skipped UI test.
- `agentdash-m0-visual/captures/manifest.json`: six captured images and hashes.

All paths above are relative to `/private/tmp/`. Keep raw diagnostic bundles local;
failed-test artifacts can include system UI metadata. No real session text,
credentials or unsanitized source fixtures were published.

## Remaining milestone gates

M1 starts with reviewed real-file capture before any adapter. Compressed Codex files
are confirmed, but the capture/decoder path still needs its scoped implementation.
Feature-scale performance budgets, real-session accounting accuracy, archive and
pricing behavior, populated Figma parity and release network observation remain
future acceptance work; this report does not claim them completed.
