import hashlib
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_package as release


TEAM = "ABCDEF1234"
REVISION = "a" * 40


class ReleasePackageTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.archive = self.root / "fixture.zip"

    def write_zip(self, *names):
        with zipfile.ZipFile(self.archive, "w", zipfile.ZIP_DEFLATED) as archive:
            for name in names:
                archive.writestr(name, b"" if name.endswith("/") else b"synthetic")

    def test_archive_accepts_only_the_app_and_its_appledouble_metadata(self):
        self.write_zip("AgentDashboard.app/Contents/Info.plist",
                       "__MACOSX/._AgentDashboard.app",
                       "__MACOSX/AgentDashboard.app/Contents/._Info.plist")
        release.validate_archive_layout(self.archive)
        self.write_zip("AgentDashboard.app/Contents/Info.plist", "other.app/Contents/Info.plist")
        with self.assertRaisesRegex(release.Rejected, "outside the expected app"):
            release.validate_archive_layout(self.archive)

    def test_archive_rejects_unsafe_names_and_aliasing_directories(self):
        self.write_zip("AgentDashboard.app/Contents/Info.plist", "AgentDashboard.app/Contents/../sibling")
        with self.assertRaisesRegex(release.Rejected, "unsafe member path"):
            release.validate_archive_layout(self.archive)
        self.write_zip("AgentDashboard.app/Contents/A", "AgentDashboard.app/contents/B")
        with self.assertRaisesRegex(release.Rejected, "colliding directory"):
            release.validate_archive_layout(self.archive)

    def test_archive_rejects_symlink_member(self):
        with zipfile.ZipFile(self.archive, "w") as archive:
            link = zipfile.ZipInfo("AgentDashboard.app/Contents/synthetic-link")
            link.create_system = 3
            link.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(link, "synthetic-target")
        with self.assertRaisesRegex(release.Rejected, "symlink"):
            release.validate_archive_layout(self.archive)

    def test_archive_rejects_conflicting_local_member_name(self):
        name = "AgentDashboard.app/Contents/SyntheticA"
        self.write_zip(name)
        data = self.archive.read_bytes()
        self.archive.write_bytes(data.replace(name.encode(), name[:-1].encode() + b"B", 1))
        with self.assertRaises(zipfile.BadZipFile):
            release.validate_archive_layout(self.archive)

    def test_digest_mismatch_precedes_extraction(self):
        self.write_zip("AgentDashboard.app/Contents/Info.plist")
        real = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.assertNotEqual(real, "0" * 64)
        with patch.object(release, "checked_command") as command:
            with self.assertRaisesRegex(release.Rejected, "does not match the reviewed digest"):
                release.verify(self.archive, sha256="0" * 64, team=TEAM,
                               revision=REVISION, version="0.1.0", build="1")
            command.assert_not_called()

    def test_revision_mismatch_never_runs_notarization_or_distribution_checks(self):
        app = self.root / release.APP_NAME
        contents = app / "Contents"
        contents.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": release.APP_ID,
            "CFBundleExecutable": release.EXECUTABLE,
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            release.REVISION_KEY: "b" * 40,
        }))
        # Model the prior Apple checks succeeding; no signing or trust
        # operation is exercised by this metadata-stage regression.
        with patch.object(release, "checked_command") as command, patch.object(release.guardrails, "check_artifact"):
            with self.assertRaisesRegex(release.Rejected, "source revision"):
                release.verify_unpacked(app, team=TEAM, revision=REVISION, version="0.1.0", build="1")
            self.assertEqual(command.call_count, 2)
            requirement = command.call_args_list[1].args[0][3]
            self.assertIn("1.2.840.113635.100.6.1.13", requirement)
            self.assertIn(f'certificate leaf[subject.OU] = "{TEAM}"', requirement)

    def test_distribution_assessment_requires_explicit_flag(self):
        with patch.object(release, "verify") as verify:
            with patch("sys.stderr"), self.assertRaises(SystemExit) as failure:
                release.main([str(self.archive), "--sha256", "0" * 64, "--team-id", TEAM,
                              "--revision", REVISION, "--version", "0.1.0", "--build", "1"])
            self.assertEqual(failure.exception.code, 2)
            verify.assert_not_called()
