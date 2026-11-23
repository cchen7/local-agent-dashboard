#!/usr/bin/env python3
"""Measure NFR-9 in a signed, optimized SyntheticQA window."""

import argparse
import os
from pathlib import Path
import re
import select
import statistics
import subprocess
import sys
import tempfile
import time
from uuid import uuid4

sys.dont_write_bytecode = True
from synthgen import FAKE_PAYLOAD, encode, transcript_text


PREFIX = b"synthetic-long-transcript: "
NUMBER = rb"([0-9]+\.[0-9]+)"
PATTERNS = (
    re.compile(rb"first-screen " + NUMBER + rb" ms, 128 rows"),
    re.compile(rb"scroll " + NUMBER + rb" updates/s, ([0-9]+) moves, ([0-9]+) drawn probes, "
               rb"([0-9]+) pt, " + NUMBER + rb" ms P95, ([0-9]+) gaps, ([0-9]+) late"),
    re.compile(rb"next-screen " + NUMBER + rb" ms, 128 rows"),
)


def fixture_env(identity, mode):
    result = {key: value for key, value in os.environ.items() if not key.startswith("AGENTDASH_")}
    result["AGENTDASH_SYNTHETIC_LONG_TRANSCRIPT"] = f"{mode}:{identity}"
    return result


def prepare(executable, identity):
    with tempfile.TemporaryFile() as payload:
        for batch in range(50):
            messages = [message for turn in range(500) for message in transcript_text(27, batch, turn)]
            for index in range(0, len(messages), 8):
                messages[index] += "\n\n" + FAKE_PAYLOAD * 5
            payload.write(encode(messages))
        payload.seek(0)
        output = subprocess.run(
            [str(executable), "--synthetic", "--synthetic-long-transcript-fixture"],
            env=fixture_env(identity, "prepare"), stdin=payload, stdout=subprocess.PIPE, timeout=90, check=True,
        ).stdout
    if PREFIX + b"prepared 50000 messages" not in output.splitlines():
        raise RuntimeError("The fixture did not verify 50,000 stored messages")


def read_measurements(child):
    pending = b""
    findings = []
    deadline = time.monotonic() + 25
    while len(findings) < len(PATTERNS) and time.monotonic() < deadline and child.poll() is None:
        ready, _, _ = select.select([child.stdout], [], [], min(1, max(0, deadline - time.monotonic())))
        if not ready:
            continue
        block = os.read(child.stdout.fileno(), 4096)
        if not block:
            break
        pending += block
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            if not line.startswith(PREFIX):
                continue
            if len(findings) >= len(PATTERNS):
                raise RuntimeError("An extra transcript result was emitted")
            marker = line[len(PREFIX):]
            match = PATTERNS[len(findings)].fullmatch(marker)
            if not match:
                raise RuntimeError(f"Unexpected native transcript result: {marker.decode()}")
            print(marker.decode(), flush=True)
            findings.append(match.groups())
        if len(pending) > 16_384:
            raise RuntimeError("Unexpected output from the synthetic app")
    if len(findings) != len(PATTERNS):
        raise RuntimeError("Missing a first-screen, native scroll or next-screen result")
    return findings


def measure(executable, identity):
    with subprocess.Popen(
        [str(executable), "--synthetic", "--window-size", "1120x720", "--appearance", "dark"],
        env=fixture_env(identity, "measure"), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    ) as child:
        try:
            return read_measurements(child)
        finally:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="path to the signed, optimized SyntheticQA bundle")
    parser.add_argument("--runs", type=int, choices=range(1, 11), default=5, metavar="1–10")
    args = parser.parse_args()
    existing = subprocess.run(["/usr/bin/pgrep", "-x", "AgentDashboard"], stdout=subprocess.DEVNULL)
    if existing.returncode != 1:
        parser.error("an Agent Dashboard process is running or process status is unavailable")
    app = args.app.resolve(strict=True)
    subprocess.run([str(Path(__file__).resolve().with_name("check-synthetic-launch.sh")), str(app)], check=True)
    executable = app / "Contents/MacOS/AgentDashboard"
    identity = uuid4()
    prepared = False
    try:
        prepare(executable, identity)
        prepared = True
        print("Verified 50,000 messages; excluded fixture generation and initial window launch.", flush=True)
        first_screens, next_screens, rates, work = [], [], [], []
        for run in range(1, args.runs + 1):
            print(f"Run {run}:", flush=True)
            first, scroll, following = measure(executable, identity)
            first_screens.append(float(first[0]))
            next_screens.append(float(following[0]))
            rates.append(float(scroll[0]))
            work.append(float(scroll[4]))
        print(f"First screen median {statistics.median(first_screens):.1f} ms, slowest {max(first_screens):.1f} ms; "
              f"next screen slowest {max(next_screens):.1f} ms.", flush=True)
        print(f"Scroll minimum {min(rates):.2f} native updates/s; largest frame-work P95 {max(work):.2f} ms.",
              flush=True)
        # A nominal 60 Hz display can deliver 59.94 Hz, and the measured
        # interval has a partial first and last frame.
        return 0 if max(first_screens) < 300 and min(rates) >= 59.4 and max(work) < 1000 / 60 else 1
    finally:
        if prepared:
            subprocess.run(
                [str(executable), "--synthetic", "--synthetic-long-transcript-fixture"],
                env=fixture_env(identity, "cleanup"), stdin=subprocess.DEVNULL, timeout=10, check=True,
            )


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"measure-synthetic-transcript: {error}", file=sys.stderr)
        raise SystemExit(2)
