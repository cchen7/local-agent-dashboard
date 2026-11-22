#!/usr/bin/env python3
"""Reproducible, offline development workloads. Never reads agent data."""

import argparse
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import shutil
import sqlite3
import stat
import sys
import unicodedata
from urllib.parse import quote
import uuid


AGENTS = ("claude_code", "codex", "copilot", "grok_build")
NATIVE_AGENTS = ("claude_code", "codex", "copilot")
COUNTS = ("inputFresh", "cacheRead", "cacheWrite", "cacheWrite1h", "output", "reasoning")
MODEL = dict(zip(AGENTS, ("claude-opus-5-5", "gpt-6.2-sol", "gpt-6.2-sol", "grok-4.7")))
SAMPLE = dict(zip(AGENTS, ((37, 11, 7, 3, 13, 0), (31, 9, 0, 0, 11, 3), (29, 8, 4, 0, 9, 2), (23, 6, 0, 0, 7, 0))))
HEADERS = dict(zip(AGENTS, (0, 2, 1, 0)))
ZERO = (0,) * len(COUNTS)
EPOCH = datetime(2026, 11, 20, tzinfo=timezone.utc)
FAKE_PAYLOAD = "Synthetic build output: module checked; no real command output. "
MAX_PADDING_PER_OUTPUT = 64 * 1024
PROTECTED = {".claude", ".codex", ".copilot", ".grok"}
APP_INDEX = "Library/Containers/com.chenxin.AgentDashboard/Data/Library/Application Support/AgentDashboard/index.sqlite"


class CorpusError(ValueError):
    pass


@dataclass(frozen=True)
class Profile:
    sessions: int
    records: int
    raw_bytes: int
    agents: tuple[str, ...] = AGENTS


PROFILES = {
    "smoke": Profile(8, 288, 1_000_000),
    "benchmark": Profile(2_000, 1_000_000, 5_000_000_000),
    "benchmark-native": Profile(2_000, 1_000_000, 5_000_000_000, NATIVE_AGENTS),
}


@dataclass(frozen=True)
class Session:
    agent: str
    number: int
    seed: int
    records: int

    @property
    def id(self):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, f"agentdash-synth:{self.seed}:{self.agent}:{self.number}"))

    @property
    def cwd(self):
        return f"/synthetic/projects/project-{(self.seed + self.number) % 40:02d}"

    def time(self, seq):
        return EPOCH + timedelta(milliseconds=self.number * 1_000 + seq * 10)

    def log(self, identifier):
        if self.agent == "claude_code":
            return Path("projects") / self.cwd.replace("/", "-") / f"{identifier}.jsonl"
        if self.agent == "codex":
            return Path("sessions/2026/11/20") / f"rollout-2026-11-20T00-00-00-{identifier}.jsonl"
        if self.agent == "copilot":
            return Path("session-state") / identifier / "events.jsonl"
        return Path("sessions") / quote(self.cwd, safe="") / identifier / "updates.jsonl"


def stamp(dt):
    return dt.isoformat(timespec="milliseconds").replace("+00:00", "Z")


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8") + b"\n"


def split(total, count, position):
    step, extra = divmod(total, count)
    return step + (position < extra)


def session_layout(profile, seed):
    agents = profile.agents
    if (not agents or len(set(agents)) != len(agents) or not set(agents).issubset(AGENTS)
            or profile.sessions < len(agents) or profile.records < profile.sessions * 8 or profile.raw_bytes <= 0):
        raise CorpusError("need at least one session per agent and eight records per session")
    return tuple(Session(agents[i % len(agents)], i, seed, split(profile.records, profile.sessions, i))
                 for i in range(profile.sessions))


def is_tool_output(session, seq):
    adjusted = seq - HEADERS[session.agent]
    return adjusted >= 0 and adjusted % 6 == 2


def usage_box(agent, scale=1):
    fresh, read, write, hour, output, reasoning = (v * scale for v in SAMPLE[agent])
    if agent == "claude_code":
        return {"input_tokens": fresh, "cache_read_input_tokens": read, "cache_creation_input_tokens": write + hour,
                "cache_creation": {"ephemeral_5m_input_tokens": write, "ephemeral_1h_input_tokens": hour},
                "output_tokens": output}
    if agent == "codex":
        return {"input_tokens": fresh + read, "cached_input_tokens": read, "output_tokens": output,
                "reasoning_output_tokens": reasoning, "total_tokens": fresh + read + output}
    return {"inputTokens": fresh + read + write, "cacheReadTokens": read, "cacheWriteTokens": write,
            "outputTokens": output, "reasoningTokens": reasoning}


def claude_record(s, sid, seq, stage, turn, timestamp, prompt, reply, call, output):
    base = {"timestamp": timestamp, "uuid": f"{sid}:{seq}", "sessionId": sid, "cwd": s.cwd, "gitBranch": "synthetic"}
    if stage == 5:
        return {**base, "type": "summary", "summary": reply}, ZERO
    if stage in (0, 2):
        content = prompt if stage == 0 else [{"type": "tool_result", "tool_use_id": call, "content": output}]
        return {**base, "type": "user", "message": {"role": "user", "content": content}}, ZERO
    tool = stage == 1
    blocks = [{"type": "tool_use", "id": call, "name": "synthetic_check", "input": {"path": "src/example.swift"}}] if tool else [
        {"type": "text", "text": reply if stage == 3 else "Synthetic companion content block."}]
    response_id = f"{sid}:{turn}:{'tool' if tool else 'reply'}"
    message = {"role": "assistant", "id": response_id, "model": MODEL[s.agent],
               "content": blocks, "usage": usage_box(s.agent)}
    return {**base, "type": "assistant", "message": message}, SAMPLE[s.agent] if stage in (1, 3) else ZERO


def codex_record(s, sid, seq, stage, turn, timestamp, prompt, reply, call, output):
    kind, delta = "event_msg", ZERO
    if seq == 0:
        kind, payload = "session_meta", {"id": sid, "cwd": s.cwd, "originator": "synthetic-cli", "model_provider": "openai"}
    elif seq == 1:
        kind, payload = "turn_context", {"model": MODEL[s.agent], "cwd": s.cwd}
    elif stage == 0:
        payload = {"type": "user_message", "message": prompt}
    elif stage == 1:
        kind = "response_item"
        payload = {"type": "function_call", "name": "synthetic_check", "call_id": call, "arguments": '{"path":"src/example.swift"}'}
    elif stage == 2:
        kind, payload = "response_item", {"type": "function_call_output", "call_id": call, "output": output}
    elif stage == 3:
        payload = {"type": "agent_message", "message": reply}
    elif stage == 4:
        payload = {"type": "token_count", "info": {"last_token_usage": usage_box(s.agent),
                                                   "total_token_usage": usage_box(s.agent, turn + 1)}}
        delta = SAMPLE[s.agent]
    else:
        payload = {"type": "task_complete", "last_agent_message": reply, "duration_ms": 10}
    return {"timestamp": timestamp, "type": kind, "payload": payload}, delta


def copilot_record(s, sid, seq, stage, turn, timestamp, prompt, reply, call, output):
    delta = ZERO
    if seq == 0:
        kind = "session.start"
        data = {"sessionId": sid, "startTime": timestamp, "model": MODEL[s.agent], "context": {"cwd": s.cwd}}
    elif stage == 0:
        kind, data = "user.message", {"content": prompt}
    elif stage == 1:
        kind, data = "tool.execution_start", {"toolName": "synthetic_check", "toolCallId": call, "arguments": {"path": "src/example.swift"}}
    elif stage == 2:
        kind, data = "tool.execution_complete", {"toolCallId": call, "success": True, "result": {"content": output}}
    elif stage == 3:
        kind, data = "assistant.message", {"content": reply}
    elif stage == 4:
        kind, data, delta = "session.usage_record", {"model": MODEL[s.agent], "usage": usage_box(s.agent)}, SAMPLE[s.agent]
    else:
        kind, data = "session.task_complete", {"success": True, "summary": reply}
    return {"type": kind, "data": data, "id": f"{sid}:{seq}", "timestamp": timestamp,
            "parentId": f"{sid}:{seq - 1}" if seq else None}, delta


def grok_record(s, sid, seq, stage, turn, timestamp, prompt, reply, call, output):
    # Spec-shaped ACP sample, not a claim about observed Grok storage fields.
    delta = ZERO
    if stage == 0:
        update = {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": prompt}}
    elif stage == 1:
        update = {"sessionUpdate": "tool_call", "toolCallId": call, "title": "Synthetic check", "status": "in_progress"}
    elif stage == 2:
        update = {"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed",
                  "content": [{"type": "content", "content": {"type": "text", "text": output}}]}
    elif stage in (3, 4):
        update = {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": reply}}
        if stage == 4:
            delta = SAMPLE[s.agent]  # materialized once in the synthetic cumulative signals
    else:
        update = {"sessionUpdate": "plan", "entries": [{"content": "Synthetic check", "priority": "medium", "status": "completed"}]}
    return {"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": update}}, delta


RECORDS = dict(zip(AGENTS, (claude_record, codex_record, copilot_record, grok_record)))


def make_record(session, sid, seq, padding=0):
    turn, stage = divmod(seq - HEADERS[session.agent], 6)
    call = f"{sid}:{turn}:call"
    prompt, reply = transcript_text(session.seed, session.number, turn)
    # ASCII padding expands the encoded output by exactly padding bytes.
    output = FAKE_PAYLOAD + (FAKE_PAYLOAD * (padding // len(FAKE_PAYLOAD) + 1))[:padding] if stage == 2 else ""
    record, tokens = RECORDS[session.agent](session, sid, seq, stage, turn, stamp(session.time(seq)), prompt, reply, call, output)
    return encode(record), tokens


def transcript_text(seed, number, turn):
    return f"合成检查 synthetic prompt {seed}/{number}/{turn}", f"Synthetic progress {number}/{turn} 已验证"


def resource_session_messages(number, turns=500, seed=27):
    """Encode one resource benchmark session for the isolated app's index seeder."""
    return encode([message for turn in range(turns) for message in transcript_text(seed, number, turn)])


def sidecars(session, sid):
    if session.agent != "grok_build":
        return ()
    turns = (session.records + 1) // 6  # number of stages at sequence 4 (usage)
    return (
        ("summary.json", encode({"title": "Synthetic Grok session", "model": MODEL[session.agent], "cwd": session.cwd,
                                 "createdAt": stamp(session.time(0)), "updatedAt": stamp(session.time(session.records - 1))})),
        ("signals.json", encode({"tokenUsage": usage_box(session.agent, turns), "turns": turns})),
        ("plan.json", encode({"entries": [{"content": "Synthetic check", "status": "completed"}]})),
    )


def plan(profile, seed, label):
    sessions = session_layout(profile, seed)
    agents = {name: {"root": name, "sessions": 0, "records": 0, "rawBytes": 0, "outputSlots": 0,
                     "expectedTokens": dict(zip(COUNTS, ZERO))} for name in profile.agents}
    for session in sessions:
        stats = agents[session.agent]
        stats["sessions"] += 1
        stats["records"] += session.records
        sid = session.id
        stats["rawBytes"] += sum(len(data) for _, data in sidecars(session, sid))
        for seq in range(session.records):
            line, tokens = make_record(session, sid, seq)
            stats["rawBytes"] += len(line)
            stats["outputSlots"] += is_tool_output(session, seq)
            for name, amount in zip(COUNTS, tokens):
                stats["expectedTokens"][name] += amount
    base = sum(stats["rawBytes"] for stats in agents.values())
    slots = sum(stats["outputSlots"] for stats in agents.values())
    excess = profile.raw_bytes - base
    if not slots or not 0 <= excess <= slots * MAX_PADDING_PER_OUTPUT:
        raise CorpusError("requested raw byte count is outside the workload's bounds")
    manifest = {"schemaVersion": 1, "profile": label, "seed": seed, "sessions": profile.sessions,
                "jsonlRecords": profile.records, "rawBytes": profile.raw_bytes, "agents": agents}
    return sessions, manifest, slots, excess


def registered_roots(index):
    try:
        info = index.lstat()
    except FileNotFoundError:
        return []
    if not stat.S_ISREG(info.st_mode) or index.resolve(strict=True) != index:
        raise CorpusError("not a regular app-owned index")
    wal = Path(str(index) + "-wal")
    shm = Path(str(index) + "-shm")
    for sidecar in (wal, shm, Path(str(index) + "-journal")):
        try:
            if not stat.S_ISREG(sidecar.lstat().st_mode):
                raise CorpusError("app index has an unsafe sidecar")
        except FileNotFoundError:
            pass
    has_wal = wal.is_file() and wal.stat().st_size != 0
    if has_wal and not shm.is_file():
        raise CorpusError("cannot read the source registry without creating a sidecar")
    query = "?mode=ro" + ("" if has_wal else "&immutable=1")
    try:
        with closing(sqlite3.connect(index.as_uri() + query, uri=True, timeout=0.25)) as db:
            if not db.execute("SELECT 1 FROM grdb_migrations WHERE identifier='v1'").fetchone():
                raise CorpusError("app index source registry is not recognized")
            return [Path(value) for (value,) in db.execute("SELECT root_path FROM sources")
                    if check_source_path(value)]
    except sqlite3.Error as error:
        raise CorpusError("could not read the app source registry") from error


def check_source_path(value):
    if not isinstance(value, str) or not value.startswith("/") or "\0" in value:
        raise CorpusError("app index contains an invalid source root")
    return True


def normalized_name(name):
    return unicodedata.normalize("NFC", name).casefold()


def directory_id(path):
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode):
        raise CorpusError("not a directory in a source or output path")
    return info.st_dev, info.st_ino


def source_boundary(root):
    """Identity of the deepest existing directory and the missing suffix."""
    missing = []
    while True:
        try:
            resolved = root.resolve(strict=True)
        except FileNotFoundError:
            if not root.name or root.name == "..":
                raise CorpusError("could not verify a registered source path")
            try:
                root.lstat()
            except FileNotFoundError:
                missing.append(normalized_name(root.name))
                root = root.parent
                continue
            # A dangling symlink does exist but its destination is unknown.
            raise CorpusError("could not verify a registered source path")
        return directory_id(resolved), tuple(reversed(missing))


def ancestor_ids(parent):
    identity = directory_id(parent)
    paths = [parent]
    if sys.platform == "darwin":
        # A firmlink is not a symlink. The Data-volume spelling can expose
        # additional ancestors (notably the Data mount itself). Only walk it
        # when the kernel confirms it names the same directory.
        data_path = Path("/System/Volumes/Data") / parent.relative_to("/")
        try:
            if directory_id(data_path) == identity:
                paths.append(data_path)
        except FileNotFoundError:
            pass
    return identity, {directory_id(path) for p in paths for path in (p, *p.parents)}


def new_output(parent, sources, raw_bytes):
    spelled = parent.absolute()
    try:
        parent = spelled.resolve(strict=True)
        parent_id, parents = ancestor_ids(parent)
        boundaries = [source_boundary(root) for root in sources]
    except (OSError, RuntimeError) as error:
        raise CorpusError("could not verify source and temporary directory boundaries") from error
    if (PROTECTED.intersection(map(normalized_name, (*spelled.parts, *parent.parts)))
            or any(not missing and identity in parents for identity, missing in boundaries)):
        raise CorpusError("temporary output would touch an existing source")
    # A missing registered root may be the proposed child or below it,
    # including via another spelling of the existing output parent.
    reserved = {missing[0] for identity, missing in boundaries if identity == parent_id and missing}
    if shutil.disk_usage(parent).free < raw_bytes + 1_000_000:
        raise CorpusError("not enough temporary space for the raw corpus")
    while True:
        output = parent / ("agentdash-synth-" + uuid.uuid4().hex)
        if normalized_name(output.name) in reserved:
            continue
        try:
            output.mkdir(mode=0o700)
            return output
        except FileExistsError:
            continue


def generate(prepared, parent, sources):
    sessions, manifest, slots, excess = prepared
    output = new_output(parent, sources, manifest["rawBytes"])
    ordinal = 0
    written = {name: 0 for name in manifest["agents"]}
    for session in sessions:
        sid = session.id
        filename = output / session.agent / session.log(sid)
        filename.parent.mkdir(parents=True, exist_ok=True)
        with filename.open("xb") as file:
            for seq in range(session.records):
                padding = 0
                if is_tool_output(session, seq):
                    padding = split(excess, slots, ordinal)
                    ordinal += 1
                line, _ = make_record(session, sid, seq, padding)
                written[session.agent] += file.write(line)
        for relative, data in sidecars(session, sid):
            with filename.with_name(relative).open("xb") as file:
                written[session.agent] += file.write(data)
    if sum(written.values()) != manifest["rawBytes"] or ordinal != slots:
        raise CorpusError("raw file size did not match the plan")
    for name in written:
        manifest["agents"][name]["rawBytes"] = written[name]
    with (output / "manifest.json").open("x", encoding="utf-8") as file:
        json.dump(manifest, file, ensure_ascii=False, indent=2)
        file.write("\n")
    return output


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", choices=PROFILES, default="smoke")
    parser.add_argument("--seed", type=int, default=27)
    parser.add_argument("--plan", action="store_true", help="validate the workload without writing raw logs")
    args = parser.parse_args(argv)
    if not 0 <= args.seed <= 2**32 - 1:
        parser.error("--seed must be an unsigned 32-bit integer")
    try:
        prepared = plan(PROFILES[args.profile], args.seed, args.profile)
        if args.plan:
            _, manifest, slots, excess = prepared
            print(json.dumps({key: manifest[key] for key in ("profile", "seed", "sessions", "jsonlRecords", "rawBytes")}
                             | {"toolOutputRecords": slots, "toolPaddingBytes": excess}, indent=2))
        else:
            parent = Path("/private/tmp" if sys.platform == "darwin" else "/tmp")
            home = Path.home().resolve(strict=True)
            output = generate(prepared, parent, registered_roots(home / APP_INDEX))
            print(output)
    except (CorpusError, OSError, RuntimeError) as error:
        print(f"synthgen: {error}" if isinstance(error, CorpusError) else "synthgen: could not complete the temporary corpus", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
