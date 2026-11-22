# Fixed Apple input source QA

Follow the hard keyboard rules in [AGENTS.md](../../AGENTS.md). The evidence
for search behavior, keyboard shortcuts, and native Chinese composition is
reported separately. None of these cases needs compatibility with a third-party
input method.

| QA area | Default unattended check | Actual keyboard acceptance |
|---|---|---|
| Chinese search, matching and paging (M3, NFR-4/NFR-9) | Launch with the normal search field prefilled from a synthetic fixture. Verify its value, Chinese hits, previous/next buttons, boundaries, paging, retention after rebuild, and navigation to a folded tool result. | In an opt-in run with Apple's **Pinyin – Simplified** already selected, type the physical keys for **zhongwen**, commit **中文**, and verify the normal search field and indexed hit. Prefill does not prove composition. |
| Shortcut dispatch (M3–M5) | Click Sessions, Projects, Usage, and the controls for next/previous match and copying a resume command. | In an opt-in **ABC** run, exercise ⌘1/2/3, ⌘G/⇧⌘G, and ⇧⌘C where the feature is implemented. Verify both disabled match boundaries and actual actions. |
| Text fields (M2–M5) | Check empty/invalid sources, cancellation, validation fixtures, and persistence without keyboard injection. | Use **ABC** for actual entry in the add-source form and editing a saved source where supported. Use that same rule for any new editable search, mapping/rule, threshold or settings QA. |
| Onboarding, watcher and archive lifecycle, Overview, tool rows, menu bar, metrics/pricing, privacy and storage controls (M0–M5) | Use synthetic sources, fixtures, click actions and existing signed App checks. Capture UI at 960×600, 1120×720 and 1440×900 in dark/light as appropriate. | No keyboard or input-source handling is required unless specifically testing a shortcut or a native text field. |
| Release/performance (SPEC §12.4, §13, §15.5) | Keep data spot checks, offline observation, launch/signing, benchmarks, archive/search integrity and visual acceptance as separate checks. Use fixture/query setup for timing. | Do not require changing an input source during any run. A skipped keyboard case does not satisfy its separate acceptance check. |

The ordinary SwiftUI search binding and index code stay the production path.
Only a launch with the synthetic test flag can supply fixture query text. The
default `SmokeTests` uses no simulated keyboard input. The guardrails reject
XCTest text/key injection, input-source enumeration and source changes in UI
test code. They restrict direct per-process event posting to the fixed-input
driver.

For a deliberately requested native keyboard run, start from the documented
[signed test build](M0-FOUNDATION.md). The separate runner checks only the
selected input source, uses access already granted to the test runner, and sends
only hardware-position events to the foreground synthetic Dashboard PID. It
never selects, enables or restores a source. A mismatch or absent access reports
a skip, without requesting permissions. Keep the same Apple source for the
entire run; do not automate switching sources between cases.

```zsh
# Routine QA: no key events, including the Chinese search and match tests.
xcodebuild -xctestrun "$RUNFILE" -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -only-testing:AgentDashboardUITests/SmokeTests test-without-building

# Independent opt-in run when ABC is already active.
TEST_RUNNER_AGENTDASH_NATIVE_KEYBOARD=abc \
xcodebuild -xctestrun "$RUNFILE" -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO -only-testing:AgentDashboardUITests/FixedKeyboardTests test-without-building

# Independent opt-in run when Apple Pinyin – Simplified is already active.
TEST_RUNNER_AGENTDASH_NATIVE_KEYBOARD=pinyin \
xcodebuild -xctestrun "$RUNFILE" -destination 'platform=macOS,arch=arm64' \
  -parallel-testing-enabled NO \
  -only-testing:AgentDashboardUITests/FixedKeyboardTests/testApplePinyinCommitsChineseIntoRealSearch \
  test-without-building
```

If the test runner cannot send native events under this policy, the keyboard case
can be checked manually with the already selected Apple source on a synthetic
Dashboard. For Chinese search, type and commit **中文** with Apple Pinyin, check
the query field, the result and transcript, and record that outcome separately.
