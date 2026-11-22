#!/usr/bin/env python3
"""Measure NFR-1 on a signed SyntheticQA app with an already prepared index."""

import argparse
import os
from pathlib import Path
import select
import statistics
import subprocess
import time
from uuid import uuid4


def launch(executable, fixture_request, expected):
    env = {key: value for key, value in os.environ.items() if not key.startswith("AGENTDASH_")}
    env["AGENTDASH_SYNTHETIC_STARTUP"] = fixture_request
    marker = f"synthetic-startup: {expected}".encode()
    started = time.monotonic()
    with subprocess.Popen(
        [str(executable), "--synthetic", "--window-size", "1120x720", "--appearance", "dark"],
        env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    ) as child:
        try:
            assert child.stdout is not None
            pending = b""
            deadline = started + 15
            while time.monotonic() < deadline:
                ready, _, _ = select.select([child.stdout], [], [], max(0, deadline - time.monotonic()))
                if not ready:
                    break
                data = os.read(child.stdout.fileno(), 4096)
                if not data:
                    break
                pending += data
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    if line == marker:
                        return (time.monotonic() - started) * 1000
                    if line.startswith(b"synthetic-startup: "):
                        raise RuntimeError(f"Unexpected startup result: {line.decode()}")
            raise RuntimeError(f"No {expected} marker before exit or within 15 seconds")
        finally:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="path to the signed SyntheticQA bundle")
    parser.add_argument("--runs", type=int, choices=range(1, 16), default=7, metavar="1–15")
    args = parser.parse_args()

    existing = subprocess.run(["/usr/bin/pgrep", "-x", "AgentDashboard"], stdout=subprocess.DEVNULL)
    if existing.returncode != 1:
        parser.error("an Agent Dashboard process is running or process status is unavailable")
    app = args.app.resolve(strict=True)
    verifier = Path(__file__).resolve().with_name("check-synthetic-launch.sh")
    subprocess.run([str(verifier), str(app)], check=True)
    executable = app / "Contents/MacOS/AgentDashboard"
    fixture_id = uuid4()
    launch(executable, f"reopen:{fixture_id}", "fixture unavailable")
    launch(executable, f"reopen:{uuid4()}/index.sqlite", "fixture unavailable")
    launch(executable, f"prepare:{fixture_id}", "prepared row drawn")
    launch(executable, f"prepare:{fixture_id}", "fixture unavailable")
    print("Prepared 1,000 sessions / 10,000 events; excluded fixture creation from timing.", flush=True)

    readings = []
    for run in range(args.runs):
        elapsed = launch(executable, f"reopen:{fixture_id}", "reopened row drawn")
        readings.append(elapsed)
        print(f"Launch {run + 1}: {elapsed:.1f} ms", flush=True)
    print(f"Median {statistics.median(readings):.1f} ms; slowest {max(readings):.1f} ms.")
    return 0 if max(readings) < 1000 else 1


if __name__ == "__main__":
    raise SystemExit(main())
