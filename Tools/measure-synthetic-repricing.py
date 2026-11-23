#!/usr/bin/env python3
"""Measure the signed app’s real price-file watcher, backfill and in-flight navigation."""

import argparse
import json
import os
from pathlib import Path
import re
import select
import stat
import subprocess
import sys
import time
from uuid import UUID, uuid4


PREFIX = b"synthetic-reprice: "


def checked_source(identifier):
    root = Path("/private/tmp") / f"agentdash-reprice-fixture-{str(identifier).upper()}"
    directory = root.lstat()
    manifest = root / "proof.json"
    metadata = manifest.lstat()
    index = root / "index.sqlite"
    binary = index.lstat()
    if not (stat.S_ISDIR(directory.st_mode) and directory.st_uid == os.getuid()
            and stat.S_IMODE(directory.st_mode) == 0o700
            and stat.S_ISREG(metadata.st_mode) and 0 < metadata.st_size <= 1024
            and stat.S_ISREG(binary.st_mode)):
        raise RuntimeError("Expected a private generated fixture, not an arbitrary index")
    proof = manifest.read_text(encoding="utf-8")
    values = json.loads(proof)
    if values.get("bytes") != binary.st_size or values.get("records") != 1_000_001:
        raise RuntimeError("The generated fixture proof and SQLite file disagree")
    return index, proof


def environment(identity, mode, proof=None):
    result = {key: value for key, value in os.environ.items() if not key.startswith("AGENTDASH_")}
    result["AGENTDASH_SYNTHETIC_REPRICE"] = f"{mode}:{identity}"
    if proof is not None:
        result["AGENTDASH_SYNTHETIC_REPRICE_PROOF"] = proof
    return result


def fixture_command(executable, identity, mode):
    done = subprocess.run(
        [str(executable), "--synthetic", "--synthetic-reprice-fixture"],
        env=environment(identity, mode), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, timeout=30,
    )
    if done.returncode != 0:
        raise RuntimeError(f"Signed {mode} command exited with status {done.returncode}")
    return [line[len(PREFIX):] for line in done.stdout.splitlines() if line.startswith(PREFIX)]


def install_fixture(executable, identity, source, proof):
    # Transfer through a pipe; a sandboxed process need not be able to
    # read an inherited descriptor pointing outside its QA container.
    with subprocess.Popen(
        [str(executable), "--synthetic", "--synthetic-reprice-fixture"],
        env=environment(identity, "install", proof), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    ) as child:
        try:
            descriptor = child.stdin.fileno()
            os.set_blocking(descriptor, False)
            deadline = time.monotonic() + 30
            with source.open("rb") as data:
                while block := data.read(262_144):
                    remainder = memoryview(block)
                    while remainder:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0 or not select.select([], [descriptor], [], remaining)[1]:
                            raise RuntimeError("Timed out transferring the verified fixture")
                        try:
                            remainder = remainder[os.write(descriptor, remainder):]
                        except BlockingIOError:
                            continue
        except BrokenPipeError:
            pass  # Read the guarded app's failure below.
        except (OSError, RuntimeError):
            child.kill()
            child.wait()
            raise
        finally:
            child.stdin.close()
            child.stdin = None
        try:
            stdout, _ = child.communicate(timeout=30)
        except subprocess.TimeoutExpired:
            child.kill()
            child.communicate()
            raise
        if child.returncode != 0 or PREFIX + b"installed 1000000 eligible rows" not in stdout.splitlines():
            detail = ", ".join(line[len(PREFIX):].decode() for line in stdout.splitlines() if line.startswith(PREFIX))
            raise RuntimeError(f"The signed app did not verify the transferred fixture ({child.returncode}): {detail}")


class Markers:
    def __init__(self, child):
        self.child = child
        self.pending = b""

    def next(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and self.child.poll() is None:
            if b"\n" not in self.pending:
                ready, _, _ = select.select([self.child.stdout], [], [], min(1, max(0, deadline - time.monotonic())))
                if not ready:
                    continue
                block = os.read(self.child.stdout.fileno(), 4096)
                if not block:
                    break
                self.pending += block
                if len(self.pending) > 16_384:
                    raise RuntimeError("Unexpected output from the QA app")
            while b"\n" in self.pending:
                line, self.pending = self.pending.split(b"\n", 1)
                if line.startswith(PREFIX):
                    value = line[len(PREFIX):].decode()
                    if re.fullmatch(r"progress [0-9]+|chart pending [0-9]+ unpriced, [0-9]+ microdollars", value):
                        print(value, flush=True)
                    else:
                        return value
        raise RuntimeError("Timed out waiting for an actual App repricing result")

    def expect(self, pattern, timeout):
        try:
            value = self.next(timeout)
        except RuntimeError as error:
            raise RuntimeError(f"{error} ({pattern})") from error
        match = re.fullmatch(pattern, value)
        if not match:
            raise RuntimeError(f"Expected {pattern}; received {value}")
        return match.groups()


def run(executable, source, proof):
    identity = uuid4()
    installed = False
    try:
        install_fixture(executable, identity, source, proof)
        installed = True
        with subprocess.Popen(
            [str(executable), "--synthetic", "--window-size", "1120x720", "--appearance", "dark"],
            env=environment(identity, "measure"), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        ) as child:
            try:
                markers = Markers(child)
                markers.expect(r"ready", 20)
                print("Visible baseline verified; live price watcher ready.", flush=True)
                changed = fixture_command(executable, identity, "change")
                match = re.fullmatch(rb"changed ([0-9]+)", changed[0]) if len(changed) == 1 else None
                if match is None:
                    raise RuntimeError("The fixture did not atomically publish the new price file")
                changed_at = int(match[1])
                started_at, = map(int, markers.expect(r"sweep-start ([0-9]+)", 12))
                print(f"App detected price change in {(started_at - changed_at) / 1e6:.1f} ms.", flush=True)
                interactions = []
                for period in ("month", "quarter"):
                    elapsed, = markers.expect(rf"interaction {period} ([0-9]+\.[0-9]+) ms", 12)
                    interactions.append(float(elapsed))
                    print(f"{period} chart drawn during active backfill: {elapsed} ms.", flush=True)
                finished_at, = map(int, markers.expect(r"sweep-done ([0-9]+)", 30))
                swept = (finished_at - started_at) / 1e9
                print(f"App sweep committed in {swept:.3f} s.", flush=True)
                final_at, = map(int, markers.expect(r"final-chart ([0-9]+)", 10))
                if not changed_at <= started_at <= finished_at <= final_at:
                    raise RuntimeError("Repricing timestamps are inconsistent")
                visible = (final_at - changed_at) / 1e9
                print(f"App sweep {swept:.3f} s; price-file change to exact chart {visible:.3f} s; "
                      f"slowest in-flight interaction {max(interactions):.1f} ms.", flush=True)
                return swept < 10 and visible < 10 and max(interactions) < 250
            finally:
                child.terminate()
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
    finally:
        if installed:
            fixture_command(executable, identity, "cleanup")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="path to the signed, optimized SyntheticQA bundle")
    parser.add_argument("--export", type=UUID, required=True, help="ID of a verified Release Package fixture")
    parser.add_argument("--trials", type=int, choices=range(1, 6), default=2)
    args = parser.parse_args()
    existing = subprocess.run(["/usr/bin/pgrep", "-x", "AgentDashboard"], stdout=subprocess.DEVNULL)
    if existing.returncode != 1:
        parser.error("an Agent Dashboard process is running or process status is unavailable")
    source, proof = checked_source(args.export)
    app = args.app.resolve(strict=True)
    subprocess.run([str(Path(__file__).resolve().with_name("check-synthetic-launch.sh")), str(app)], check=True)
    passed = True
    for trial in range(1, args.trials + 1):
        print(f"Trial {trial}:", flush=True)
        passed = run(app / "Contents/MacOS/AgentDashboard", source, proof) and passed
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"measure-synthetic-repricing: {error}", file=sys.stderr)
        raise SystemExit(2)
