# M1 watcher primitive — 2026-11-19

Scope: SPEC §3/§4/§7, SEC-1/2/3/5/6/8. Standalone file monitoring for one
authorized directory; no adapter or App wiring is included.

## Public API

`ADIngest/FSEventsWatcher.swift` exports:

```swift
public final class FSEventsWatcher: Sendable {
    public struct FileID: Hashable, Sendable {
        public let relativePath: String
    }
    public enum Signal: Equatable, Sendable {
        case fileChanged(FileID)
        case rescanRequired
    }
    public enum Failure: Error, Equatable, Sendable {
        case invalidRoot, rootUnavailable, streamCreationFailed, streamStartFailed
    }
    public init(authorizedRoot: URL,
                onChange: @escaping @Sendable (Signal) -> Void) throws
    public func cancel()
}
```

The caller supplies an explicit, already-authorized directory and owns one watcher
per root, including the lifetime of any security-scoped access. Construction
starts exactly one stream with a single-element paths array; there is no separate
restart/start API or global root registry. The root must be a local file URL for
an existing directory and must not itself be a symlink. Dot/traversal/NUL paths
and non-local URL hosts are rejected with category-only errors.

The stream uses `FSEventStreamCreate`, `kFSEventStreamEventIdSinceNow`,
`kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot`, a fixed
**0.4 second** latency, `FSEventStreamSetDispatchQueue` on a private serial utility
queue, and `FSEventStreamStart`. Native latency is a batching setting, not a
delivery deadline. Start watching before the initial scan to avoid a scan/watch
gap; initial scan coordination remains the caller's responsibility.

Regular-file events emit one `fileChanged(FileID)` per distinct file in
the native batch. If any event cannot be safely attributed to a file (including
directory or unknown events, loss/coalescing, and root or volume changes), the
batch emits only `rescanRequired`. Empty batches emit nothing.

### Scoped implementation decision

Match a file path against the canonical root at a component boundary, reject
empty, dot and traversal components, and copy only the relative identifier.
Keep `FileID` as the debounce key; it compares and hashes UTF-8 bytes, so two
different spellings that Swift would normalize for equality remain distinct.
Keep identifiers inside ingest and out of logs. They are scheduling hints, so
subsequent reads still use existing authorization and read-only open checks.
The callback discards native absolute paths and event IDs and emits no logs.
No source content is read by this primitive. Debouncing,
scheduling, discovery, parsing, vendor rules, automatic recovery and persistent
event cursors remain coordinator work. This decision is recorded here for
coordinator review per `DEVELOPMENT_PLAN.md`; no format or product decision changes
are proposed.

`cancel()` synchronously gates delivery, clears client callback captures, and
calls `FSEventStreamStop` → `FSEventStreamInvalidate` → `FSEventStreamRelease`.
Cancellation is final and idempotent. It can run inside the callback; external
callers wait for any active callback. The callback must return promptly and must
avoid ownership cycles. Public watcher deinitialization performs the same cleanup.
A retained C context protects callback state during native cleanup. All mutable
state and lifecycle operations are confined to the delivery queue. A stream
that fails to start is invalidated/released without calling Stop.

## Verification

Existing Xcode 27.2 (27B52), SDK 27.2, arm64, Swift 6 / strict concurrency.
The frozen GRDB 7.11.1 repository was copied from the existing public dependency
cache into task-local scratch; no install or dependency/lockfile change was made.
Build products, logs, caches and synthetic test roots stay in task-local scratch.

| Check | Result |
|---|---|
| New `ADIngestTests` target | 10 test functions passed, including 7 loss/root/volume flag argument cases |
| Full package suite | 52 test functions passed across four test targets; no skipped tests |
| Actual synthetic append | Observed notification on a nested Unicode path, within the 5 s bounded wait; appended bytes unchanged |
| Actual synthetic root rename | Observed `rescanRequired` within the 5 s bounded wait |
| Timeout / teardown | Idle wait returns after its 0.15 s timeout; explicit double-cancel completes within 3 s; no callbacks during a subsequent 1.2 s wait after another append |
| Callback lifetime | Reentrant cancellation, external cancellation during an active callback, deinit, callback-capture release and independent-root teardown passed |
| App build | `xcodebuild ... build` succeeded without compiler warnings; app was not launched |
| Signed artifact | Re-signed task-local ad-hoc app with frozen entitlements and runtime flag; exact signed-entitlement/signature/Hardened Runtime guard passed |
| Developer tools | 46 synthetic tests passed, zero skipped |
| API / dependency guards | Passed; exact GRDB 7.11.1 pin and both lockfiles unchanged |
| Diff whitespace | `git diff --check` passed |

The first default execution-sandbox attempt could not invoke SwiftPM's nested
manifest sandbox (`sandbox_apply: Operation not permitted`). SwiftPM's
`--disable-sandbox` allowed compilation inside that execution sandbox, but six
native tests failed with `streamStartFailed`; the three deterministic tests passed.
Re-running the same built watcher tests outside the execution sandbox passed all
nine then-present functions. After adding the active-callback cancellation test,
the complete 52-function package suite was rebuilt and passed outside that
execution sandbox. These are execution-host restrictions, separate from the
application's frozen App Sandbox entitlements.

### Reproduction and evidence

Full package check (run with native FSEvents service access):

```sh
watcher_scratch=$(mktemp -d /private/tmp/agentdash-watcher-verify.XXXXXX)
mkdir "$watcher_scratch/test-roots"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
TMPDIR="$watcher_scratch/test-roots" \
CLANG_MODULE_CACHE_PATH="$watcher_scratch/clang-module-cache" \
swift test --package-path Packages/AgentDashKit \
  --scratch-path "$watcher_scratch/build" \
  --cache-path "$watcher_scratch/cache" \
  --config-path "$watcher_scratch/config" \
  --security-path "$watcher_scratch/security" \
  --manifest-cache local --disable-sandbox --disable-automatic-resolution \
  --disable-netrc --disable-keychain
```

Add `--filter FSEventsWatcherTests` for only the new tests.
`package-tests-final.log`, `focused-native-tests.log`, `tool-tests.log` and
`app-build.log` retain local synthetic evidence in that scratch directory.
The app build used task-local DerivedData/package/cache paths,
`-skipPackageUpdates -disableAutomaticPackageResolution
-onlyUsePackageVersionsFromResolvedFile`, and ad-hoc signing. The subsequent
re-sign and `Tools/check-entitlements.sh` followed the existing M0 report.

## Gaps and boundaries

- Real event loss, event-ID wrap and mount changes were tested through synthetic
  flag batches; no system overload or volume changes were induced.
- The signed sandboxed app has not exercised this watcher. No coordinator or app
  integration, source authorization/bookmark lifecycle, UI behavior or NFR-2
  end-to-end timing is claimed. No real source roots were used as test inputs.
- The coordinator must retain a root-to-watcher association and implement per-file
  scheduling and fallback discovery/rescan/recovery separately.
- No adapter or source format changed; no fixture capture was needed. Shared
  SPEC/FORMATS/DECISIONS files remain coordinator-owned under the development plan.

API semantics were checked against the installed macOS 27.2 SDK's `FSEvents.h`
and Apple's [File System Events Programming Guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).
Apple's [callback documentation](https://developer.apple.com/documentation/coreservices/fseventstreamcallback)
also confirms the callback-owned C string array when `UseCFTypes` is absent.

Review follow-up: 53 package tests passed with native FSEvents service access,
including 11 watcher tests. Two files under one synthetic root delivered their
own relative identifiers; the nested Unicode append also delivered its exact
relative identifier. The default execution sandbox still blocks stream startup.

Second review follow-up: 54 package tests passed, including 12 watcher tests.
A synthetic callback with precomposed and decomposed filenames retained both
debounce keys; the byte-identical repeat was coalesced.
