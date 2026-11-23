#!/usr/bin/env python3
"""Measure selection-to-chart display for NFR-5 on signed SyntheticQA."""

import argparse
import math
import os
from pathlib import Path
import re
import select
import subprocess
import sys
import time
from uuid import UUID, uuid4


PREFIX = b"synthetic-period: "
DRAWN = re.compile(rb"drawn (tokens|cost) (hour|week|month|quarter|all|custom|day) ([0-9]+\.[0-9]+) ms,"
                   rb" ([1-9][0-9]*) rows, query ([0-9]+\.[0-9]+) ms, plot ([0-9]+\.[0-9]+) ms")
PERIODS = ("hour", "week", "month", "quarter", "all", "custom", "day")


def fixture_env(identity, mode, cycles):
    result = {key: value for key, value in os.environ.items() if not key.startswith("AGENTDASH_")}
    result["AGENTDASH_SYNTHETIC_USAGE_PERIOD"] = f"{mode}:{identity}"
    result["AGENTDASH_SYNTHETIC_PERIOD_CYCLES"] = str(cycles)
    return result


def fixture_command(executable, identity, mode, timeout):
    result = subprocess.run(
        [str(executable), "--synthetic", "--synthetic-period-fixture"],
        env=fixture_env(identity, mode, 1), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Signed QA {mode} exited with status {result.returncode}")
    if mode == "prepare" and PREFIX + b"prepared 1000000 token rows" not in result.stdout.splitlines():
        raise RuntimeError("The fixture did not verify a million stored token rows")


def read_measurements(child, metric, cycles):
    pending = b""
    measurements = {period: [] for period in PERIODS}
    ready_marker = f"ready {metric}".encode()
    order = iter(PERIODS * cycles)
    ready = False
    deadline = time.monotonic() + 12 + cycles * 9
    while time.monotonic() < deadline and child.poll() is None:
        available, _, _ = select.select([child.stdout], [], [], min(1, max(0, deadline - time.monotonic())))
        if not available:
            continue
        block = os.read(child.stdout.fileno(), 4096)
        if not block:
            break
        pending += block
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            if not line.startswith(PREFIX):
                continue
            marker = line[len(PREFIX):]
            if marker == ready_marker and not ready:
                ready = True
                continue
            if marker == b"done" and ready and next(order, None) is None:
                if all(len(samples) == cycles for samples in measurements.values()):
                    return measurements
                break
            match = DRAWN.fullmatch(marker)
            if not ready or not match:
                raise RuntimeError(f"Unexpected native period result: {marker.decode()}")
            measured_metric, period, elapsed, _, _, _ = (part.decode() for part in match.groups())
            if measured_metric != metric or period != next(order, None):
                raise RuntimeError(f"Unexpected period/metric: {marker.decode()}")
            measurements[period].append(float(elapsed))
            print(marker.decode(), flush=True)
        if len(pending) > 16_384:
            raise RuntimeError("Unexpected output from the synthetic app")
    raise RuntimeError(f"Missing native chart draw for the {metric} period sequence")


def measure(executable, identity, metric, cycles):
    with subprocess.Popen(
        [str(executable), "--synthetic", "--window-size", "1120x720", "--appearance", "dark"],
        env=fixture_env(identity, metric, cycles), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    ) as child:
        try:
            return read_measurements(child, metric, cycles)
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
    parser.add_argument("--cycles", type=int, choices=range(1, 11), default=3, metavar="1–10")
    parser.add_argument("--metric", action="append", choices=("tokens", "cost"), help="default: both")
    parser.add_argument("--fixture", type=UUID, help="reuse an owned fixture retained by an earlier run")
    parser.add_argument("--keep-fixture", action="store_true", help="retain the fixture for a controlled comparison")
    args = parser.parse_args()
    existing = subprocess.run(["/usr/bin/pgrep", "-x", "AgentDashboard"], stdout=subprocess.DEVNULL)
    if existing.returncode != 1:
        parser.error("an Agent Dashboard process is running or process status is unavailable")
    app = args.app.resolve(strict=True)
    subprocess.run([str(Path(__file__).resolve().with_name("check-synthetic-launch.sh")), str(app)], check=True)
    executable = app / "Contents/MacOS/AgentDashboard"
    identity = args.fixture or uuid4()
    prepared = args.fixture is not None
    try:
        if not prepared:
            print("Preparing and verifying 1,000,000 indexed token rows. Preparation is outside timing.", flush=True)
            fixture_command(executable, identity, "prepare", timeout=360)
            prepared = True
            print("Verified 1,000,000 indexed token rows with stored quotes.", flush=True)
        print(f"Fixture {identity}", flush=True)
        passed = True
        for metric in args.metric or ("tokens", "cost"):
            samples = measure(executable, identity, metric, args.cycles)
            slowest = max(max(values) for values in samples.values())
            all_values = sorted(value for values in samples.values() for value in values)
            p95 = all_values[math.ceil(len(all_values) * 0.95) - 1]
            print(f"{metric}: {len(all_values)} transitions; P95 {p95:.1f} ms; slowest {slowest:.1f} ms.",
                  flush=True)
            passed = (slowest < 100) and passed
        return 0 if passed else 1
    finally:
        if prepared and not args.keep_fixture:
            fixture_command(executable, identity, "cleanup", timeout=10)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"measure-synthetic-usage-period: {error}", file=sys.stderr)
        raise SystemExit(2)
