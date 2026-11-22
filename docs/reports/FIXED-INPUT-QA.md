# Fixed Apple input source QA

Follow the hard input rules in [AGENTS.md](../../AGENTS.md) in every worktree.
Before any UI run, sign the SyntheticQA build and verify it with
`Tools/check-synthetic-launch.sh`. Keep all input testing in that isolated app.
Record three separate results: search behavior with fixtures, actual Chinese
composition using Apple Pinyin – Simplified, and actual ASCII entry and
shortcut dispatch using ABC. Third-party input methods are outside the scope
of development and acceptance.

| QA area | Default unattended check | Actual keyboard acceptance |
|---|---|---|
| Dashboard search (M3, NFR-4/NFR-9) | Prefill the real search field with a synthetic query. Verify CJK and English queries, filter token removal and restoration with saved searches, paging with and without project grouping, match boundaries, restoration after rebuild, and navigation to a folded tool result. | With Apple **Pinyin – Simplified** already selected, type `zhongwen`, commit **中文**, and verify the search field, indexed result and matching transcript. Repeat with a saved filter token in the same field; preserve it while composing and committing Chinese. |
| Menu bar search (M4) | Verify the 360-point panel, search field, click-to-open actions and query routing with synthetic data. If XCTest cannot open the status item, record the menu test as pending or use the documented manual entry. | With the same fixed **Pinyin** source, compose and commit **中文**, then submit the committed query. Verify the main window receives the Chinese query and shows the matching indexed result. |
| Keyboard shortcuts (§11.10) | Use the corresponding controls for navigation, match movement, rescan and session actions, and exercise the same disabled boundaries. | With **ABC** already selected, verify ⌘F focus, ⌘1/2/3, ⌘R, ⌘G/⇧⌘G and both match boundaries, ⇧⌘C, ⌘, and menu bar ⌘D. Verify form Return/Escape and menu bar ⌘Q on the synthetic App where applicable. |
| Editable forms and rules (M2–M5) | Use fixtures and clicks for validation, persistence, cancellation and confirmation. Cover source names and environment labels, mapping/rule rows, Smart Group names, status thresholds, model context sizes, redlines, and exclusion globs. | Use **ABC** to enter, edit and clear ASCII values. If the feature accepts Chinese names or labels, cover their round trip with fixtures; use **Pinyin** when testing actual Chinese typing in a native field. Keep numeric and path cases in a fixed ABC run. |
| Other feature QA (M0–M5) | Use fixtures and clicks for onboarding, watchers, archive and retention, Overview, tool details, Projects, usage and pricing, login item state and storage and privacy controls. Compare the three SPEC window sizes in dark and light. | Only use a keyboard when the case explicitly tests a native field or shortcut above. Apply the same policy to future settings or controls. |
| Release and performance (§12.4, §13, §15.5) | Verify source access and read-only behavior, offline operation, real-data count and cost spot checks, archive/search integrity, performance, signing and visuals separately. Use synthetic inputs for benchmarks and UI. | Release requires separate results for the two native input lanes. A skipped case documents a gap and stays open. |

The ordinary SwiftUI search binding and index code stay the production path.
Only a launch with the synthetic test flag can supply fixture query text. The
default `SmokeTests` uses no simulated keyboard input. The guardrails reject
input-source selection, enumeration, permission requests and unguarded key
events in the app and UI tests. Only the fixed-input test driver may read the
selected source and post a key to the synthetic App.

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

The commands cover only the cases implemented in `FixedKeyboardTests`; use the
matrix for the remaining native cases. Manual typing on the synthetic App with
the already selected Apple input source is also valid. It needs no automation
permission. If the source or automation access cannot be verified, skip key
events without changing the desktop or interrupting the unattended run.
