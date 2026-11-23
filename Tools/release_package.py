"""Verify, but never sign, notarize, install or launch, the Release ZIP."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata
import zipfile

import guardrails


APP_NAME = "AgentDashboard.app"
APP_ID = "com.chenxin.AgentDashboard"
EXECUTABLE = "AgentDashboard"
REVISION_KEY = "AgentDashboardSourceRevision"
MAX_ARCHIVE_BYTES = 256 * 1024 * 1024
MAX_UNPACKED_BYTES = 512 * 1024 * 1024
MAX_MEMBERS = 20_000


class Rejected(Exception):
    """A stage-specific reason without file contents or command output."""


def code_requirement(team):
    if re.fullmatch(r"[A-Z0-9]{10}", team) is None:
        raise Rejected("invalid expected Team ID")
    # Apple's Developer ID Application requirement, not the App Store
    # alternative. The OU and executable identifier are both pinned.
    return (f'anchor apple generic and identifier "{APP_ID}" and '
            "certificate 1[field.1.2.840.113635.100.6.2.6] exists and "
            "certificate leaf[field.1.2.840.113635.100.6.1.13] exists and "
            f'certificate leaf[subject.OU] = "{team}"')


def staged_archive(path, private_copy, expected_sha):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    digest = hashlib.sha256()
    with os.fdopen(fd, "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= MAX_ARCHIVE_BYTES:
            raise Rejected("expected a bounded regular ZIP file")
        read = 0
        with open(private_copy, "xb") as copy:
            for chunk in iter(lambda: source.read(256 * 1024), b""):
                read += len(chunk)
                if read > before.st_size:
                    raise Rejected("archive changed during verification")
                digest.update(chunk)
                copy.write(chunk)
        after = os.fstat(source.fileno())
        if (read != before.st_size or before.st_size != after.st_size
                or before.st_mtime_ns != after.st_mtime_ns or before.st_ctime_ns != after.st_ctime_ns):
            raise Rejected("archive changed during verification")
    if digest.hexdigest() != expected_sha:
        raise Rejected("ZIP SHA-256 does not match the reviewed digest")


def validate_archive_layout(path):
    paths = {}
    spelling = {}
    total = 0
    has_app = False
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        if not 0 < len(members) <= MAX_MEMBERS:
            raise Rejected("ZIP has no members or exceeds the member limit")
        for item in members:
            directory = item.is_dir()
            name = item.filename
            parts = (name[:-1] if directory else name).split("/")
            if (item.orig_filename != name or "\\" in name or ":" in name
                    or any(ord(c) < 32 or ord(c) == 127 for c in name)
                    or any(part in ("", ".", "..") for part in parts)):
                raise Rejected("ZIP contains an unsafe member path")
            mode = stat.S_IFMT(item.external_attr >> 16)
            if mode not in (0, stat.S_IFDIR if directory else stat.S_IFREG):
                raise Rejected("ZIP contains a symlink or nonregular member")
            if item.flag_bits & 1 or item.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise Rejected("ZIP contains an encrypted or unsupported member")
            total += item.file_size
            if total > MAX_UNPACKED_BYTES or (directory and item.file_size != 0):
                raise Rejected("ZIP exceeds the unpacked size policy")
            if parts[0] == APP_NAME:
                if len(parts) == 1 and not directory:
                    raise Rejected("ZIP app root is not a directory")
                has_app = True
            elif not apple_double(parts, directory):
                raise Rejected("ZIP contains something outside the expected app and its metadata")
            # macOS volumes can collapse case and Unicode variants.
            key = tuple(unicodedata.normalize("NFD", x.casefold()) for x in parts)
            if key in paths:
                raise Rejected("ZIP contains duplicate or colliding member paths")
            for i in range(1, len(key) + 1):
                literal = tuple(parts[:i])
                if spelling.setdefault(key[:i], literal) != literal:
                    raise Rejected("ZIP contains colliding directory spellings")
            paths[key] = directory
            # ZIP readers can disagree about a conflicting local-header name.
            # zipfile.open checks it against the validated central directory.
            with archive.open(item):
                pass
        if archive.testzip() is not None:
            raise Rejected("ZIP member integrity check failed")
    if not has_app:
        raise Rejected("ZIP does not contain the expected App bundle")
    for parts in paths:
        if any(paths.get(parts[:i]) is False for i in range(1, len(parts))):
            raise Rejected("ZIP member has a file where a directory is required")


def apple_double(parts, directory):
    if parts[0] != "__MACOSX":
        return False
    if len(parts) == 1:
        return directory
    if len(parts) == 2:
        return parts[1] == (APP_NAME if directory else "._" + APP_NAME)
    return parts[1] == APP_NAME and (directory or parts[-1].startswith("._"))


def checked_command(args, error, timeout=45):
    try:
        result = subprocess.run(args, capture_output=True, stdin=subprocess.DEVNULL, timeout=timeout, check=False)
    except FileNotFoundError:
        raise guardrails.PrerequisiteError("a required macOS or Xcode tool is missing") from None
    except (OSError, subprocess.TimeoutExpired):
        raise Rejected(error + " (could not complete)") from None
    if result.returncode:
        raise Rejected(error)
    return result.stdout


def verify_unpacked(app, *, team, revision, version, build):
    if not app.is_dir() or app.is_symlink() or any(item.is_symlink() for item in app.rglob("*")):
        raise Rejected("extracted bundle must be a real app without symlinks")
    checked_command(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)],
                    "extracted code signature failed")
    checked_command(["/usr/bin/codesign", "--verify", "--strict", "-R=" + code_requirement(team), str(app)],
                    "expected Apple Developer ID Application signature and team; ad-hoc is not distributable")
    guardrails.check_artifact(app)
    contents = app / "Contents"
    info_path = contents / "Info.plist"
    binary = contents / "MacOS" / EXECUTABLE
    try:
        if info_path.stat().st_size > 262_144:
            raise Rejected("signed Info.plist is unexpectedly large")
        info = plistlib.loads(info_path.read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException):
        raise Rejected("signed Info.plist is unreadable") from None
    if not isinstance(info, dict) or (info.get("CFBundleIdentifier"), info.get("CFBundleExecutable")) != (APP_ID, EXECUTABLE):
        raise Rejected("bundle identifier or executable is not the ordinary Release app")
    if (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")) != (version, build):
        raise Rejected("signed version or build number does not match")
    if info.get(REVISION_KEY) != revision:
        raise Rejected("signed source revision is absent or does not match the reviewed commit")
    if checked_command(["/usr/bin/lipo", "-archs", str(binary)], "cannot inspect Release architecture").strip() != b"arm64":
        raise Rejected("expected an arm64-only Release executable")
    checked_command(["/usr/bin/xcrun", "stapler", "validate", str(app)],
                    "stapled notarization ticket could not be validated", timeout=60)
    checked_command(["/usr/bin/syspolicy_check", "distribution", str(app)],
                    "macOS distribution assessment failed", timeout=60)


def verify(path, *, sha256, team, revision, version, build):
    with tempfile.TemporaryDirectory(prefix="agentdash-release-check-", dir="/private/tmp") as scratch:
        root = Path(scratch)
        copy = root / "signed.zip"
        staged_archive(path, copy, sha256)
        validate_archive_layout(copy)
        extracted = root / "package"
        extracted.mkdir()
        checked_command(["/usr/bin/ditto", "-x", "-k", str(copy), str(extracted)], "safe ZIP extraction failed")
        if {entry.name for entry in extracted.iterdir()} != {APP_NAME}:
            raise Rejected("unexpected extracted package contents")
        verify_unpacked(extracted / APP_NAME, team=team, revision=revision, version=version, build=build)
    return {"sha256": sha256, "sourceRevision": revision, "version": version, "build": build,
            "architecture": "arm64", "developerID": "verified", "staple": "verified", "distribution": "passed"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("zip_file", type=Path)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--revision", required=True, help="reviewed full 40-character Git commit")
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--assess", action="store_true", help="allow macOS trust assessment, which may contact Apple")
    args = parser.parse_args(argv)
    if not args.assess:
        parser.error("--assess is required for the notarization and macOS distribution checks")
    if re.fullmatch(r"[0-9a-fA-F]{64}", args.sha256) is None or re.fullmatch(r"[0-9a-f]{40}", args.revision) is None:
        parser.error("supply a full SHA-256 digest and a full lowercase Git commit")
    if re.fullmatch(r"[A-Z0-9]{10}", args.team_id) is None:
        parser.error("Team ID must be ten uppercase letters or digits")
    if any(re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,3}", value) is None for value in (args.version, args.build)):
        parser.error("expected version and build must be numeric version strings")
    try:
        result = verify(args.zip_file, sha256=args.sha256.lower(), team=args.team_id, revision=args.revision,
                        version=args.version, build=args.build)
    except guardrails.PrerequisiteError as error:
        print(f"check-release-package: {error}", file=sys.stderr)
        return 2
    except (Rejected, guardrails.Violation) as error:
        print(f"check-release-package: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, RuntimeError, zipfile.BadZipFile):
        print("check-release-package: could not safely read or stage the ZIP", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
