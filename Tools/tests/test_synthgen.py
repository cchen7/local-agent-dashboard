import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch
from uuid import UUID

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import synthgen


class SyntheticCorpusTests(unittest.TestCase):
    def test_smoke_exact_bytes_shapes_and_reproducibility(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            a = synthgen.generate(synthgen.plan(synthgen.PROFILES["smoke"], 27, "smoke"), root, [])
            b = synthgen.generate(synthgen.plan(synthgen.PROFILES["smoke"], 27, "smoke"), root, [])
            self.assertNotEqual(a, b)

            def tree(path):
                return {p.relative_to(path): hashlib.sha256(p.read_bytes()).digest()
                        for p in path.rglob("*") if p.is_file()}

            self.assertEqual(tree(a), tree(b))
            manifest = json.loads((a / "manifest.json").read_text())
            self.assertEqual(manifest["sessions"], 8)
            self.assertEqual(manifest["jsonlRecords"], 288)
            self.assertEqual(manifest["rawBytes"], 1_000_000)
            self.assertEqual(sum(p.stat().st_size for p in a.rglob("*")
                                 if p.is_file() and p.name != "manifest.json"), 1_000_000)

            expected = {
                "claude_code": (888, 264, 168, 72, 312, 0),
                "codex": (310, 90, 0, 0, 110, 30),
                "copilot": (348, 96, 48, 0, 108, 24),
                "grok_build": (276, 72, 0, 0, 84, 0),
            }
            for agent in synthgen.AGENTS:
                scope = a / agent
                logs = list(scope.rglob("*.jsonl"))
                report = manifest["agents"][agent]
                self.assertEqual(len(logs), 2)
                self.assertEqual(report["records"], 72)
                self.assertEqual(report["rawBytes"], sum(p.stat().st_size for p in scope.rglob("*") if p.is_file()))
                self.assertEqual(tuple(report["expectedTokens"][k] for k in synthgen.COUNTS), expected[agent])
                for log in logs:
                    lines = log.read_bytes().splitlines()
                    self.assertEqual(len(lines), 36)
                    self.assertGreater(max(map(len, lines)), 2048)
                    records = [json.loads(line) for line in lines]
                    if agent == "claude_code":
                        self.assertEqual(log.parts[-3], "projects")
                        self.assertEqual(records[3]["message"]["id"], records[4]["message"]["id"])
                    elif agent == "codex":
                        self.assertEqual(records[0]["type"], "session_meta")
                        self.assertTrue(log.name.endswith("-" + records[0]["payload"]["id"] + ".jsonl"))
                        self.assertEqual(records[1]["type"], "turn_context")
                        self.assertEqual(records[6]["payload"]["info"]["last_token_usage"]["total_tokens"], 51)
                    elif agent == "copilot":
                        self.assertEqual(records[0]["type"], "session.start")
                        self.assertEqual(records[0]["data"]["sessionId"], log.parent.name)
                        self.assertEqual(len({record["id"] for record in records}), len(records))
                    else:
                        self.assertEqual(log.name, "updates.jsonl")
                        self.assertEqual(records[0]["params"]["sessionId"], log.parent.name)
                        self.assertTrue(all(log.with_name(name).is_file()
                                            for name in ("summary.json", "signals.json", "plan.json")))

    def test_declared_benchmark_layout_and_preflight(self):
        profile = synthgen.PROFILES["benchmark"]
        layout = synthgen.session_layout(profile, 27)
        self.assertEqual((len(layout), sum(item.records for item in layout), profile.raw_bytes),
                         (2_000, 1_000_000, 5_000_000_000))
        for agent in synthgen.AGENTS:
            self.assertEqual(sum(item.agent == agent for item in layout), 500)
        with self.assertRaises(synthgen.CorpusError):
            synthgen.plan(synthgen.Profile(4, 32, 1), 0, "impossible")

    def test_native_benchmark_counts_only_importable_sources(self):
        native = synthgen.PROFILES["benchmark-native"]
        layout = synthgen.session_layout(native, 27)
        self.assertEqual((len(layout), sum(item.records for item in layout), native.raw_bytes),
                         (2_000, 1_000_000, 5_000_000_000))
        self.assertEqual([sum(item.agent == agent for item in layout) for agent in
                          ("claude_code", "codex", "copilot", "grok_build")], [667, 667, 666, 0])
        with tempfile.TemporaryDirectory() as scratch:
            small = synthgen.Profile(6, 216, 1_000_000, native.agents)
            output = synthgen.generate(synthgen.plan(small, 27, "native-test"), Path(scratch), [])
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertEqual(set(manifest["agents"]), {"claude_code", "codex", "copilot"})
            self.assertFalse((output / "grok_build").exists())
            self.assertEqual(sum(p.stat().st_size for p in output.rglob("*.jsonl")), 1_000_000)

    def test_protects_registered_source_and_protected_names(self):
        with tempfile.TemporaryDirectory() as scratch:
            parent = Path(scratch).resolve()
            index = parent / "synthetic-index.sqlite"
            with sqlite3.connect(index) as db:
                db.executescript("""CREATE TABLE grdb_migrations(identifier TEXT);
                    INSERT INTO grdb_migrations VALUES('v1');
                    CREATE TABLE sources(root_path TEXT NOT NULL);
                    CREATE TABLE sessions(private_text TEXT);
                    INSERT INTO sessions VALUES('synthetic ignored');""")
                db.execute("INSERT INTO sources VALUES(?)", (str(parent),))
            before = index.read_bytes()
            roots = synthgen.registered_roots(index)
            self.assertEqual(roots, [parent])
            with self.assertRaises(synthgen.CorpusError):
                synthgen.new_output(parent, roots, 100)
            protected = parent / ".CoDeX"
            protected.mkdir()
            with self.assertRaises(synthgen.CorpusError):
                synthgen.new_output(protected, [], 100)
            self.assertEqual(index.read_bytes(), before)
            self.assertEqual(set(parent.iterdir()), {index, protected})
            self.assertEqual(list(protected.iterdir()), [])

    @unittest.skipUnless(sys.platform == "darwin", "needs a macOS firmlink")
    def test_refuses_real_firmlink_alias_before_mkdir(self):
        parent = Path("/private/tmp")
        aliases = [Path("/System/Volumes/Data/private/tmp"), Path("/System/Volumes/Data")]
        if not aliases[0].is_dir() or not parent.samefile(aliases[0]):
            self.skipTest("temporary directory has no Data volume alias")
        for root in aliases:
            with self.subTest(root=root), patch.object(Path, "mkdir") as mkdir:
                # The real directory is only stat'ed. Never try to create a
                # corpus here, even if the overlap check regresses.
                with self.assertRaises(synthgen.CorpusError):
                    synthgen.new_output(parent, [root], 100)
                mkdir.assert_not_called()

    def test_refuses_aliased_ancestor_and_unresolvable_source(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            source = root / "source"
            parent = source / "staging"
            parent.mkdir(parents=True)
            alias = root / "alias"
            alias.symlink_to(source, target_is_directory=True)
            dangling = root / "dangling"
            dangling.symlink_to(root / "absent", target_is_directory=True)
            for registered in [alias, dangling / "child"]:
                with self.assertRaises(synthgen.CorpusError):
                    synthgen.new_output(parent, [registered], 100)
                self.assertEqual(list(parent.iterdir()), [])

    def test_avoids_creating_parent_of_missing_source_via_alias(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            parent = root / "staging"
            parent.mkdir()
            alias = root / "alias"
            alias.symlink_to(parent, target_is_directory=True)
            reserved, safe = UUID(int=1), UUID(int=2)
            registered = alias / ("agentdash-synth-" + reserved.hex) / "missing"
            with patch.object(synthgen.uuid, "uuid4", side_effect=[reserved, safe]):
                output = synthgen.new_output(parent, [registered], 100)
            self.assertEqual(output.name, "agentdash-synth-" + safe.hex)
            self.assertFalse(registered.parent.exists())


if __name__ == "__main__":
    unittest.main()
