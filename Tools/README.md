# M0 developer tools

Requirement anchors: SEC-1…8, ADP-1…7, SPEC §12.1, §14.4, §15.2.
These are local developer commands, never app code. They use an existing Python
3.10+ and its standard library; nothing is installed or resolved. Shell entrypoints
disable bytecode caches. Run from any directory; the default repository is the
worktree containing these scripts.

## Synthetic performance corpus

Requirement anchors: SPEC §15.3, NFR-3 and NFR-8.

```sh
corpus=$(Tools/synthgen)
cat "$corpus/manifest.json"
Tools/synthgen --profile benchmark --plan
Tools/synthgen --profile benchmark
```

The default smoke profile writes 8 sessions, 288 JSONL records and
1,000,000 raw bytes. The explicit benchmark profile writes 2,000 sessions,
1,000,000 JSONL records and exactly 5,000,000,000 raw bytes. Counts include
session/usage records, not just displayed messages. Raw bytes include the
Grok sidecars and exclude the manifest. Use `--plan` to check the full
configuration without writing anything. Generation checks free space first.
The separate `benchmark-native` profile has the same total sessions,
records, and bytes, all in Claude Code, Codex, and Copilot CLI logs,
so the importer can process all 5 GB while Grok is deferred.

The command prints the path of a fresh, owner-only temporary directory.
There is no input log or user-specified output path. When the App-owned index
exists, only its registered source roots are read, in read-only mode, to
refuse a temporary destination that overlaps one. The check compares directory
identities, including macOS Data volume aliases, and stops before creating
anything if it cannot verify a boundary. The tool never opens agent files or
registers the output in Settings. The manifest is emitted
only after the corpus is complete; do not use partial output or commit large
corpora.

The same profile and seed (default 27) produce identical relative paths,
contents, and manifest in different temporary directories. The manifest
gives per-agent session, record, byte and expected token-component totals.
Reasoning tokens are already part of output. Long bytes are allocated to
synthetic tool output so import tests exercise truncation. Claude usage
includes repeated response IDs, Codex includes both per-call and cumulative
counts, and Copilot uses per-call records. The Grok workload is a
spec-shaped sample with [ACP v1 plan and tool
updates](https://agentclientprotocol.com/protocol/v2/migration), not a
fixture captured from a real Grok installation or proof of its adapter.

Generating the corpus is not an ingestion benchmark. Measure elapsed import
time and database bytes separately, and report which sources the App
actually imported.

To measure the production importer and the SQLite footprint in an optimized
test process:

```sh
corpus=$(Tools/synthgen --profile benchmark)
AGENTDASH_FULL_INDEX_CORPUS="${corpus##*/}" \
  swift test --package-path Packages/AgentDashKit -c release \
  --filter firstIndexFromSyntheticCorpus
```

The test accepts the generator's temporary directory identifier, uses a new
index and the bundled price table, and checks persisted checkpoints, sessions
and token components against the manifest. Sources run concurrently as in
onboarding, sharing one index. It reports import time separately from the
final WAL checkpoint, with sizes for the live and checkpointed SQLite files.
Use the smoke profile or set `AGENTDASH_FULL_INDEX_SERIAL=1` for diagnostics
without performance assertions. Grok bytes stay outside the measured throughput
and storage denominator until there is a native importer. The result is a
package benchmark with the same import and persistence code as the app;
UI work and live watcher startup are not measured.
Use `--profile benchmark-native` in the generation command to verify the
full 5 GB duration on the three native importers. Keep the four-format
profile and its unsupported coverage separate in reports.

## Guardrails

```sh
Tools/forbid-apis.sh
Tools/check-dependencies.sh
Tools/check-entitlements.sh /absolute/path/to/AgentDashboard.app
```

`forbid-apis.sh` inspects Swift/C/ObjC/C++ source under `App/` and
`Packages/*/Sources/`. Tests, Tools, docs and other top-level directories are not
production sources. `.worktrees`, `.git`, `.build`, `.swiftpm`, `DerivedData`,
`build`, `node_modules` and Python caches are excluded. It scans vendored source
inside production source roots; vendoring is not an API exemption. Source symlinks
are rejected, so a link cannot silently pull in another worktree or skip code.

For C/ObjC/C++ files, the scanner first deletes backslash-newline continuations
without inserting whitespace, then recognizes line and non-nesting block comments.
Swift comments support nesting. Original physical line numbers survive C splicing.
The scanner retains string literals and checks forbidden network, process, Apple
Events, AI, Spotlight and CloudKit symbols. Swift function-declaration names such
as `func accept(token: String, ...)` are not treated as POSIX calls. Only the name
is exempted for call-shaped rules; parameters/defaults and the body are still
scanned, including subsequent calls with the same name and backtick-escaped calls.
Strings cannot create declaration exemptions. This does not resolve a call's
module/type: a custom method call named `accept(...)` remains conservative review
work. A production file/directory called
`Fixtures` is still scanned. There is no inline suppression. An ordinary comment
about a forbidden API is allowed; code on the same line is still checked. String
literals are checked because they may name runtime APIs. Diagnostics give location
and rule, never source excerpts. This is a conservative lexical guard, not a
compiler, complete data-flow analysis or proof of zero network. Computed runtime
names, aliases, build configuration and SEC-3/8 privacy still require code review;
signed sandbox/runtime and release observation are separate checks.

`check-dependencies.sh` requires
`Packages/AgentDashKit/{Package.swift,Package.resolved}`. The manifest must be a
single `import PackageDescription` followed by `let package = Package(...)`, with
a literal dependencies array containing only:

```swift
.package(url: "https://github.com/groue/GRDB.swift.git", exact: "<major.minor.patch>")
```

The official URL without `.git` is also allowed. Whitespace, comments and trailing
commas are supported. Computed/conditional declarations, other imports, extra
top-level declarations, additional manifests, registry/local packages, branches,
ranges and revision-only pins fail for review. The checker tokenizes string
literals and balances the initializer; a commented or quoted declaration cannot
stand in for a real dependency. It never executes a Swift manifest or resolves a
package. Lockfile formats 2/3 must contain exactly the official `grdb.swift` remote
pin, matching the exact manifest version and a 40-character lowercase Git revision.
Every other lockfile under the repository (excluding Tools/docs/caches above) must
agree on that version and revision. It checks consistency, not remote tag-to-commit
authenticity. Foundation must select and resolve the real pin. The synthetic
version `7.8.0` in tests is not a project version decision.

Source-vendored BSD zstd is conditional on the observation recorded in FORMATS;
it is not permission for another Swift package, runtime or decoder implementation
here. Vendored license/scope review remains manual.

`check-entitlements.sh` requires an existing `.app` and `/usr/bin/codesign`.
It runs signature verification with `--verify --strict`, reads the signed plist
with `--display --entitlements - --xml`, then reads the actual signature flags.
It requires exactly the four keys in SPEC §12.1: three boolean `true` sandbox /
user-selected read-write / app-scope values, plus exactly the five read-only home
paths, without duplicates or broader aliases. It rejects every extra key,
including network permissions, and requires the Hardened Runtime flag. Missing
or invalid XML, unsigned/invalid signatures and failed inspection never pass.
It does not establish sandbox directory access, identity/notarization or runtime
network behavior. Ad hoc signatures are accepted for development checks.

API/dependency commands accept `--root /explicit/repository` for synthetic tests
or an explicitly authorized integration review.
There is no entitlement-plist-only mode that can masquerade as an artifact check.

## Fixture capture

Use one explicit stable UTF-8 JSON/JSONL or `.jsonl.zst` file per invocation and a
newly named output in an existing, separate directory:

```sh
Tools/fixture-capture \
  --input /private/tmp/synthetic-source/events.jsonl \
  --source-root /private/tmp/synthetic-source \
  --output /private/tmp/synthetic-fixtures/events.jsonl
```

Use the full agent/source root for `--source-root`, especially custom sources.
For Copilot's `workspace.yaml`, choose a new `.yaml` output instead.
This narrow mode records only the shapes of the `name` and `summary`
scalars. It replaces their values with fixed synthetic text and drops
all other fields; it is not a general YAML sanitizer.
If omitted, the input parent is the boundary. The input parent and any protected
input ancestor are always additional boundaries. Independently of the input's
location, output and marker ancestry must never contain a directory named
`.claude`, `.codex`, `.copilot` or `.grok` (case-insensitive). The check covers
spelled paths, canonical paths and intermediate symlink targets, including an
ordinary alias to a different protected root and a protected-name symlink pointing
outward to an ordinary directory. Canonicalized destinations must also be outside
all declared source boundaries. Existing
output or marker paths, symlink entries (even dangling), same-file aliases and
hardlinks are refused. Nothing is overwritten; source directories are never
created or changed. The tool does not discover sources, recurse directories,
copy SQLite, interpret YAML or capture arbitrary text files.

For `.jsonl.zst` input, give `--output` a `.jsonl` extension. Compressed capture
uses the local [Python 3.14+ `compression.zstd` module](https://docs.python.org/3.14/library/compression.zstd.html).
The decoder reads concatenated frames in memory from the bounded input buffer;
its window, compressed input and decoded output each have a 64 MiB limit. No raw
JSONL file is written. Invalid or truncated zstd data fails before publication.
Plain JSON/JSONL still works without the optional module. This is a developer
tool, separate from the native App decoder.

JSONL must have complete newline-terminated object records. Blank lines are
discarded. JSON may contain an object or array. Invalid UTF-8/JSON, duplicate keys,
non-finite numbers, partial records and inputs larger than 64 MiB fail closed.
Malformed parser cases must be synthetic fixtures, not raw failed captures.

Sanitization policy (`fixture_capture.py` is the authoritative allow-list):

- Objects/arrays, missing fields, ordinary numbers, booleans and null retain their
  shape and values. Token/accounting numbers are unchanged. Metadata fields whose
  normalized name ends in key/token/secret/password/credential(s)/authorization
  redact their entire subtree: strings become placeholders, numbers become zero,
  booleans become false and null stays null. This prevents numeric passwords from
  passing the general number rule. Other numeric metadata is retained and needs
  review for sensitivity.
- Only reviewed `SCHEMA_KEYS` retain their names. Unknown/dynamic keys are replaced
  with distinct deterministic strings, including private names used as map keys.
  Their values still traverse the entire policy. Add genuinely new schema keys to
  the reviewed list before relying on them for adapter fixtures.
- Every string is replaced unless it is an exact enum value in the matching
  field's `ENUMS` list. A known enum in message text is still replaced. Models,
  providers, originators, versions, branches, URLs and arbitrary new metadata
  strings have no bypass. Argument JSON strings, commands and patches are opaque
  text; their internal syntax is not promised to remain executable/parseable.
  Use synthetic specialized tool/patch fixtures where that syntax matters.
- Text becomes `x` per Unicode **code point**, retaining only space/tab/CR/LF.
  This preserves Python `len`, not UTF-8 bytes, grapheme count, Swift `String.count`
  or visual width. Combining marks, emoji sequences, CJK and U+2028/U+2029 are
  covered. JSON escaping/formatting can change byte lengths and offsets; never use
  these fixtures as original-file byte checkpoints.
- Reviewed ID/reference string fields map to deterministic, distinct placeholders
  of the same code-point length. UUID strings retain UUID layout. The same raw
  string gets the same ID across all reviewed ID fields in this invocation.
  Allocation depends on encounter order, with no raw-value hash or mapping saved;
  it is stable for the same ordered input, not a cross-capture identity contract.
  Excessive distinct very short IDs/keys fail rather than merge relationships.
- Path fields map to distinct `/Users/dev/…` placeholders of the same length when
  possible; short/relative paths expand to at least `/Users/dev/0` length. No
  private directory basename is retained. Valid ISO timestamp strings shift to a
  synthetic UTC origin (`2000-01-01` for the first), preserving relative intervals
  at microsecond precision, fractional field width and timezone suffix width.
  Unrecognized time strings are ordinary masked text. Numeric timestamps remain
  numbers under the general numeric rule.

The tool reads with `O_RDONLY`, checks inode/device/size/mtime/ctime around the
read and before staging, and never opens a source for writing, locks, deletes or
explicitly changes timestamps. Filesystems may maintain access time for ordinary
reads. Output operations use a pinned directory descriptor with no symlink
components, mode-0600 staging files and exclusive hard-link publication. Concurrent
new output files are preserved. This is not a defense against a privileged process
moving already-open directory trees during execution.

After re-parsing and validating the transformed output and checking secret
patterns, the tool publishes `<output>.sanitized` with a SHA-256 of **sanitized**
bytes, record count, policy version and `review_required: true`. No raw-source
digest, path, ID map or content appears in the marker or diagnostics. Expected
failures remove this invocation's stages and any just-published output if marker
publication fails. A crash/power loss between the two publications can leave an
unmarked output; it cannot mark an unvalidated output. Do not treat a marker as
human approval or as proof no metadata could identify someone. Review content,
unknown key additions, numeric metadata and timestamps before committing a fixture.

## Exit codes and verification

| Command | 0 | 1 | 2 |
|---|---|---|---|
| `forbid-apis.sh` | Sources inspected, no match | Forbidden API / uninspectable syntax | Missing sources / unreadable tree or prerequisite / usage |
| `check-dependencies.sh` | Exact approved pin and consistent locks | Unapproved/inconsistent/malformed declarations or lock | Missing package/lock, symlink/read prerequisite or usage |
| `check-entitlements.sh` | Actual signature, entitlements and runtime flags pass | Invalid/unsigned artifact or policy/inspection failure | Missing `.app`, codesign or usage |
| `fixture-capture` | New validated fixture and marker | Invalid/unsafe input/output, validation or publication failure | Missing Python, zstd module for compressed input, or usage |

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tools/tests -v
```

Tests create only synthetic inputs and scratch apps under task-specific
`/private/tmp/agentdash-m0-*` directories and clean them afterward. The signed
artifact test uses existing `/usr/bin/clang` and ad hoc `codesign --sign -` with
Hardened Runtime, needs no keychain identity, and never launches the synthetic app.
It reports a skip when macOS/clang/codesign is absent; such a skip is not artifact
verification. No package resolution, global installation or global caches are used.

M0 review verification: **40 tests passed, zero skipped**, including all four
independent protected roots and symlink aliases, Swift declaration/call separation,
`sys` + backslash-newline + `tem`, and C comment/splicing order. The following
read-only integration checks also passed against the coordinator-authorized
Foundation worktree:

```sh
Tools/forbid-apis.sh --root ../m0-foundation
# Exit 0: 18 production source files inspected.
Tools/check-dependencies.sh --root ../m0-foundation
# Exit 0: GRDB.swift exact 7.11.1, lockfiles consistent.
```

The narrow literal manifest policy is unchanged. These observations do not verify
the signed Agent Dashboard app, sandbox source access or runtime network behavior;
rerun checks against the final combined head before merge.
