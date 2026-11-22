"""The launch preflight refuses to execute a non-QA or unguarded bundle."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import guardrails as guard


class SyntheticLaunchTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.app = Path(directory.name) / "AgentDashboard.app"
        self.binary = self.app / "Contents" / "MacOS" / "AgentDashboard"
        self.binary.parent.mkdir(parents=True)
        self.binary.write_bytes(b"synthetic Mach-O fixture")
        self.binary.chmod(0o700)

    def write_info(self, bundle_id):
        data = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "AgentDashboard"}
        (self.app / "Contents" / "Info.plist").write_bytes(plistlib.dumps(data))

    def test_normal_bundle_rejected_before_running_any_code(self):
        self.write_info("com.chenxin.AgentDashboard")
        with mock.patch.object(guard, "check_artifact") as verify, mock.patch.object(subprocess, "run") as start:
            with self.assertRaisesRegex(guard.Violation, "isolated SyntheticQA"):
                guard.check_synthetic_launch(self.app)
            verify.assert_not_called()
            start.assert_not_called()

    def test_signed_container_without_compiled_guard_is_not_launched(self):
        self.write_info(guard.QA_BUNDLE_ID)
        with mock.patch.object(guard, "check_artifact") as verify, mock.patch.object(subprocess, "run") as start:
            with self.assertRaisesRegex(guard.Violation, "compiled launch guard"):
                guard.check_synthetic_launch(self.app)
            verify.assert_called_once_with(self.app)
            start.assert_not_called()

    def test_signed_guarded_bundle_must_actually_exit_before_the_preview(self):
        self.write_info(guard.QA_BUNDLE_ID)
        self.binary.write_bytes(b"synthetic prefix " + guard.QA_REFUSAL + b"\x00")
        with mock.patch.object(guard, "check_artifact"), mock.patch.object(subprocess, "run") as start:
            start.return_value = subprocess.CompletedProcess([], 0, b"", b"")
            with self.assertRaisesRegex(guard.Violation, "did not refuse"):
                guard.check_synthetic_launch(self.app)
            start.return_value = subprocess.CompletedProcess([], 64, b"", guard.QA_REFUSAL + b"\n")
            guard.check_synthetic_launch(self.app)
            self.assertEqual(start.call_args.args, ([str(self.binary.resolve())],))


if __name__ == "__main__":
    unittest.main()
