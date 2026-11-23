import hashlib
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import stat
import subprocess
import tempfile
import unittest


TOOLS = Path(__file__).resolve().parents[1] / "pricing"
TOOL = os.environ.get("AGENTDASH_PRICING_TOOL")
INSTALL_HARNESS = os.environ.get("AGENTDASH_PRICE_INSTALL_HARNESS")


def rate(date, amount):
    return {
        "effectiveFrom": date,
        "input": amount,
        "output": amount,
        "source": "https://example.invalid/synthetic",
        "checkedAt": "2026-02-01",
    }


def table(entries):
    return json.dumps({
        "schemaVersion": 1,
        "currency": "USD",
        "unit": "per_million_tokens",
        "updatedAt": "2026-02-01",
        "models": [{
            "id": "synthetic-model",
            "vendor": "synthetic",
            "displayName": "Synthetic",
            "prices": entries,
        }],
    }).encode()


class PricingCommandTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.old = self.root / "old.json"
        self.old.write_bytes(table([rate("2026-01-01", 1)]))
        self.candidate = self.root / "candidate.json"
        self.candidate.write_bytes(table([rate("2026-01-01", 1), rate("2026-02-01", 2)]))
        self.snapshot = self.root / "approved-copy.sqlite"
        with closing(sqlite3.connect(self.snapshot)) as db:
            db.executescript("""
                CREATE TABLE grdb_migrations(identifier TEXT);
                INSERT INTO grdb_migrations VALUES ('v11_token_quotes');
                CREATE TABLE token_events(agent TEXT, model TEXT, ts INTEGER, input_fresh INTEGER,
                    cache_read INTEGER, cache_write INTEGER, cache_write_1h INTEGER, output INTEGER,
                    reasoning INTEGER, precision TEXT, cost_micro_usd INTEGER, price_status TEXT);
                CREATE TABLE unrelated_transcripts(text TEXT);
                INSERT INTO unrelated_transcripts VALUES ('synthetic transcript not for pricing');
                INSERT INTO token_events VALUES
                    ('codex','synthetic-model',1769904000000,0,0,0,0,2,0,'call',11,'approx'),
                    ('codex','synthetic-model',1769904000000,0,0,0,0,3,0,'call',0,'unpriced'),
                    ('copilot','sk-synthetic-token-value-hidden-for-audit',1769904000000,0,0,0,0,1,0,'call',0,'unpriced');
                """)

    def call(self, command, *args):
        return subprocess.run([str(TOOLS / command), *map(str, args)], cwd=self.root,
                              capture_output=True, check=False)

    def test_install_requires_explicit_confirmation(self):
        result = self.call("install", self.candidate)
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"--apply", result.stderr)

    @unittest.skipUnless(TOOL, "set AGENTDASH_PRICING_TOOL to the built CLI")
    def test_snapshot_inventory_and_quote_impact_do_not_mutate_snapshot(self):
        before = hashlib.sha256(self.snapshot.read_bytes()).digest()
        report = self.call("validate", self.candidate, "--previous", self.old, "--index-snapshot", self.snapshot)
        self.assertEqual(report.returncode, 0, report.stderr)
        data = json.loads(report.stdout)
        self.assertEqual((data["quoteDeltaMicroUSD"], data["backfillDeltaMicroUSD"]), (5, 6))
        self.assertEqual(data["impact"]["storedMicroUSD"], 11)
        self.assertEqual(data["impact"]["projectedStoredMicroUSD"], 17)
        self.assertEqual(data["impact"]["projectedUnpricedTokens"], 1)
        inventory = self.call("models-seen", self.candidate, "--index-snapshot", self.snapshot)
        self.assertEqual(inventory.returncode, 0, inventory.stderr)
        models = json.loads(inventory.stdout)["models"]
        self.assertEqual([(x["tokens"], x["unpricedTokens"]) for x in models], [(5, 0), (1, 1)])
        self.assertEqual(models[0]["key"]["model"], "synthetic-model")
        self.assertNotIn(b"synthetic-token-value", inventory.stdout)
        self.assertNotIn(b"synthetic transcript", report.stdout + inventory.stdout)
        self.assertEqual(hashlib.sha256(self.snapshot.read_bytes()).digest(), before)
        for suffix in ("-wal", "-shm", "-journal"):
            self.assertFalse(Path(str(self.snapshot) + suffix).exists())

    @unittest.skipUnless(TOOL, "set AGENTDASH_PRICING_TOOL to the built CLI")
    def test_wrappers_resolve_bundled_table_from_a_different_working_directory(self):
        validate = self.call("validate")
        self.assertEqual(validate.returncode, 0, validate.stderr)
        self.assertGreater(json.loads(validate.stdout)["models"], 0)
        inventory = self.call("models-seen", "--index-snapshot", self.snapshot)
        self.assertEqual(inventory.returncode, 0, inventory.stderr)
        self.assertEqual(sum(x["tokens"] for x in json.loads(inventory.stdout)["models"]), 6)

    @unittest.skipUnless(TOOL, "set AGENTDASH_PRICING_TOOL to the built CLI")
    def test_validate_refuses_changed_history_and_live_format(self):
        self.candidate.write_bytes(table([rate("2026-01-01", 9)]))
        result = self.call("validate", self.candidate, "--previous", self.old)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"changedEntry", result.stderr)
        conn = sqlite3.connect(self.snapshot)
        try:
            self.assertEqual(conn.execute("PRAGMA journal_mode=WAL").fetchone()[0], "wal")
        finally:
            conn.close()
        result = self.call("models-seen", self.old, "--index-snapshot", self.snapshot)
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"notStandaloneSnapshot", result.stderr)
        self.assertFalse(Path(str(self.snapshot) + "-shm").exists())

    @unittest.skipUnless(INSTALL_HARNESS, "set AGENTDASH_PRICE_INSTALL_HARNESS to the scratch installer harness")
    def test_installer_preserves_history_and_never_follows_destination_symlink(self):
        directory = self.root / ".config" / "agent-dashboard"
        destination = directory / "pricing.json"

        def install(source):
            return subprocess.run([INSTALL_HARNESS, str(source), str(self.old), str(destination)], check=False)

        self.assertEqual(install(self.old).returncode, 0)
        self.assertEqual(destination.read_bytes(), self.old.read_bytes())
        self.assertEqual(install(self.candidate).returncode, 0)
        self.assertEqual(destination.read_bytes(), self.candidate.read_bytes())
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        self.assertNotEqual(install(self.old).returncode, 0)
        self.assertEqual(destination.read_bytes(), self.candidate.read_bytes())
        self.assertEqual(sorted(x.name for x in directory.iterdir()), ["pricing.json"])
        outside = self.root / "unrelated.json"
        outside.write_bytes(b"synthetic marker")
        destination.unlink()
        destination.symlink_to(outside)
        self.assertNotEqual(install(self.candidate).returncode, 0)
        self.assertTrue(destination.is_symlink())
        self.assertEqual(outside.read_bytes(), b"synthetic marker")
