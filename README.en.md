# Agent Dashboard

[简体中文](README.md) · [Download for macOS](https://github.com/cchen7/local-agent-dashboard/releases/latest)

Search your local Claude Code, Codex (CLI and desktop), and GitHub Copilot CLI sessions in one Mac app. Open a search hit at the original message, follow the recent work in a project, or compare token usage across agents.

## Install and index a source

Requires **macOS 27 or later on Apple silicon**. The interface is available in English and Simplified Chinese.

1. Download `AgentDashboard-0.1.0-macOS-arm64.dmg` from the [0.1.0 release](https://github.com/cchen7/local-agent-dashboard/releases/tag/v0.1.0). Open it, drag **AgentDashboard** to **Applications**, and launch the installed copy. The release is Developer ID signed and notarized by Apple.
2. Select the local sources you want to include and choose **Start Indexing**. For a nonstandard location, use **Settings → Sources → Add Source**, choose the agent's root folder, and start indexing when ready. Adding a source does not scan it.
3. Press `⌘F` in Sessions. For example, `agent:codex in:7d "migration"` finds mentions in the last seven days of Codex history. Open a result to read the surrounding messages. Use `⌘G` and `⇧⌘G` to step through hits, or save a frequent query as a Smart Group.

Projects groups sessions by workspace and shows recent activity. Token Usage includes cache reads and writes, and estimates costs using public API rates; it does not report a subscription bill. Usage without a known price is still counted. Search and usage are also available from the menu bar.

## What stays on the Mac

The app does not make network requests or call a model. It reads authorized sources without modifying them and stores its search index in its own sandbox. Display masking hides common credential patterns on screen; it does not redact stored or original text. Index redaction and workspace exclusion rules are available in privacy settings.

Cloud sessions, Grok Build, and transcript export are outside the [0.1.0 scope](docs/RELEASE-SCOPE.md). Claude Code local records are supported; an independent historical usage comparison is pending a matching time window with cache counters.

## Build

Use Xcode 27 and the corresponding macOS SDK on Apple silicon. Dependency lockfiles are checked in. Resolving build dependencies for the first time may require internet access.

```sh
xcodebuild -project AgentDashboard.xcodeproj -scheme AgentDashboard \
  -configuration Release -destination 'platform=macOS,arch=arm64' build
swift test --package-path Packages/AgentDashKit
```

[Development and tests](AGENTS.md) · [Specification](docs/SPEC.md) · [Session formats](docs/FORMATS.md) · [MIT license](LICENSE) · [Third-party notices](App/Resources/THIRD-PARTY-NOTICES.txt)
