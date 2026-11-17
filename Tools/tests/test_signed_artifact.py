"""Exercise the *real* codesign path on disposable synthetic apps, never the app.

This verifies the tool boundary, not Agent Dashboard/Xcode/sandbox-read acceptance.
Only existing Command Line Tools are used. No signing identity/keychain is needed.
"""

import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import guardrails as guard


@unittest.skipUnless(sys.platform == "darwin" and Path("/usr/bin/clang").is_file()
                     and Path(guard.CODESIGN).is_file(), "existing macOS clang/codesign required")
class SignedSyntheticArtifactTests(unittest.TestCase):
    def test_signed_pass_extra_entitlement_unsigned_and_missing(self):
        with tempfile.TemporaryDirectory(prefix="agentdash-m0-signing-", dir="/private/tmp") as directory:
            root = Path(directory)
            app = root / "Synthetic.app"
            executable_dir = app / "Contents/MacOS"
            executable_dir.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "local.synthetic.agentdash-tool-test",
                "CFBundleExecutable": "Synthetic", "CFBundlePackageType": "APPL",
                "CFBundleName": "Synthetic", "CFBundleVersion": "1"}))
            environment = dict(os.environ, TMPDIR=directory,
                CLANG_MODULE_CACHE_PATH=str(root / "clang-cache"))
            compiler = subprocess.run(["/usr/bin/clang", "-x", "c", "-", "-o", str(executable_dir / "Synthetic")],
                input=b"int main(void) { return 0; }\n", capture_output=True, env=environment)
            self.assertEqual(compiler.returncode, 0, compiler.stderr.decode(errors="replace"))
            command = [str(TOOLS / "check-entitlements.sh"), str(app)]
            def inspect():
                return subprocess.run(command, capture_output=True, text=True, env=environment)
            unsigned = inspect()
            self.assertEqual(unsigned.returncode, 1, unsigned.stdout + unsigned.stderr)
            entitlements = root / "Synthetic.entitlements"
            for extra, expected in ((None, 0), ("com.apple.security.network.client", 1),
                                    ("com.apple.security.unknown.synthetic", 1)):
                values = guard.required_entitlements()
                if extra:
                    values[extra] = True
                entitlements.write_bytes(plistlib.dumps(values))
                signed = subprocess.run([guard.CODESIGN, "--force", "--sign", "-", "--options", "runtime",
                    "--entitlements", str(entitlements), str(app)], capture_output=True, env=environment)
                self.assertEqual(signed.returncode, 0, signed.stderr.decode(errors="replace"))
                result = inspect()
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
            missing = subprocess.run([str(TOOLS / "check-entitlements.sh"), str(root / "Missing.app")],
                capture_output=True, text=True, env=environment)
            self.assertEqual(missing.returncode, 2)


if __name__ == "__main__":
    unittest.main()
