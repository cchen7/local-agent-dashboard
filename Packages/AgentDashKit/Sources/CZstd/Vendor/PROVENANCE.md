# Zstandard decoder provenance — SEC-4 / ADP-CX

This is the optional source-vendored decoder described in SEC-4. Verification
uses synthetic input. No adapter or ingestion behavior is implemented here.

## Upstream and verification

- Official repository: <https://github.com/meta/zstd> (the former
  `facebook/zstd` URL redirects here).
- Release: [v1.5.7](https://github.com/meta/zstd/releases/tag/v1.5.7).
- Annotated tag object: `ac66b19e6bd6b83238bf008eecc1298105298532`.
- Peeled commit: `f8745da6ff1ad1e7bab384bd1f9d742439278e99`.
- Tag date: 2025-02-19. Source verified on 2026-11-19 using official remote
  refs, the GitHub tag API, and local `git verify-tag --raw v1.5.7`.
- `verify-tag` exited 0 with `GOODSIG` and `VALIDSIG` for Zstandard Release
  Signing Key fingerprint `4EF4AC63455FC9F4545D9B7DEF8FE99528B52FFD`.
  The public key came from <https://github.com/felixhandte.gpg> and was imported
  only into a disposable task-local keyring. Its trust was `TRUST_UNDEFINED`:
  this verifies the mathematical signature, not an independently established
  identity chain. GitHub's tag API reported `verified: false, reason: bad_email`;
  it is not being represented as a GitHub-verified tag.
- Version-specific API and generation instructions were checked against this
  commit's [`lib/zstd.h`](https://github.com/meta/zstd/blob/f8745da6ff1ad1e7bab384bd1f9d742439278e99/lib/zstd.h)
  and [`build/single_file_libs/README.md`](https://github.com/meta/zstd/blob/f8745da6ff1ad1e7bab384bd1f9d742439278e99/build/single_file_libs/README.md).
  Context7 provided supplemental streaming API documentation; its `dev` docs
  were not used as evidence of the pinned version.

## Vendored scope and license

`zstddeclib.c` is the **unmodified decoder-only amalgamation** produced by
upstream `combine.py` and `zstddeclib-in.c`. No encoder implementation, CLI,
assembly, legacy decoder, build script, or upstream Swift package is vendored.
The amalgamation includes common entropy/xxHash support and upstream API
declarations; encoder declarations do not add encoder implementations.
Its built-in settings disable assembly, legacy support, tracing and debug logging.

Upstream offers BSD or GPLv2; this project selects the **BSD license**, reproduced
verbatim in adjacent `LICENSE`. All upstream copyright and license notices,
including the xxHash notice for Yann Collet / Meta Platforms, remain in the
amalgamation. Binary distribution must reproduce this BSD notice/disclaimer and
the retained attribution in accompanying materials. App distribution packaging
is outside this primitive-only change.

SHA-256 values:

| Artifact | SHA-256 |
|---|---|
| Commit archive (`codeload` URL below) | `4b0bd1f0cfb25e61b9103c35f27395530ff5b4c0d2513a00fd745849e85ea52c` |
| Generated `zstddeclib.c` | `5eb38abe0a7eea13674b312a006df72002d4192f0f0b4d09e6f03fb927a1f3d0` |
| Upstream `LICENSE` | `7055266497633c9025b777c78eb7235af13922117480ed5c674677adc381c9d8` |
| Upstream `combine.py` | `4fd5e30ab95f558cb46159abe81a620878b53c0aeba7ebd20f0c23d12ae8bff5` |
| Upstream `zstddeclib-in.c` | `bc92e749753feac9beaeae6e5fd8efe80f8ba31f937a71179ffa2876c903d6b6` |

## Reproduce from upstream

These are developer-machine commands, never App runtime behavior. They use only
task-local files and existing Git, curl, GPG and Python 3 (3.8+) tools; no install
or global configuration is needed. Compare the resulting bytes/hashes before
replacing any vendor file. A changed GitHub archive hash must be investigated;
the tag object, commit and generated-source hashes must still match exactly.

```sh
zstd_task=$(mktemp -d /private/tmp/agentdash-zstd-provenance.XXXXXX)
git ls-remote --tags https://github.com/meta/zstd.git \
  refs/tags/v1.5.7 'refs/tags/v1.5.7^{}'
git init --quiet "$zstd_task/tag"
git -C "$zstd_task/tag" -c gc.auto=0 fetch --depth=1 --no-tags \
  https://github.com/meta/zstd.git refs/tags/v1.5.7:refs/tags/v1.5.7
mkdir -m 700 "$zstd_task/gnupg"
curl -q -fL https://github.com/felixhandte.gpg -o "$zstd_task/signer.gpg"
GNUPGHOME="$zstd_task/gnupg" gpg --batch --import "$zstd_task/signer.gpg"
GNUPGHOME="$zstd_task/gnupg" git -C "$zstd_task/tag" verify-tag --raw v1.5.7
curl -q -fL \
  https://codeload.github.com/meta/zstd/tar.gz/f8745da6ff1ad1e7bab384bd1f9d742439278e99 \
  -o "$zstd_task/upstream.tar.gz"
shasum -a 256 "$zstd_task/upstream.tar.gz"
tar -xzf "$zstd_task/upstream.tar.gz" -C "$zstd_task"
zstd_source="$zstd_task/zstd-f8745da6ff1ad1e7bab384bd1f9d742439278e99"
cd "$zstd_source/build/single_file_libs"
PYTHONDONTWRITEBYTECODE=1 python3 combine.py -r ../../lib \
  -x legacy/zstd_legacy.h -o "$zstd_task/zstddeclib.c" zstddeclib-in.c
shasum -a 256 "$zstd_task/zstddeclib.c" "$zstd_source/LICENSE" \
  combine.py zstddeclib-in.c
```

## Local integration policy

`CZstd` is a local SwiftPM C source target. `CZstd.c` includes the amalgamation
once; `Vendor` is excluded from automatic source discovery. Only the small
project-owned bridge header is exposed to Swift. `ADZstd` provides
`ZstdStreamDecoder.write(_:emit:)` and explicit `finish()`. No existing adapter
depends on it yet. External dependency declarations and both GRDB lockfiles
remain unchanged (exact 7.11.1, commit
`b83108d10f42680d78f23fe4d4d80fc88dab3212`).

- Default and absolute maximum window/history: **8 MiB**; callers may lower it
  to any exact byte size >= 1024. Native `ZSTD_DCtx_setMaxWindowSize` is set once
  and preserved across frames. No external dictionary is loaded or accepted
  (maximum external dictionary size **0 bytes**); nonzero dictionary IDs fail.
- Each frame header is checked with `ZSTD_getFrameHeader` in a fixed **18-byte**
  buffer before its payload is submitted. This also enforces window policy on
  small known-size frames, whose upstream single-pass shortcut can bypass the
  allocation/window check. Header-only submission avoids that shortcut as well.
- Default output chunk **64 KiB**; configurable range **1...128 KiB**. Native
  calls and Swift callbacks both obey that bound. The synchronous callback gives
  back pressure; no async queue or whole-file compressed/decompressed buffer is
  created. The caller chooses and owns input chunks and may retain emitted
  chunks. The native context retains only bounded window/block/header state;
  the window cap is not a total-process allocation limit.
- Concatenated standard, empty and skippable frames are accepted;
  `completedFrameCount` exposes every completed frame, including skippable ones.
  No trailing bytes are silently ignored. A non-boundary EOF, including empty
  input or a partial second frame, fails at `finish()`.
- Malformed headers/blocks and checksum mismatches fail. Checksums are verified
  when present; a bit change that remains a valid checksum-less stream cannot
  in general be detected. Output is provisional until successful `finish()`;
  consumers must handle already-emitted bytes on failure.
- Native/consumer failure and successful EOF close the decoder. Reentrant calls
  are rejected; the class is serial-use and deliberately not `Sendable`.
- No file access, logging, subprocess, network API or global installation is
  part of this decoder. The App's entitlements and code are unchanged.

## Synthetic fixtures

All fixtures are synthetic bytes in `Tests/ADZstdTests`. Raw/RLE/skippable frames
are constructed directly from the standard frame format, including unknown-size
and 18-byte headers. No real session was captured or used.

The 155-byte checksummed compressed fixture was generated using this commit's
encoder **only in task-local scratch**, not vendored or linked into the product:

```sh
make -C "$zstd_source/lib" libzstd.a ZSTD_LEGACY_SUPPORT=0 ZSTD_MULTITHREAD=0
# Compile a temporary C fixture generator against lib/zstd.h and lib/libzstd.a.
```

Exact generator recipe: take the four ASCII strings (including final newlines)
from `SyntheticZstdFixtures.lines`; for `i = 0..<128`, append `lines[(i * 7) % 4]`.
This yields 5984 bytes. Create a fresh `ZSTD_CCtx`; set
`ZSTD_c_compressionLevel = 3` and `ZSTD_c_checksumFlag = 1`, leaving other defaults
unchanged; call `ZSTD_compress2` once. `ZSTD_versionNumber()` was 10507.
The resulting 155 bytes are preserved literally in `checkedFrame`; tests compare
the full decoded bytes to the separately constructed text.

## Local verification (2026-11-19)

Build products, fetched sources, verification keyrings and logs stay in a
task-local scratch directory. Tests use synthetic data. Verification used
Xcode 27.2 / Apple Swift 6.4.2 / arm64.

From the assigned worktree root, the complete package-test command was:

```sh
zstd_verify=$(mktemp -d /private/tmp/agentdash-zstd-verify.XXXXXX)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/AgentDashKit \
  --scratch-path "$zstd_verify/swift-build" \
  --cache-path "$zstd_verify/swift-cache" \
  --config-path "$zstd_verify/swift-config" \
  --security-path "$zstd_verify/swift-security" \
  --manifest-cache local --disable-sandbox --force-resolved-versions
```

- Exit **0**: **29 test functions** passed, zero failures or skips: ADZstd **16**,
  ADStore **10**, ADCore **3**. The four parameterized zstd functions cover 31
  combinations, in addition to internal loops over all split points and prefixes.
  No compiler warnings. Log: `package-tests.log` in scratch.
- AddressSanitizer: the same command with scratch path `asan-build` and appended
  `--sanitize address --filter ADZstdTests` exited **0**: all **16** zstd functions
  passed, no sanitizer diagnostics. The native `CZstd.o` has ASan load/store
  instrumentation, confirmed by its undefined symbols. Log: `asan-tests.log`.
- `Tools/forbid-apis.sh`: exit **0**, **22** production source files inspected.
- `Tools/check-dependencies.sh`: exit **0**, GRDB exact **7.11.1**, lockfiles
  consistent. Both tracked lockfiles are unchanged from the assigned baseline.
- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/tests -v`:
  exit **0**, **40** tests passed, zero skipped. Log: `tool-tests.log`.
- `clang -std=c99 -Wall -Wextra -Werror -fsyntax-only -I
  Packages/AgentDashKit/Sources/CZstd/include
  Packages/AgentDashKit/Sources/CZstd/CZstd.c`: exit **0** (one command).
- A second independent invocation of upstream `combine.py` reproduced the
  vendored C bytes exactly (`cmp` exit **0**). `LICENSE` also matches upstream
  byte-for-byte; the hashes above were rechecked. The checked fixture bytes also
  match a fresh run of the scratch v1.5.7 encoder exactly.
- `nm -gU CZstd.o`: zero defined symbols starting `ZSTD_compress`,
  `ZSTD_createCCtx`, `ZSTD_CCtx` or `ZDICT_` (accounting for Mach-O's `_` prefix).
- `git diff --check`: exit **0**.

The macOS arm64 App also built successfully with the full Xcode toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project AgentDashboard.xcodeproj -scheme AgentDashboard \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$zstd_verify/xcode-build" \
  -clonedSourcePackagesDirPath "$zstd_verify/xcode-packages" \
  -disableAutomaticPackageResolution CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- build
```

The first attempts failed at manifest evaluation under a nested development
sandbox. A build with normal developer-tool access succeeded. The local App was
re-signed using the existing entitlement file and Hardened Runtime and passed
`Tools/check-entitlements.sh`. No App was launched during this check; runtime
ingestion is outside this decoder-only change.
