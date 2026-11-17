"""Fail-closed M0 guardrails. Developer tools only; not linked into the app."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

REPO = Path(__file__).resolve().parents[1]
CODESIGN = "/usr/bin/codesign"
CACHE_DIRS = {".git", ".worktrees", ".build", ".swiftpm", "DerivedData", "build", "__pycache__", "node_modules"}
SOURCE_SUFFIXES = {".swift", ".m", ".mm", ".c", ".h", ".cc", ".cpp", ".cxx", ".hpp"}
GRDB_URLS = {"https://github.com/groue/GRDB.swift", "https://github.com/groue/GRDB.swift.git"}
PATH_KEY = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
SOURCE_PATHS = ["/.claude/", "/.codex/", "/.copilot/", "/.grok/", "/.config/agent-dashboard/"]
STRING_OPEN = re.compile(r'(#+)?("""|"|\')')
SWIFT_FUNCTION = re.compile(r"\bfunc\s+`?(?P<name>[A-Za-z_]\w*)`?\s*(?=[(<])")


class Violation(Exception):
    """The inspected input violates a guardrail (exit 1)."""


class PrerequisiteError(Exception):
    """The required input/tool is unavailable, so no passing claim is possible (exit 2)."""


def required_entitlements():
    return {"com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-write": True,
            "com.apple.security.files.bookmarks.app-scope": True,
            PATH_KEY: list(SOURCE_PATHS)}


def validate_entitlements(value):
    expected = required_entitlements()
    if not isinstance(value, dict) or set(value) != set(expected):
        raise Violation("signed entitlements must contain exactly the four keys in SPEC 12.1; missing/extra key")
    for key in expected.keys() - {PATH_KEY}:
        if value[key] is not True:
            raise Violation("required sandbox, user-selected read-write and app-scope values must be boolean true")
    paths = value[PATH_KEY]
    if not isinstance(paths, list) or any(not isinstance(p, str) for p in paths):
        raise Violation("home-relative read-only paths must be an array of strings")
    if len(paths) != len(SOURCE_PATHS) or set(paths) != set(SOURCE_PATHS):
        raise Violation("home-relative read-only paths must match exactly the five paths in SPEC 12.1")


def signed_output(arguments):
    try:
        result = subprocess.run([CODESIGN, *arguments], capture_output=True, timeout=30, check=False)
    except FileNotFoundError:
        raise PrerequisiteError("codesign is unavailable") from None
    except (OSError, subprocess.TimeoutExpired):
        raise Violation("codesign inspection could not complete") from None
    if result.returncode:
        raise Violation("codesign failed: artifact is unsigned, invalid, or could not be inspected")
    return result


def check_artifact(app):
    app = Path(app)
    if not app.is_dir() or app.suffix != ".app":
        raise PrerequisiteError("a built, signed .app directory is required")
    if not os.path.isfile(CODESIGN) or not os.access(CODESIGN, os.X_OK):
        raise PrerequisiteError("prerequisite missing: /usr/bin/codesign")
    signed_output(["--verify", "--strict", str(app)])
    entitlements = signed_output(["--display", "--entitlements", "-", "--xml", str(app)])
    try:
        value = plistlib.loads(entitlements.stdout)
    except (ValueError, plistlib.InvalidFileException, TypeError, OverflowError):
        raise Violation("codesign did not return a valid entitlement plist; inspection was not skipped") from None
    validate_entitlements(value)
    metadata = signed_output(["--display", "--verbose=4", str(app)])
    flags = metadata.stderr.decode("utf-8", errors="replace")
    # Inspect the actual code-signature flags, not a plist/build setting.
    match = re.search(r"\bflags=0x([0-9a-fA-F]+)\b", flags)
    if not match or not int(match[1], 16) & 0x10000:
        raise Violation("signed artifact does not have the Hardened Runtime flag")


def strip_comments(source, *, nested=True, mask_strings=False):
    """Remove comments without changing offsets; Swift block comments can nest.

    Swift raw/multiline and ordinary C/ObjC strings are retained for dynamic API
    references. The declaration classifier alone requests masked strings so text
    cannot create an exemption. There is no source-level suppression syntax.
    """
    result = list(source)
    index = 0
    size = len(source)
    while index < size:
        if source.startswith("//", index):
            end = source.find("\n", index)
            end = size if end < 0 else end
            result[index:end] = " " * (end - index)
            index = end
        elif source.startswith("/*", index):
            start = index
            depth = 1
            index += 2
            while index < size and depth:
                if nested and source.startswith("/*", index):
                    depth += 1
                    index += 2
                elif source.startswith("*/", index):
                    depth -= 1
                    index += 2
                else:
                    index += 1
            if depth:
                raise Violation("unterminated block comment; source cannot be inspected reliably")
            result[start:index] = ["\n" if c == "\n" else " " for c in source[start:index]]
        else:
            # Raw Swift opening delimiters are zero or more # followed by quotes.
            match = STRING_OPEN.match(source, index)
            if not match:
                index += 1
                continue
            hashes = match[1] or ""
            quote = match[2]
            closing = quote + hashes
            start = index
            index += len(match[0])
            while index < size:
                if source.startswith("\\" + hashes, index):
                    index += len(hashes) + 2
                elif source.startswith(closing, index):
                    index += len(closing)
                    break
                else:
                    index += 1
            if mask_strings:
                result[start:index] = ["\n" if c == "\n" else " " for c in source[start:index]]
    return "".join(result)


FORBIDDEN = [
    ("SEC-2 network", re.compile(r"\b(?:NS)?URLSession\w*\b|\bNSURLConnection\b|\bNW(?:Connection|Listener|Browser|PathMonitor|Endpoint|Parameters)\w*\b|\bCFSocket\w*\b|\bCF(?:Read|Write)?Stream\w*\b|\b(?:WKWebView|SFSafariViewController)\b")),
    ("SEC-2 network import", re.compile(r"\bimport\s+(?:(?:class|struct|enum|func|var|let|typealias)\s+)?(?:Network|NetworkExtension|CFNetwork|WebKit|SafariServices)\b|@import\s+(?:Network|CFNetwork|WebKit)\b|#\s*(?:include|import)\s*[<\"](?:sys/socket|netdb|arpa/inet|netinet/in)\.h")),
    ("SEC-2 socket", re.compile(r"\b(?P<call>socket|socketpair|connect|bind|listen|accept|accept4|getaddrinfo|gethostbyname)`?\s*\(")),
    ("SEC-5 process", re.compile(r"\b(?:Process|NSTask|NSUserUnixTask|NSUserScriptTask)\b|\b(?P<call>posix_spawn\w*|fork|vfork|popen|system|execl\w*|execv\w*)`?\s*\(")),
    ("SEC-5 Apple Events", re.compile(r"\b(?:NSAppleScript|NSAppleEvent\w*|NSUserAppleScriptTask|AppleScript|ScriptingBridge|SBApplication|AEDesc|AECreate\w*|AESend\w*|AEDeterminePermissionToAutomateTarget|OSAExecute\w*|OSAScript)\b")),
    ("SEC-6 AI", re.compile(r"\b(?:FoundationModels|LanguageModelSession|SystemLanguageModel|NLEmbedding|NLContextualEmbedding\w*|NLModel\w*|NLClassifier\w*|CoreML|CreateML|MLModel\w*)\b")),
    ("SEC-7 shared index/cloud", re.compile(r"\b(?:CoreSpotlight|CSSearchableIndex|CloudKit|NSUbiquitousKeyValueStore)\b")),
]


def production_files(root):
    root = Path(root).resolve()
    app = root / "App"
    packages = root / "Packages"
    candidates = [app] if app.exists() or app.is_symlink() else []
    if packages.is_symlink():
        raise PrerequisiteError("production package directory must not be a symlink")
    if packages.is_dir():
        try:
            for package in sorted(packages.iterdir()):
                if package.name in CACHE_DIRS:
                    continue
                if package.is_symlink():
                    raise PrerequisiteError("production package directories must not be symlinks")
                source = package / "Sources"
                if source.exists() or source.is_symlink():
                    candidates.append(source)
        except OSError:
            raise PrerequisiteError("production package directories could not be enumerated") from None
    for candidate in candidates:
        if candidate.is_symlink() or candidate.parent.is_symlink():
            raise PrerequisiteError("production source directories must not be symlinks")
        for directory, subdirs, names in os.walk(candidate, followlinks=False, onerror=walk_error):
            for name in subdirs + names:
                if name not in CACHE_DIRS and (Path(directory) / name).is_symlink():
                    raise PrerequisiteError("production source symlinks require explicit review")
            subdirs[:] = sorted(d for d in subdirs if d not in CACHE_DIRS)
            for name in sorted(names):
                path = Path(directory) / name
                if path.suffix.lower() in SOURCE_SUFFIXES:
                    yield path


def walk_error(_):
    raise PrerequisiteError("repository tree could not be enumerated completely")


def prepare_source(source, *, is_swift):
    """C splicing precedes comment recognition and inserts no whitespace.

    Keep the original physical line for each resulting character, including when
    a splice joins identifier or comment-delimiter characters across lines.
    """
    logical = []
    lines = []
    index, line_number = 0, 1
    while index < len(source):
        continuation = 0
        if not is_swift:
            continuation = 3 if source.startswith("\\\r\n", index) else 2 if source.startswith("\\\n", index) else 0
        if continuation:
            index += continuation
            line_number += 1
            continue
        logical.append(source[index])
        lines.append(line_number)
        if source[index] == "\n":
            line_number += 1
        index += 1
    return strip_comments("".join(logical), nested=is_swift), lines


def check_forbidden(root):
    root = Path(root).resolve()
    files = list(production_files(root))
    if not files:
        raise PrerequisiteError("no production App or Packages/*/Sources files exist; integration check pending")
    violations = []
    for path in files:
        is_swift = path.suffix.lower() == ".swift"
        try:
            source, lines = prepare_source(path.read_text(encoding="utf-8"), is_swift=is_swift)
        except (OSError, UnicodeError):
            raise PrerequisiteError("a production source file could not be read as UTF-8") from None
        declarations = {match.start("name") for match in SWIFT_FUNCTION.finditer(
            strip_comments(source, mask_strings=True))} if is_swift else set()
        for label, pattern in FORBIDDEN:
            for match in pattern.finditer(source):
                if "call" in pattern.groupindex and match.group("call") is not None and match.start("call") in declarations:
                    continue
                line = lines[match.start()]
                violations.append(f"{path.relative_to(root)}:{line}: {label}")
                break
    if violations:
        raise Violation("forbidden APIs found:\n" + "\n".join(violations))
    return len(files)


def load_json(path):
    def unique_keys(pairs):
        value = {}
        for key, child in pairs:
            if key in value:
                raise Violation("duplicate key in Package.resolved")
            value[key] = child
        return value
    try:
        return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_keys)
    except (OSError, ValueError, UnicodeError, RecursionError):
        raise Violation("Package.resolved must be readable, valid JSON") from None


def package_declaration(manifest):
    """Accept only the deliberately small, exact-pinned M0 manifest syntax.

    Never executes a manifest (Swift manifests are programs). Dynamic lists,
    variable URLs/versions, registry, branch, revision-only and local packages
    require review instead of being silently treated as an approved dependency.
    """
    source = strip_comments(manifest)
    tokens = re.findall(r'"(?:\\.|[^"\\])*"|[A-Za-z_]\w*|\d+|[^\s]', source)
    prefix = ["import", "PackageDescription", "let", "package", "=", "Package", "("]
    if tokens[:len(prefix)] != prefix or tokens[-1:] != [")"]:
        raise Violation("manifest must be one import PackageDescription and one let package = Package(...) declaration")
    if any(token in {"{", "}", "#", ";"} for token in tokens):
        raise Violation("computed/conditional manifests require dependency review")

    # Split the outer initializer's arguments, keeping string tokens opaque.
    arguments = []
    current = []
    stack = []
    for token in tokens[len(prefix):-1]:
        if token in {"(", "["}:
            stack.append(token)
        elif token in {")", "]"}:
            if not stack or stack.pop() != {")": "(", "]": "["}[token]:
                raise Violation("unbalanced manifest declaration")
        if token == "," and not stack:
            arguments.append(current)
            current = []
        else:
            current.append(token)
    if stack:
        raise Violation("unbalanced manifest declaration")
    if current:
        arguments.append(current)
    fields = {}
    for argument in arguments:
        if len(argument) < 3 or argument[1] != ":" or argument[0] in fields:
            raise Violation("manifest initializer must use unique literal argument labels")
        fields[argument[0]] = argument[2:]
    declaration = "".join(fields.get("dependencies", []))
    match = re.fullmatch(r'\[\.package\(url:"([^"\\]+)",exact:"(\d+\.\d+\.\d+)"[,]?\)[,]?\]', declaration)
    calls = sum(tokens[i:i+3] == [".", "package", "("] for i in range(len(tokens)))
    if not match or calls != 1 or match[1] not in GRDB_URLS:
        raise Violation("dependencies must be a literal array containing only the official GRDB.swift URL and exact version")
    return match[2]


def lock_state(path, version):
    lock = load_json(path)
    if not isinstance(lock, dict) or type(lock.get("version")) is not int or lock["version"] not in {2, 3}:
        raise Violation("only Package.resolved format 2 or 3 is supported")
    pins = lock.get("pins")
    if not isinstance(pins, list) or len(pins) != 1 or not isinstance(pins[0], dict):
        raise Violation("Package.resolved must contain exactly one approved GRDB.swift pin")
    pin = pins[0]
    if pin.get("identity") != "grdb.swift" or pin.get("location") not in GRDB_URLS or pin.get("kind") != "remoteSourceControl":
        raise Violation("unapproved dependency identity, source or kind in Package.resolved")
    state = pin.get("state")
    if not isinstance(state, dict) or set(state) != {"version", "revision"}:
        raise Violation("GRDB lock must have a version and immutable revision, with no branch")
    if state["version"] != version or not isinstance(state["revision"], str) or not re.fullmatch(r"[0-9a-f]{40}", state["revision"]):
        raise Violation("GRDB exact version/revision is invalid or inconsistent with Package.swift")
    return state["revision"]


def check_dependencies(root):
    root = Path(root).resolve()
    package = root / "Packages/AgentDashKit"
    manifest = package / "Package.swift"
    primary_lock = package / "Package.resolved"
    if not manifest.is_file() or not primary_lock.is_file():
        raise PrerequisiteError("Packages/AgentDashKit/Package.swift and Package.resolved are required; integration check pending")
    if any(p.is_symlink() for p in (root / "Packages", package, manifest, primary_lock)):
        raise PrerequisiteError("package inputs must not be symlinks")
    try:
        version = package_declaration(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeError):
        raise PrerequisiteError("Package.swift could not be read as UTF-8") from None
    revision = lock_state(primary_lock, version)
    for directory, subdirs, names in os.walk(root, followlinks=False, onerror=walk_error):
        subdirs[:] = sorted(d for d in subdirs if d not in CACHE_DIRS and d not in {"Tools", "docs"})
        if any((Path(directory) / d).is_symlink() for d in subdirs):
            raise PrerequisiteError("dependency input directories must not be symlinks")
        for name in names:
            if name not in {"Package.swift", "Package.resolved"}:
                continue
            path = Path(directory) / name
            if path.is_symlink():
                raise PrerequisiteError("dependency manifests/lockfiles must not be symlinks")
            if name == "Package.swift" and path != manifest:
                raise Violation("unexpected additional package manifest requires dependency review")
            if name == "Package.resolved" and lock_state(path, version) != revision:
                raise Violation("GRDB revisions disagree between committed lockfiles")
    return version


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("forbid", "dependencies"):
        command = commands.add_parser(name)
        command.add_argument("--root", type=Path, default=REPO,
                             help="repository root (synthetic repositories are supported)")
    commands.add_parser("entitlements").add_argument("app", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "forbid":
            count = check_forbidden(args.root)
            print(f"forbid-apis: passed ({count} production source files inspected)")
        elif args.command == "dependencies":
            version = check_dependencies(args.root)
            print(f"check-dependencies: passed (GRDB.swift exact {version}, lockfiles consistent)")
        else:
            check_artifact(args.app)
            print("check-entitlements: passed (signature, exact signed entitlements, Hardened Runtime)")
    except PrerequisiteError as error:
        print(f"{args.command}: unmet prerequisite: {error}", file=sys.stderr)
        return 2
    except Violation as error:
        print(f"{args.command}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
