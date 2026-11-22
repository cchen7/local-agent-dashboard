"""SEC-3/8, ADP-3, SPEC 15.2: synthetic inputs only."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

try:
    from compression import zstd
except ImportError:
    zstd = None  # Plain JSON/JSONL capture must also work on older Python.

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
import fixture_capture as capture


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="agentdash-m0-capture-", dir="/private/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.destination = self.root / "fixtures"
        self.destination.mkdir()
        self.input = self.source / "synthetic.jsonl"
        self.output = self.destination / "fixture.jsonl"

    def write(self, records):
        self.input.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in records))

    def run_capture(self):
        capture.capture(self.input, self.output, self.source)
        return [json.loads(line) for line in self.output.read_text().splitlines()]

    def assert_no_output(self):
        self.assertFalse(self.output.exists())
        self.assertFalse(Path(str(self.output) + ".sanitized").exists())
        self.assertEqual(list(self.destination.iterdir()), [])

    def test_sanitization_schema_numbers_relationships_and_unicode(self):
        records = [
            {"type": "session_meta", "timestamp": "2026-11-17T01:02:03.123Z", "payload": {
                "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "cwd": "/Users/private/work/client",
                "originator": "Private Launcher", "model_provider": "private-provider",
                "git": {"branch": "private-branch", "repository_url": "https://private.invalid/repo"}}},
            {"type": "event_msg", "payload": {"type": "user_message", "message": "中文👩‍💻e\u0301\nsecret!",
                "sessionId": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                "parentId": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "new_private_field": "github_pat_SYNTHETIC_ONLY_1234567890", "success": True}},
            {"type": "event_msg", "payload": {"type": "token_count", "info": {
                "last_token_usage": {"input_tokens": 120, "cached_input_tokens": 40,
                    "output_tokens": 17, "reasoning_output_tokens": 7, "total_tokens": 137},
                "total_token_usage": {"total_tokens": 999}, "optional": None}}},
            {"type": "new-private-record", "payload": {"id": "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
                "role": "assistant", "text": "sk-SYNTHETIC_ONLY_secret ghp_SYNTHETIC_ONLY_secret",
                "unknown": {"/Users/private/private-key-name": "Bearer SYNTHETIC_ONLY_TOKEN"}}},
        ]
        self.write(records)
        before = (self.input.read_bytes(), self.input.stat().st_mtime_ns, self.input.stat().st_ino)
        out = self.run_capture()
        self.assertEqual(before, (self.input.read_bytes(), self.input.stat().st_mtime_ns, self.input.stat().st_ino))
        self.assertEqual(out[0]["type"], "session_meta")
        self.assertEqual(out[1]["payload"]["type"], "user_message")
        self.assertEqual(out[3]["payload"]["role"], "assistant")
        self.assertNotEqual(out[3]["type"], records[3]["type"])
        self.assertEqual(out[0]["payload"]["id"], out[1]["payload"]["sessionId"])
        self.assertEqual(out[1]["payload"]["parentId"], out[3]["payload"]["id"])
        self.assertNotEqual(out[0]["payload"]["id"], out[3]["payload"]["id"])
        self.assertTrue(out[0]["payload"]["cwd"].startswith("/Users/dev/"))
        self.assertEqual(len(out[0]["payload"]["cwd"]), len(records[0]["payload"]["cwd"]))
        self.assertEqual(len(out[1]["payload"]["message"]), len(records[1]["payload"]["message"]))
        self.assertEqual(out[2], records[2])
        self.assertNotEqual(out[0]["timestamp"], records[0]["timestamp"])
        serialized = self.output.read_text()
        for secret in ("private", "SYNTHETIC_ONLY", "sk-", "ghp_", "github_pat_", "Bearer"):
            self.assertNotIn(secret, serialized)
        marker = json.loads(Path(str(self.output) + ".sanitized").read_text())
        self.assertEqual(marker["sha256"], hashlib.sha256(self.output.read_bytes()).hexdigest())
        self.assertEqual(marker["records"], 4)
        self.assertNotIn(str(self.input), json.dumps(marker))

    def test_known_enum_is_preserved_only_in_its_schema_field(self):
        self.write([{"type": "assistant", "message": "assistant", "role": "assistant",
                     "text": "token_count", "model_provider": "azure", "id": "assistant"}])
        out = self.run_capture()[0]
        self.assertEqual(out["type"], "assistant")
        self.assertEqual(out["role"], "assistant")
        self.assertNotEqual(out["message"], "assistant")
        self.assertNotEqual(out["text"], "token_count")
        self.assertNotEqual(out["model_provider"], "azure")
        self.assertNotEqual(out["id"], "assistant")

    def test_claude_history_keeps_display_key_but_not_its_value(self):
        private_prompt = "synthetic history value 中文"
        self.write([{"display": private_prompt, "project": "/Users/synthetic/project", "timestamp": 1234}])
        row = self.run_capture()[0]
        self.assertIn("display", row)
        self.assertNotEqual(row["display"], private_prompt)
        self.assertEqual(len(row["display"]), len(private_prompt))
        self.assertNotIn(private_prompt, self.output.read_text())
        self.assertTrue(row["project"].startswith("/Users/dev/"))
        self.assertEqual(row["timestamp"], 1234)

    def test_json_nested_unknown_keys_and_embedded_json_never_pass_through(self):
        self.input = self.source / "synthetic.json"
        self.output = self.destination / "fixture.json"
        self.input.write_text(json.dumps({"arguments": '{"command":"SECRET_SYNTHETIC"}',
            "SECRET_SYNTHETIC_KEY": [{"new": 1.25, "active": False}], "input_tokens": 21}))
        capture.capture(self.input, self.output, self.source)
        self.assertNotIn("SECRET_SYNTHETIC", self.output.read_text())
        self.assertEqual(json.loads(self.output.read_text())["input_tokens"], 21)

    def test_short_paths_are_synthetic_and_ids_stay_distinct(self):
        self.write([{"id": "a", "parentId": "b", "cwd": "/a"}, {"id": "b", "parentId": "a", "cwd": "/b"}])
        a, b = self.run_capture()
        self.assertEqual(a["id"], b["parentId"])
        self.assertEqual(b["id"], a["parentId"])
        self.assertNotEqual(a["id"], b["id"])
        self.assertNotEqual(a["cwd"], b["cwd"])
        self.assertTrue(a["cwd"].startswith("/Users/dev/"))

    def test_copilot_workspace_capture_retains_only_anonymized_title_shapes(self):
        source = self.source / "workspace.yaml"
        original = b'id: synthetic-private-id\nname: |-\n  synthetic-private-name\nsummary: "synthetic-private-summary"\ncwd: /synthetic/private\n'
        source.write_bytes(original)
        output = self.destination / "workspace-shape.yaml"
        capture.capture(source, output, self.source)
        encoded = output.read_bytes()
        self.assertTrue(encoded.startswith(b"name: |-\n  Synthetic"))
        self.assertIn(b'summary: "Synthetic', encoded)
        self.assertNotIn(b"synthetic-private", encoded)
        self.assertNotIn(b"cwd", encoded)
        self.assertEqual(source.read_bytes(), original)
        marker = json.loads(output.with_suffix(".yaml.sanitized").read_text())
        self.assertEqual(marker["sha256"], hashlib.sha256(encoded).hexdigest())

    def test_repeat_capture_is_deterministic(self):
        self.write([{"id": "synthetic-id", "text": "synthetic text", "cwd": "/tmp/synthetic"}])
        self.run_capture()
        other = self.destination / "second.jsonl"
        capture.capture(self.input, other, self.source)
        self.assertEqual(self.output.read_bytes(), other.read_bytes())

    def test_unicode_separators_combining_marks_and_secret_formats(self):
        text = "中文\u2028👩‍💻e\u0301\u2029\t\n" + " ".join((
            "sk-SYNTHETIC_123", "ghp_SYNTHETIC_123", "github_pat_SYNTHETIC_123",
            "AKIA0123456789ABCDEF", "xoxb-SYNTHETIC_123", "xoxp-SYNTHETIC_123",
            "-----BEGIN RSA PRIVATE KEY-----", "API_KEY=SYNTHETIC_123",
            "TOKEN=SYNTHETIC_123", "PASSWORD=SYNTHETIC_123"))
        self.write([{"text": text, "input_tokens": 100, "output_tokens": 5}])
        out = self.run_capture()[0]
        self.assertEqual(len(out["text"]), len(text))
        self.assertEqual((out["input_tokens"], out["output_tokens"]), (100, 5))
        self.assertNotIn("SYNTHETIC_123", self.output.read_text())
        self.assertIsNone(capture.SECRET.search(out["text"]))

    def test_numeric_credentials_are_redacted_without_changing_token_accounting(self):
        self.write([{"input_tokens": 120, "output_tokens": 17,
            "API_KEY": 123456789, "password": [424242, {"input_tokens": 987654321}],
            "authorization": {"role": "assistant", "active": True}}])
        out = self.run_capture()[0]
        self.assertEqual((out["input_tokens"], out["output_tokens"]), (120, 17))
        for value in ("123456789", "424242", "987654321", "assistant", "true"):
            self.assertNotIn(value, self.output.read_text())

    def test_timestamps_are_shifted_to_synthetic_origin_with_relative_intervals(self):
        self.write([{"timestamp": "2026-11-17T01:02:03.123Z"},
                    {"timestamp": "2026-11-17T01:02:05.123Z"}])
        a, b = self.run_capture()
        self.assertEqual(a["timestamp"], "2000-01-01T00:00:00.000Z")
        self.assertEqual(b["timestamp"], "2000-01-01T00:00:02.000Z")

    def test_reject_same_file_descendants_symlinks_hardlinks_and_existing_output(self):
        self.write([{"text": "SYNTHETIC_SECRET"}])
        nested = self.source / "nested"
        nested.mkdir()
        alias = self.root / "alias"
        alias.symlink_to(self.source, target_is_directory=True)
        hardlink = self.destination / "hardlink.jsonl"
        os.link(self.input, hardlink)
        dangling = self.destination / "dangling.jsonl"
        dangling.symlink_to(self.destination / "absent.jsonl")
        targets = [self.input, nested / "out.jsonl", alias / "out.jsonl", hardlink, dangling]
        existing = self.destination / "existing.jsonl"
        existing.write_text("PRESERVE")
        targets.append(existing)
        for target in targets:
            with self.subTest(target=target.name), self.assertRaises(capture.CaptureError):
                capture.capture(self.input, target, self.source)
        self.assertEqual(existing.read_text(), "PRESERVE")
        self.assertIn("SYNTHETIC_SECRET", self.input.read_text())

    def test_protected_agent_named_ancestor_cannot_be_destination(self):
        protected = self.root / ".codex"
        nested = protected / "sessions"
        nested.mkdir(parents=True)
        source = nested / "synthetic.jsonl"
        source.write_text('{"text":"synthetic"}\n')
        with self.assertRaises(capture.CaptureError):
            capture.capture(source, protected / "outside-sessions.jsonl", nested)

    def test_all_independent_protected_destinations_and_symlink_aliases_are_rejected(self):
        self.write([{"text": "synthetic", "input_tokens": 9}])
        before = self.input.read_bytes()
        for name in (".claude", ".codex", ".copilot", ".grok"):
            protected = self.root / "different-agent-roots" / name / "nested"
            protected.mkdir(parents=True)
            alias = self.root / ("alias-" + name[1:])
            alias.symlink_to(protected, target_is_directory=True)
            for parent in (protected, alias):
                with self.subTest(agent=name, alias=parent == alias):
                    output = parent / ("alias.jsonl" if parent == alias else "direct.jsonl")
                    with self.assertRaises(capture.CaptureError):
                        capture.capture(self.input, output, self.source)
                    self.assertFalse(output.exists())
                    self.assertFalse(Path(str(output) + ".sanitized").exists())
                    self.assertEqual(list(protected.iterdir()), [])
        self.assertEqual(self.input.read_bytes(), before)

    def test_protected_symlink_names_and_chained_aliases_cannot_be_destinations(self):
        self.write([{"text": "synthetic"}])
        for index, name in enumerate((".claude", ".codex", ".copilot", ".grok", ".CoDeX")):
            area = self.root / ("synthetic-" + str(index))
            area.mkdir()
            outside = area / "ordinary-target"
            outside.mkdir()
            protected_alias = area / name
            protected_alias.symlink_to(outside, target_is_directory=True)
            chained_alias = area / "ordinary-alias"
            chained_alias.symlink_to(protected_alias, target_is_directory=True)
            for parent in (protected_alias, chained_alias):
                with self.subTest(agent=name, chained=parent == chained_alias):
                    output = parent / ("chained.jsonl" if parent == chained_alias else "direct.jsonl")
                    with self.assertRaises(capture.CaptureError):
                        capture.capture(self.input, output, self.source)
                    self.assertFalse(output.exists())
                    self.assertFalse(Path(str(output) + ".sanitized").exists())
                    self.assertEqual(list(outside.iterdir()), [])

    def test_existing_marker_is_never_replaced(self):
        self.write([{"text": "synthetic"}])
        marker = Path(str(self.output) + ".sanitized")
        marker.write_text("PRESERVE")
        with self.assertRaises(capture.CaptureError):
            self.run_capture()
        self.assertFalse(self.output.exists())
        self.assertEqual(marker.read_text(), "PRESERVE")

    def test_malformed_partial_duplicate_or_nonfinite_input_leaves_no_marker(self):
        for raw in ('{"text":\n', '{"text":"synthetic"}', '{"id":1,"id":2}\n',
                    '{"input_tokens":NaN}\n', '[]\n', ''):
            with self.subTest(raw=raw):
                self.input.write_text(raw)
                with self.assertRaises(capture.CaptureError):
                    self.run_capture()
                self.assert_no_output()
    def test_unsupported_compressed_suffix_leaves_no_marker(self):
        self.input = self.source / "synthetic.json.zst"
        self.input.write_bytes(b"not compressed real data")
        with self.assertRaises(capture.CaptureError):
            self.run_capture()
        self.assert_no_output()

    @unittest.skipIf(zstd is None, "compression.zstd unavailable")
    def test_zstd_capture_matches_plain_across_frames(self):
        records = [{"type": "session_meta", "payload": {"cwd": "/Users/private/work"}},
                   {"type": "event_msg", "payload": {"type": "token_count", "output_tokens": 9,
                                                      "message": "SECRET_SYNTHETIC_中文"}}]
        self.write(records)
        self.run_capture()
        compressed = self.source / "synthetic.jsonl.zst"
        raw = self.input.read_bytes()
        middle = len(raw) // 2
        data = zstd.compress(raw[:middle]) + zstd.compress(raw[middle:])
        compressed.write_bytes(data)
        before = capture.source_signature(compressed)
        other = self.destination / "from-zstd.jsonl"
        capture.capture(compressed, other, self.source)
        self.assertEqual(self.output.read_bytes(), other.read_bytes())
        self.assertEqual(self.output.with_suffix(".jsonl.sanitized").read_bytes(),
                         other.with_suffix(".jsonl.sanitized").read_bytes())
        self.assertEqual(compressed.read_bytes(), data)
        self.assertEqual(capture.source_signature(compressed), before)
        self.assertEqual(len(list(self.destination.iterdir())), 4)

    @unittest.skipIf(zstd is None, "compression.zstd unavailable")
    def test_bad_zstd_or_decoded_jsonl_never_publishes(self):
        self.input = self.source / "synthetic.jsonl.zst"
        frame = zstd.compress(b'{"text":"SYNTHETIC_SECRET"}\n')
        inputs = (b"not zstd", frame[:-1], frame + b"trailing junk", b"",
                  zstd.compress(b'{"text":"missing final newline"}'),
                  zstd.compress(b'{"text":"bad UTF-8 \xff"}\n'))
        for index, data in enumerate(inputs):
            with self.subTest(index=index):
                self.input.write_bytes(data)
                with self.assertRaises(capture.CaptureError) as error:
                    self.run_capture()
                self.assertNotIn("SYNTHETIC_SECRET", str(error.exception))
                self.assert_no_output()

    @unittest.skipIf(zstd is None, "compression.zstd unavailable")
    def test_zstd_rejects_oversize_input_and_oversize_expansion(self):
        self.input = self.source / "synthetic.jsonl.zst"
        frame = zstd.compress(b'{"text":"' + b"x" * 1024 + b'"}\n')
        self.input.write_bytes(frame)
        for limit, error in ((len(frame) - 1, "input exceeds"), (len(frame), "decoded input exceeds")):
            with self.subTest(limit=limit), mock.patch.object(capture, "MAX_BYTES", limit):
                with self.assertRaisesRegex(capture.CaptureError, error):
                    self.run_capture()
                self.assert_no_output()

    @unittest.skipIf(zstd is None, "compression.zstd unavailable")
    def test_zstd_rejects_oversize_decoder_window_independently_of_output(self):
        self.input = self.source / "synthetic.jsonl.zst"
        options = {zstd.CompressionParameter.window_log: 12, zstd.CompressionParameter.content_size_flag: 0}
        raw = b'{"text":"' + b"x" * 8192 + b'"}\n'
        compressor = zstd.ZstdCompressor(options=options)
        self.input.write_bytes(compressor.compress(raw, zstd.ZstdCompressor.FLUSH_FRAME))
        with mock.patch.object(capture, "MAX_ZSTD_WINDOW_LOG", 10):
            with self.assertRaisesRegex(capture.CaptureError, "unsupported zstd input"):
                self.run_capture()
            self.assert_no_output()
        self.assertEqual(len(self.run_capture()[0]["text"]), 8192)

    def test_zstd_requires_plain_jsonl_output_and_optional_stdlib_decoder(self):
        compressed = self.source / "synthetic.jsonl.zst"
        compressed.write_bytes(b"synthetic")
        with self.assertRaisesRegex(capture.CaptureError, "output extension"):
            capture.capture(compressed, self.destination / "fixture.jsonl.zst", self.source)
        with mock.patch.object(capture, "zstd", None, create=True):
            with self.assertRaisesRegex(capture.CaptureError, "compression.zstd"):
                capture.capture(compressed, self.output, self.source)
            self.assert_no_output()
            self.write([{"type": "session_meta"}])
            self.assertEqual(self.run_capture(), [{"type": "session_meta"}])

    def test_validation_failure_and_source_change_do_not_publish(self):
        self.write([{"text": "synthetic"}])
        with mock.patch.object(capture, "validate_sanitized", side_effect=capture.CaptureError("synthetic failure")):
            with self.assertRaises(capture.CaptureError):
                self.run_capture()
        self.assert_no_output()
        original = capture.validate_sanitized

        def mutate(*args):
            original(*args)
            self.input.write_text('{"text":"synthetic changed"}\n')

        with mock.patch.object(capture, "validate_sanitized", side_effect=mutate):
            with self.assertRaises(capture.CaptureError):
                self.run_capture()
        self.assert_no_output()

    def test_marker_publication_failure_rolls_back_own_output(self):
        self.write([{"text": "synthetic"}])
        link = os.link

        def fail_marker(src, dst, **kwargs):
            if str(dst).endswith(".sanitized"):
                raise OSError("synthetic publication failure")
            return link(src, dst, **kwargs)

        with mock.patch.object(capture.os, "link", side_effect=fail_marker):
            with self.assertRaises(capture.CaptureError):
                self.run_capture()
        self.assert_no_output()

    def test_destination_parent_symlink_change_cannot_redirect_a_write_into_source(self):
        self.write([{"text": "synthetic"}])
        original = capture.validate_sanitized

        def change_parent(*args):
            original(*args)
            self.destination.rmdir()
            self.destination.symlink_to(self.source, target_is_directory=True)

        with mock.patch.object(capture, "validate_sanitized", side_effect=change_parent):
            with self.assertRaises(capture.CaptureError):
                self.run_capture()
        self.assertEqual(list(self.source.iterdir()), [self.input])

    def test_an_output_created_after_validation_is_not_overwritten(self):
        self.write([{"text": "synthetic"}])
        original = capture.validate_sanitized

        def publish_other(*args):
            original(*args)
            self.output.write_text("PRESERVE_OTHER_WRITER")

        with mock.patch.object(capture, "validate_sanitized", side_effect=publish_other):
            with self.assertRaises(capture.CaptureError):
                self.run_capture()
        self.assertEqual(self.output.read_text(), "PRESERVE_OTHER_WRITER")
        self.assertFalse(Path(str(self.output) + ".sanitized").exists())
        self.assertEqual(list(self.destination.iterdir()), [self.output])

    def test_cli_errors_do_not_echo_source_content(self):
        self.input.write_text('{"SECRET_SYNTHETIC_CONTENT": broken}\n')
        result = subprocess.run([str(TOOLS / "fixture-capture"), "--input", str(self.input),
            "--output", str(self.output), "--source-root", str(self.source)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("SECRET_SYNTHETIC_CONTENT", result.stderr + result.stdout)
        self.assert_no_output()


if __name__ == "__main__":
    unittest.main()
