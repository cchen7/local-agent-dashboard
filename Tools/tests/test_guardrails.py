"""SEC-1/2/4/5/6/7: production-shaped, entirely synthetic repositories."""

import copy
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import guardrails as guard

GRDB_URL = "https://github.com/groue/GRDB.swift.git"
REVISION = "a" * 40


class GuardrailTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentdash-m0-guards-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def source(self, text, relative="App/Synthetic.swift"):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        return path

    def package(self, version="7.8.0"):
        path = self.root / "Packages/AgentDashKit"
        path.mkdir(parents=True, exist_ok=True)
        (path / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "AgentDashKit", dependencies: [
    .package(url: "%s", exact: "%s")
], targets: [.target(name: "ADStore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")])])
''' % (GRDB_URL, version))
        lock = {"version": 3, "pins": [{"identity": "grdb.swift", "kind": "remoteSourceControl",
            "location": GRDB_URL, "state": {"revision": REVISION, "version": version}}]}
        (path / "Package.resolved").write_text(json.dumps(lock))
        return path, lock

    def test_allowed_sources_comments_strings_and_excluded_trees(self):
        self.source('''import Foundation
// URLSession.shared must never be used.
/* outer /* Process() */ URLSession */
let allowed = ProcessInfo.processInfo
let text = "https://example.invalid/ordinary-text"
let raw = #"not a comment: // and /*"#
''')
        for path in (".worktrees/other/App/Bad.swift", "Packages/AgentDashKit/.build/Bad.swift",
                     "Packages/AgentDashKit/Tests/Fixtures/Bad.swift", "docs/Bad.swift", "Tools/Bad.swift"):
            self.source("URLSession.shared", path)
        self.assertGreater(guard.check_forbidden(self.root), 0)

    def test_every_forbidden_family_is_rejected(self):
        examples = ["URLSession.shared", "NSURLConnection()", "import Network", "import CFNetwork", "NWConnection()",
            "NWListener()", "CFSocketCreate()", "CFReadStreamCreatePairWithSocketToHost()",
            "socket (1, 2, 3)", "getaddrinfo()", "WKWebView()", "SFSafariViewController()",
            "Process()", "NSTask()", "posix_spawnp()", "fork()", "system(\"synthetic\")",
            "NSAppleScript()", "NSAppleEventDescriptor()", "AESendMessage()", "import ScriptingBridge", "SBApplication()",
            "import FoundationModels", "LanguageModelSession()", "NLEmbedding.wordEmbedding()",
            "NLModel()", "NLContextualEmbedding()", "import CoreML", "import CreateML", "MLModel()",
            "import CoreSpotlight", "import CloudKit"]
        for example in examples:
            with self.subTest(example=example):
                self.source(example)
                with self.assertRaises(guard.Violation):
                    guard.check_forbidden(self.root)

    def test_comments_fixture_names_conditional_code_and_literals_cannot_hide_use(self):
        examples = ["/* allowed fixture */ URLSession.shared", "// fixture\nProcess()",
            '#if false\nimport Network\n#endif', 'let name = "URLSession"',
            'let raw = #"escape \\"#; Process()',
            'let raw = ##"escape \\"##; Process()',
            'let text = "\\(Process())"', 'let text = """\nURLSession\n"""']
        for example in examples:
            with self.subTest(example=example):
                self.source(example, "Packages/AgentDashKit/Sources/ADCore/Fixtures/Example.swift")
                with self.assertRaises(guard.Violation):
                    guard.check_forbidden(self.root)

    def test_ui_keyboard_guard_rejects_source_selection_and_unguarded_synthesis(self):
        baseline = self.source('let example = "field.typeText(synthetic)"', "App/Tests/SmokeTests.swift")
        own = self.source("read(TISCopyCurrentKeyboardInputSource()); event.postToPid(pid)",
                          "App/Tests/FixedKeyboardTests.swift")
        self.assertEqual(guard.check_ui_keyboard(self.root), 2)
        for call in ("field.typeText(text)", "app.typeKey(key)", "TISCreateInputSourceList(nil, true)",
                     "TISCopyCurrentASCIICapableKeyboardInputSource()", "TISSelectInputSource(ref)",
                     "CGRequestPostEventAccess()", "event.postToPid(pid)",
                     "XCUIElement.perform(withKeyModifiers: .command) {}"):
            with self.subTest(call=call):
                baseline.write_text(call)
                with self.assertRaises(guard.Violation):
                    guard.check_ui_keyboard(self.root)
        baseline.write_text("label.click()")
        for call in ("TISEnableInputSource(ref)", "CGRequestPostEventAccess()", "event.post(tap: .cgSessionEventTap)"):
            own.write_text(call)
            with self.subTest(driver_call=call), self.assertRaises(guard.Violation):
                guard.check_ui_keyboard(self.root)

    def test_production_uses_native_fields_without_keyboard_automation(self):
        self.source("TextField(\"Query\", text: $query).keyboardShortcut(.defaultAction)")
        self.assertEqual(guard.check_forbidden(self.root), 1)
        for call in ("TISCopyCurrentKeyboardInputSource()", "TISSelectInputSource(ref)", "CGRequestPostEventAccess()",
                     "CGEventCreateKeyboardEvent(nil, 0, true)", "event.postToPid(pid)"):
            with self.subTest(call=call):
                self.source(call)
                with self.assertRaises(guard.Violation):
                    guard.check_forbidden(self.root)

    def test_c_line_continuation_cannot_hide_a_socket_call(self):
        self.source("int fd = so\\\ncket(1, 2, 3);", "App/Synthetic.c")
        with self.assertRaises(guard.Violation):
            guard.check_forbidden(self.root)

    def test_c_identifier_splicing_joins_system_without_whitespace(self):
        for newline in ("\n", "\r\n"):
            with self.subTest(newline=repr(newline)):
                self.source('void run(void) { sys\\' + newline + 'tem("synthetic"); }', "App/Synthetic.c")
                with self.assertRaisesRegex(guard.Violation, r"App/Synthetic.c:1: SEC-5 process"):
                    guard.check_forbidden(self.root)

    def test_c_splicing_precedes_comments_and_preserves_original_diagnostic_lines(self):
        allowed = [
            '// continued comment \\\nsystem("comment only");\n',
            '/\\\n* system("comment only"); *\\\n/\n',
        ]
        for source in allowed:
            with self.subTest(source=source):
                self.source(source, "App/Synthetic.c")
                self.assertEqual(guard.check_forbidden(self.root), 1)
        # Splicing makes /* part of the preceding // comment, so the real call
        # on physical line 4 must not disappear inside a fabricated block comment.
        self.source('void run(void) {\n// continued \\\n/*\nsys\\\ntem("synthetic"); // */\n}\n', "App/Synthetic.c")
        with self.assertRaisesRegex(guard.Violation, r"App/Synthetic.c:4: SEC-5 process"):
            guard.check_forbidden(self.root)

    def test_c_block_comments_are_not_swift_nested_comments(self):
        self.source('void run(void) { /* outer /* inner */ system("synthetic"); // */\n}', "App/Synthetic.c")
        with self.assertRaises(guard.Violation):
            guard.check_forbidden(self.root)

    def test_swift_function_declarations_are_not_posix_calls(self):
        declarations = [
            'protocol TokenSink { func accept(token: String, flags: Int) throws }',
            'struct TokenSink { func accept(token: String) { consume(token) } }',
            'struct TokenSink { func /* schema method */ accept(token: String) {} }',
            'protocol TokenSink { func\naccept(token: String) }',
            'struct TokenSink { func `accept`(token: String) {} }',
            'struct TokenSink { func connect(token: String) {}\nfunc system(token: String) {} }',
        ]
        for source in declarations:
            with self.subTest(source=source):
                self.source(source)
                self.assertEqual(guard.check_forbidden(self.root), 1)

    def test_swift_declarations_do_not_hide_forbidden_calls_in_bodies_or_defaults(self):
        forbidden = [
            'func accept(token: String) { accept(0, nil, nil) }',
            'func accept(token: String) { Darwin.accept(0, nil, nil) }',
            'func `accept`(token: String) { Darwin.`accept`(0, nil, nil) }',
            'func system(token: String) { system("synthetic") }',
            'func accept(token: String = String(system("synthetic"))) {}',
            'func accept(token: String) { let session = URLSession.shared }',
            'let name = "func accept("',
        ]
        for source in forbidden:
            with self.subTest(source=source):
                self.source(source)
                with self.assertRaises(guard.Violation):
                    guard.check_forbidden(self.root)

    def test_missing_sources_and_external_source_symlinks_fail_closed(self):
        with self.assertRaises(guard.PrerequisiteError):
            guard.check_forbidden(self.root)
        outside = self.source("import Foundation", "outside.swift")
        sources = self.root / "App"
        sources.mkdir()
        (sources / "Alias.swift").symlink_to(outside)
        with self.assertRaises(guard.PrerequisiteError):
            guard.check_forbidden(self.root)

    def test_required_entitlements_exact_types_and_paths(self):
        entitlements = guard.required_entitlements()
        guard.validate_entitlements(entitlements)
        bad_cases = []
        for key in entitlements:
            bad = copy.deepcopy(entitlements)
            del bad[key]
            bad_cases.append(bad)
        for key in ("com.apple.security.network.client", "com.apple.security.network.server", "unknown"):
            bad = copy.deepcopy(entitlements)
            bad[key] = True
            bad_cases.append(bad)
        for value in (False, 1, "true"):
            bad = copy.deepcopy(entitlements)
            bad["com.apple.security.app-sandbox"] = value
            bad_cases.append(bad)
        path_key = "com.apple.security.temporary-exception.files.home-relative-path.read-only"
        for paths in (["/"], ["/.codex/", "../"], entitlements[path_key] + ["/.codex/"], "~/.codex"):
            bad = copy.deepcopy(entitlements)
            bad[path_key] = paths
            bad_cases.append(bad)
        for bad in bad_cases:
            with self.subTest(bad=bad), self.assertRaises(guard.Violation):
                guard.validate_entitlements(bad)

    def test_signed_inspection_never_skips_missing_unsigned_or_unavailable(self):
        with self.assertRaises(guard.PrerequisiteError):
            guard.check_artifact(self.root / "Missing.app")
        app = self.root / "Synthetic.app"
        app.mkdir()
        with mock.patch.object(guard, "CODESIGN", str(self.root / "missing-tool")):
            with self.assertRaises(guard.PrerequisiteError):
                guard.check_artifact(app)
        failure = subprocess.CompletedProcess([], 1, b"", b"not signed")
        with mock.patch.object(guard.subprocess, "run", return_value=failure):
            with self.assertRaises(guard.Violation):
                guard.check_artifact(app)

    def test_signed_inspection_validates_extracted_plist_and_runtime(self):
        app = self.root / "Synthetic.app"
        app.mkdir()

        def result(out=b"", err=b""):
            return subprocess.CompletedProcess([], 0, out, err)

        good = [result(), result(plistlib.dumps(guard.required_entitlements())), result(err=b"flags=0x10000(runtime)")]
        with mock.patch.object(guard.subprocess, "run", side_effect=good):
            guard.check_artifact(app)
        for plist, metadata in ((b"", b"runtime"), (b"not a plist", b"runtime"),
                                (plistlib.dumps(guard.required_entitlements()), b"flags=0x0(none)")):
            with mock.patch.object(guard.subprocess, "run", side_effect=[result(), result(plist), result(err=metadata)]):
                with self.assertRaises(guard.Violation):
                    guard.check_artifact(app)

    def test_dependency_pass_exact_pin_and_all_lockfiles(self):
        path, lock = self.package()
        self.assertEqual(guard.check_dependencies(self.root), "7.8.0")
        extra_lock = self.root / "AgentDashboard.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        extra_lock.parent.mkdir(parents=True)
        extra_lock.write_text(json.dumps(lock))
        self.assertEqual(guard.check_dependencies(self.root), "7.8.0")
        lock["pins"][0]["state"]["revision"] = "b" * 40
        extra_lock.write_text(json.dumps(lock))
        with self.assertRaises(guard.Violation):
            guard.check_dependencies(self.root)

    def test_dependency_missing_package_or_lock_is_unmet_prerequisite(self):
        with self.assertRaises(guard.PrerequisiteError):
            guard.check_dependencies(self.root)
        path, _ = self.package()
        (path / "Package.resolved").unlink()
        with self.assertRaises(guard.PrerequisiteError):
            guard.check_dependencies(self.root)

    def test_unapproved_dependency_pin_ranges_and_inconsistent_lock_rejected(self):
        path, lock = self.package()
        manifest = path / "Package.swift"
        original = manifest.read_text()
        bad_manifests = [original.replace('exact: "7.8.0"', 'from: "7.8.0"'),
            original.replace(GRDB_URL, "https://example.invalid/GRDB.swift.git"),
            original.replace('], targets:', ', .package(path: "../Unapproved")], targets:'),
            original.replace('exact: "7.8.0"', 'exact: selectedVersion'),
            original.replace('dependencies: [\n', 'dependencies: approved + [\n')]
        for text in bad_manifests:
            with self.subTest(text=text):
                manifest.write_text(text)
                with self.assertRaises(guard.Violation):
                    guard.check_dependencies(self.root)

    def test_manifest_decoys_dynamic_or_conditional_declarations_fail_closed(self):
        path, _ = self.package()
        manifest = path / "Package.swift"
        original = manifest.read_text()
        for text in (
            original.replace("import PackageDescription", "import PackageDescription\nlet decoy = 1"),
            original.replace('], targets:', '] + additionalPackages, targets:'),
            original + '\npackage = Package(name: "Bypass", dependencies: [])\n',
            original.replace('let package =', '#if os(macOS)\nlet package =') + '\n#endif',
            'import PackageDescription\nlet example = #"' + original.split("let package = ")[1] + '"#\n'
                + 'let package = Package(name: "Bypass", dependencies: [])',
        ):
            with self.subTest(text=text):
                manifest.write_text(text)
                with self.assertRaises(guard.Violation):
                    guard.check_dependencies(self.root)

    def test_lockfile_duplicate_keys_and_invalid_format_fail_closed(self):
        path, lock = self.package()
        for raw in ('{"version":3,"version":2,"pins":[]}', '[1,2]',
                    json.dumps({**lock, "version": True})):
            with self.subTest(raw=raw):
                (path / "Package.resolved").write_text(raw)
                with self.assertRaises(guard.Violation):
                    guard.check_dependencies(self.root)
    def test_unapproved_or_inconsistent_lock_rejected(self):
        path, lock = self.package()
        bad_locks = []
        for field, value in (("identity", "zstd"), ("location", "https://example.invalid/grdb"), ("kind", "fileSystem")):
            bad = copy.deepcopy(lock)
            bad["pins"][0][field] = value
            bad_locks.append(bad)
        for state in ({"version": "7.7.0", "revision": REVISION}, {"branch": "main", "revision": REVISION},
                      {"version": "7.8.0", "revision": "not-a-commit"}):
            bad = copy.deepcopy(lock)
            bad["pins"][0]["state"] = state
            bad_locks.append(bad)
        bad = copy.deepcopy(lock)
        bad["pins"].append({"identity": "unapproved"})
        bad_locks.append(bad)
        for bad in bad_locks:
            with self.subTest(lock=bad):
                (path / "Package.resolved").write_text(json.dumps(bad))
                with self.assertRaises(guard.Violation):
                    guard.check_dependencies(self.root)

    def test_cli_exit_codes_and_synthetic_pass_fail(self):
        command = [str(TOOLS / "forbid-apis.sh"), "--root", str(self.root)]
        def run(args):
            return subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(run(command).returncode, 2)
        self.source("import Foundation")
        self.assertEqual(run(command).returncode, 0)
        self.source("URLSession.shared")
        self.assertEqual(run(command).returncode, 1)
        dep_command = [str(TOOLS / "check-dependencies.sh"), "--root", str(self.root)]
        self.assertEqual(run(dep_command).returncode, 2)
        path, lock = self.package()
        self.assertEqual(run(dep_command).returncode, 0)
        lock["pins"].append({"identity": "unapproved"})
        (path / "Package.resolved").write_text(json.dumps(lock))
        self.assertEqual(run(dep_command).returncode, 1)


if __name__ == "__main__":
    unittest.main()
