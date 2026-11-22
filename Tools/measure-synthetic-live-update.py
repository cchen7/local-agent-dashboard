#!/usr/bin/env python3
"""Measure NFR-2 with signed SyntheticQA and external synthetic JSONL writes."""

import argparse
import os
from pathlib import Path
import select
import statistics
import subprocess
import time
from uuid import uuid4


AGENTS = ("claude_code", "codex", "copilot")
PREFIX = b"synthetic-live-update: "


class Markers:
    def __init__(self, pipe):
        self.pipe = pipe
        self.pending = b""

    def expect(self, *events, timeout=10):
        expected = {event.encode() for event in events}
        deadline = time.monotonic() + timeout
        while expected:
            if b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                if not line.startswith(PREFIX):
                    continue
                event = line[len(PREFIX):]
                if event not in expected:
                    raise RuntimeError(f"Unexpected live-update marker: {event.decode()}")
                expected.remove(event)
                continue
            left = max(0, deadline - time.monotonic())
            ready, _, _ = select.select([self.pipe], [], [], left)
            if not ready:
                break
            block = os.read(self.pipe.fileno(), 4096)
            if not block:
                break
            self.pending += block
            if len(self.pending) > 16_384:
                raise RuntimeError("Unexpected output from the synthetic process")
        if expected:
            raise RuntimeError(f"Missing live-update marker: {sorted(event.decode() for event in expected)}")


def command(writer, name):
    writer.stdin.write(name + b"\n")
    writer.stdin.flush()


def stop(child):
    child.terminate()
    try:
        child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def measure(executable, agent):
    env = {key: value for key, value in os.environ.items() if not key.startswith("AGENTDASH_")}
    env["AGENTDASH_SYNTHETIC_LIVE_UPDATE"] = f"{agent}:{uuid4()}"
    launch = [str(executable), "--synthetic"]
    # A sibling process shares the QA container, but never sets up AppKit
    # or an index. Only that process owns and writes the synthetic files.
    with subprocess.Popen(
        launch + ["--synthetic-live-update-writer"], env=env,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    ) as writer:
        try:
            written = Markers(writer.stdout)
            command(writer, b"prepare")
            written.expect("writer prepared")
            with subprocess.Popen(
                launch + ["--window-size", "1120x720", "--appearance", "dark"],
                env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            ) as child:
                try:
                    drawn = Markers(child.stdout)
                    drawn.expect("watching", "baseline row drawn")
                    begin = time.monotonic_ns()
                    command(writer, b"append")
                    written.expect("writer appended")
                    drawn.expect("appended row drawn")
                    append_ms = (time.monotonic_ns() - begin) / 1_000_000

                    begin = time.monotonic_ns()
                    command(writer, b"create")
                    written.expect("writer created")
                    drawn.expect("created row drawn")
                    create_ms = (time.monotonic_ns() - begin) / 1_000_000
                finally:
                    stop(child)
            command(writer, b"finish")
            if writer.wait(timeout=3) != 0:
                raise RuntimeError("Synthetic fixture writer did not exit cleanly")
            return append_ms, create_ms
        finally:
            writer.stdin.close()
            try:
                writer.wait(timeout=3)
            except subprocess.TimeoutExpired:
                stop(writer)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="path to the signed SyntheticQA bundle")
    parser.add_argument("--agent", choices=AGENTS, action="append", help="repeat to measure a subset")
    parser.add_argument("--runs", type=int, choices=range(1, 11), default=5, metavar="1–10")
    args = parser.parse_args()
    existing = subprocess.run(["/usr/bin/pgrep", "-x", "AgentDashboard"], stdout=subprocess.DEVNULL)
    if existing.returncode != 1:
        parser.error("an Agent Dashboard process is running or process status is unavailable")
    app = args.app.resolve(strict=True)
    verifier = Path(__file__).resolve().with_name("check-synthetic-launch.sh")
    subprocess.run([str(verifier), str(app)], check=True)
    executable = app / "Contents/MacOS/AgentDashboard"
    passed = True
    for agent in args.agent or AGENTS:
        readings = []
        for run in range(args.runs):
            appended, created = measure(executable, agent)
            readings.append((appended, created))
            print(f"{agent} {run + 1}: append {appended:.1f} ms, create {created:.1f} ms", flush=True)
        for name, values in zip(("append", "create"), zip(*readings)):
            print(f"{agent} {name}: median {statistics.median(values):.1f} ms; slowest {max(values):.1f} ms")
            passed = passed and max(values) <= 2000
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
