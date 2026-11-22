#!/usr/bin/env python3
"""Measure NFR-6 and NFR-7 on the signed SyntheticQA app with 1M indexed events."""

import argparse
from contextlib import contextmanager
import ctypes
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
from uuid import uuid4

sys.dont_write_bytecode = True
from synthgen import resource_session_messages


PREFIX = b"synthetic-resources: "


class ProcessUsage(ctypes.Structure):
    """Darwin sys/resource.h, rusage_info_v2 (64-bit fields after the UUID)."""

    _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
        (field, ctypes.c_uint64) for field in (
            "user_ticks system_ticks package_wakeups interrupt_wakeups pageins wired_bytes resident_bytes "
            "footprint_bytes start_time exit_time child_user_ticks child_system_ticks child_package_wakeups "
            "child_interrupt_wakeups child_pageins child_elapsed read_bytes written_bytes"
        ).split()
    ]


class MachTimebase(ctypes.Structure):
    _fields_ = [("numerator", ctypes.c_uint32), ("denominator", ctypes.c_uint32)]


def process_usage_reader():
    pid_usage = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True).proc_pid_rusage
    pid_usage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(ProcessUsage)]
    pid_usage.restype = ctypes.c_int
    get_timebase = ctypes.CDLL(None).mach_timebase_info
    get_timebase.argtypes = [ctypes.POINTER(MachTimebase)]
    get_timebase.restype = ctypes.c_int
    timebase = MachTimebase()
    if get_timebase(ctypes.byref(timebase)) != 0 or not timebase.denominator:
        raise RuntimeError("Could not resolve the CPU accounting timebase")

    def read(pid):
        result = ProcessUsage()
        if pid_usage(pid, 2, ctypes.byref(result)) != 0:  # RUSAGE_INFO_V2
            code = ctypes.get_errno()
            raise OSError(code, os.strerror(code))
        return result

    return read, timebase.numerator / timebase.denominator


def expect(child, expected, timeout):
    pending = b""
    marker = PREFIX + expected.encode()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and child.poll() is None:
        left = min(1, max(0, deadline - time.monotonic()))
        ready, _, _ = select.select([child.stdout], [], [], left)
        if not ready:
            continue
        block = os.read(child.stdout.fileno(), 4096)
        if not block:
            break
        pending += block
        while b"\n" in pending:
            line, pending = pending.split(b"\n", 1)
            if line == marker:
                return
            if line.startswith(PREFIX):
                raise RuntimeError(f"Unexpected QA result: {line.decode()}")
        if len(pending) > 16_384:
            raise RuntimeError("Unexpected output from the synthetic app")
    raise RuntimeError(f"Missing QA readiness marker: {expected}")


def fixture_env(identity, mode):
    result = {key: value for key, value in os.environ.items() if not key.startswith("AGENTDASH_")}
    result["AGENTDASH_SYNTHETIC_RESOURCES"] = f"{mode}:{identity}"
    result["AGENTDASH_SYNTHETIC_TOPICS"] = "1"
    return result


@contextmanager
def launch(executable, identity, mode, stdin=subprocess.DEVNULL):
    with subprocess.Popen(
        [str(executable), "--synthetic", "--synthetic-status", "--window-size", "1120x720", "--appearance", "dark"],
        env=fixture_env(identity, mode), stdin=stdin, stdout=subprocess.PIPE,
    ) as child:
        try:
            yield child
        finally:
            child.terminate()
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def sample(child, duration, read_usage, nanoseconds_per_tick):
    time.sleep(4)  # Leave render/close and startup work outside the measured interval.
    first = read_usage(child.pid)
    start = time.monotonic_ns()
    deadline = start + duration * 1_000_000_000
    peak_footprint = first.footprint_bytes
    peak_rss = first.resident_bytes
    count = 1
    while True:
        remaining = deadline - time.monotonic_ns()
        if remaining > 0:
            time.sleep(min(remaining / 1e9, 0.5))
        if child.poll() is not None:
            raise RuntimeError("QA app exited during sampling")
        last = read_usage(child.pid)
        end = time.monotonic_ns()
        if last.start_time != first.start_time or last.footprint_bytes == 0:
            raise RuntimeError("Process usage snapshot does not match the launched QA app")
        peak_footprint = max(peak_footprint, last.footprint_bytes)
        peak_rss = max(peak_rss, last.resident_bytes)
        count += 1
        if end >= deadline:
            break
    cpu_ticks = last.user_ticks + last.system_ticks - first.user_ticks - first.system_ticks
    cpu_ns = cpu_ticks * nanoseconds_per_tick
    cpu = 100 * cpu_ns / (end - start)
    print(
        f"{count} samples over {(end - start) / 1e9:.2f} s; "
        f"peak footprint {peak_footprint / 1e6:.2f} MB, peak RSS {peak_rss / 1e6:.2f} MB; "
        f"average CPU {cpu:.3f}%; "
        f"I/O delta {last.read_bytes - first.read_bytes} read bytes, "
        f"{last.written_bytes - first.written_bytes} write bytes",
        flush=True,
    )
    return peak_footprint, cpu


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="path to the signed, optimized SyntheticQA bundle")
    parser.add_argument("--seconds", type=int, choices=range(15, 41), default=20, metavar="15–40")
    args = parser.parse_args()
    if sys.platform != "darwin":
        parser.error("this resource budget uses macOS process accounting")
    existing = subprocess.run(["/usr/bin/pgrep", "-x", "AgentDashboard"], stdout=subprocess.DEVNULL)
    if existing.returncode != 1:
        parser.error("an Agent Dashboard process is running or process status is unavailable")
    app = args.app.resolve(strict=True)
    verifier = Path(__file__).resolve().with_name("check-synthetic-launch.sh")
    subprocess.run([str(verifier), str(app)], check=True)
    read_usage, nanoseconds_per_tick = process_usage_reader()
    executable = app / "Contents/MacOS/AgentDashboard"
    identity = uuid4()
    prepared = False
    passed = True
    try:
        print("Preparing and verifying 1,000 sessions / 1,000,000 indexed events.", flush=True)
        with tempfile.TemporaryFile() as corpus:
            for session in range(1_000):
                corpus.write(resource_session_messages(session))
            corpus.seek(0)
            with launch(executable, identity, "prepare", stdin=corpus) as child:
                expect(child, "prepared 1000000 events", timeout=180)
                prepared = True
        print("Verified 1,000,000 stored events. Reopening the same fixture for both readings.", flush=True)
        for mode, maximum in (("dashboard", 400_000_000), ("menu-only", 150_000_000)):
            with launch(executable, identity, mode) as child:
                expect(child, f"{mode} ready", timeout=15)
                print(f"{mode}:", end=" ", flush=True)
                footprint, cpu = sample(child, args.seconds, read_usage, nanoseconds_per_tick)
                passed = (footprint < maximum and cpu < 1) and passed
    finally:
        if prepared:
            subprocess.run(
                [str(executable), "--synthetic", "--synthetic-resource-cleanup"],
                env=fixture_env(identity, "cleanup"), stdin=subprocess.DEVNULL, timeout=10, check=True,
            )
    return 0 if passed else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"measure-synthetic-resources: {error}", file=sys.stderr)
        raise SystemExit(2)
