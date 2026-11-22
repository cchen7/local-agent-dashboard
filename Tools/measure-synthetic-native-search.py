#!/usr/bin/env python3
"""Measure native search and result paging in the signed SyntheticQA app."""

import argparse
import json
import math
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import sys
import time
from uuid import UUID, uuid4


PREFIX = b"synthetic-search: "
SCENARIOS = ("mixed", "chinese", "broad", "next-page", "directory")
RESULT = re.compile(
    rb"drawn (mixed|chinese|broad|next-page|directory) total ([0-9.]+) ms, adjusted ([0-9.]+) ms,"
    rb" debounce ([0-9.]+) ms, query ([0-9.]+) ms, draw ([0-9.]+) ms"
)


def checked_source(identifier):
    root = Path("/private/tmp") / f"agentdash-search-fixture-{str(identifier).upper()}"
    folder = root.lstat()
    metadata = root / "proof.json"
    receipt = metadata.lstat()
    index = root / "index.sqlite"
    binary = index.lstat()
    if not (stat.S_ISDIR(folder.st_mode) and folder.st_uid == os.getuid()
            and stat.S_IMODE(folder.st_mode) == 0o700 and stat.S_ISREG(receipt.st_mode)
            and 0 < receipt.st_size <= 1024 and stat.S_ISREG(binary.st_mode)):
        raise RuntimeError("Expected an owned synthetic search export")
    raw = metadata.read_text(encoding="utf-8")
    proof = json.loads(raw)
    if proof != {"bytes": binary.st_size, "events": 1_000_000, "sessions": 2_000}:
        raise RuntimeError("Synthetic export proof and index disagree")
    return index, raw


def environment(identifier, mode, cycles=1, proof=None):
    result = {key: value for key, value in os.environ.items() if not key.startswith("AGENTDASH_")}
    result["AGENTDASH_SYNTHETIC_NATIVE_SEARCH"] = f"{mode}:{identifier}"
    result["AGENTDASH_SYNTHETIC_SEARCH_CYCLES"] = str(cycles)
    if proof is not None:
        result["AGENTDASH_SYNTHETIC_SEARCH_PROOF"] = proof
    return result


def install(executable, identifier, source, proof):
    with subprocess.Popen(
        [str(executable), "--synthetic", "--synthetic-native-search-fixture"],
        env=environment(identifier, "install", proof=proof), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    ) as child:
        try:
            descriptor = child.stdin.fileno()
            os.set_blocking(descriptor, False)
            deadline = time.monotonic() + 30
            with source.open("rb") as data:
                while block := data.read(262_144):
                    remaining = memoryview(block)
                    while remaining:
                        budget = deadline - time.monotonic()
                        if budget <= 0 or not select.select([], [descriptor], [], budget)[1]:
                            raise RuntimeError("Timed out transferring the generated index")
                        try:
                            remaining = remaining[os.write(descriptor, remaining):]
                        except BlockingIOError:
                            continue
        except BrokenPipeError:
            pass
        except (OSError, RuntimeError):
            child.kill()
            child.wait()
            raise
        finally:
            child.stdin.close()
            child.stdin = None
        try:
            output, _ = child.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            raise
        if child.returncode or PREFIX + b"installed 1000000 search events" not in output.splitlines():
            raise RuntimeError(f"Signed install did not verify the fixture (status {child.returncode})")


def measure(executable, identifier, cycles):
    with subprocess.Popen(
        [str(executable), "--synthetic", "--window-size", "1120x720", "--appearance", "dark"],
        env=environment(identifier, "measure", cycles), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    ) as child:
        try:
            return read_measurements(child, cycles)
        finally:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def read_measurements(child, cycles):
    data = {scenario: [] for scenario in SCENARIOS}
    expected = iter(SCENARIOS * cycles)
    ready = False
    refreshed = False
    pending = b""
    deadline = time.monotonic() + 20
    while child.poll() is None and time.monotonic() < deadline:
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
            if marker == b"ready 2000 sessions" and not ready:
                ready = True
                deadline = time.monotonic() + 8
                continue
            if (marker == b"refreshed offset 50 matches 100001" and ready and not refreshed
                    and len(data["next-page"]) == cycles and len(data["directory"]) == cycles - 1):
                refreshed = True
                print(marker.decode(), flush=True)
                deadline = time.monotonic() + 8
                continue
            if marker == b"done" and ready and refreshed and all(len(v) == cycles for v in data.values()):
                return data
            match = RESULT.fullmatch(marker)
            if not ready or not match:
                raise RuntimeError(f"Unexpected native search result: {marker.decode()}")
            scenario = match[1].decode()
            if scenario != next(expected, None):
                raise RuntimeError("Native search sequence disagrees with the driver")
            sample = tuple(float(match[i]) for i in range(2, 7))
            if (scenario == "next-page" and sample[2] != 0) or (scenario != "next-page" and sample[2] < 149):
                raise RuntimeError("Search debounce did not match the production path")
            data[scenario].append(sample)
            print(marker.decode(), flush=True)
            deadline = time.monotonic() + 8
        if len(pending) > 16_384:
            raise RuntimeError("Unexpected output from the synthetic app")
    raise RuntimeError(f"Native search did not finish ({sum(map(len, data.values()))} draws)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="signed optimized SyntheticQA bundle")
    parser.add_argument("--export", required=True, type=UUID)
    parser.add_argument("--cycles", type=int, choices=range(1, 21), metavar="1–20", default=20)
    args = parser.parse_args()
    running = subprocess.run(["/usr/bin/pgrep", "-x", "AgentDashboard"], stdout=subprocess.DEVNULL)
    if running.returncode != 1:
        parser.error("an Agent Dashboard process is running or process status is unavailable")
    source, proof = checked_source(args.export)
    app = args.app.resolve(strict=True)
    subprocess.run([str(Path(__file__).resolve().with_name("check-synthetic-launch.sh")), str(app)], check=True)
    executable = app / "Contents/MacOS/AgentDashboard"
    identifier = uuid4()
    install(executable, identifier, source, proof)
    try:
        results = measure(executable, identifier, args.cycles)
        passed = True
        for scenario, samples in results.items():
            rank = math.ceil(len(samples) * 0.95) - 1
            total, adjusted, debounce, query, draw = (sorted(column)[rank] for column in zip(*samples))
            print(f"{scenario}: P95 total {total:.1f}, adjusted {adjusted:.1f}, debounce {debounce:.1f}, "
                  f"query {query:.1f}, draw {draw:.1f} ms", flush=True)
            passed = adjusted < 150 and passed
        return 0 if passed else 1
    finally:
        subprocess.run([str(executable), "--synthetic", "--synthetic-native-search-fixture"],
                       env=environment(identifier, "cleanup"), stdin=subprocess.DEVNULL,
                       timeout=10, check=True)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"measure-synthetic-native-search: {error}", file=sys.stderr)
        raise SystemExit(2)
