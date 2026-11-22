"""Local, fail-closed JSON/JSONL/zstd fixture sanitizer (SPEC 15.2).

No source discovery, network, external libraries, or source writes. See README.md
for the deliberately narrow input contract and privacy/Unicode limitations.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import io
import json
import math
import os
from pathlib import Path
import re
import secrets
import stat
import sys

try:
    from compression import zstd
except ImportError:
    zstd = None  # Plain inputs do not require Python 3.14+.

MAX_BYTES = 64 * 1024 * 1024
MAX_WORKSPACE_BYTES = 256 * 1024
MAX_ZSTD_WINDOW_LOG = 26  # 64 MiB decoder window; independent of output size.
PROTECTED_NAMES = {".claude", ".codex", ".copilot", ".grok"}

# Only schema keys reviewed here survive verbatim. Unknown/dynamic keys are
# pseudonymized too: modelMetrics and tool metadata can use private values as keys.
SCHEMA_KEYS = set("""
type timestamp payload ordinal id uuid parentUuid parentId parent_id sessionId
session_id parent_session_id agentId agent_id messageId message_id requestId
request_id call_id tool_use_id tool_call_id turn_id parent_thread_id thread_id
source subagent thread_spawn other depth agent_path originator cli_version
model_provider cwd git branch commit_hash repository_url gitBranch version
message content text thinking role name namespace arguments input output result
toolName tool_name tool_calls tool_use tool_result toolCallId toolCallIds
usage input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens
cache_creation ephemeral_5m_input_tokens ephemeral_1h_input_tokens cached_input_tokens
reasoning_output_tokens total_tokens last_token_usage total_token_usage info
inputTokens outputTokens cacheReadTokens cacheWriteTokens reasoningTokens totalTokens
model modelId model_id modelMetrics metrics rate_limits primary secondary used_percent
window_minutes resets_at plan_type model_context_window context_window
stop_reason stop_sequence isMeta is_error success error code status kind data
startTime endTime created_at updated_at started_at completed_at duration_ms
context approval_policy sandbox_policy effort precision producer copilotVersion
summary title description display instructions command path file_path filePath directory
project project_path workspace workspace_path repository filename files changes
added removed lines_added lines_removed count seq optional active metadata
last_agent_message parent forked_from continued_from agentType
""".split())

# These are exact, field-scoped schema discriminators, never a global bypass.
ENUMS = {
    "type": set("""
        session_meta turn_context event_msg response_item user assistant system
        developer tool message user_message agent_message token_count input_text
        output_text text thinking tool_use tool_result function_call
        function_call_output custom_tool_call custom_tool_call_output task_started
        task_complete exec_command_end patch_apply_end compacted summary
        file-history-snapshot attachment queue-operation session.start session.resume
        session.context_changed user.message assistant.message assistant.turn_start
        assistant.turn_end tool.execution_start tool.execution_complete
        session.task_complete session.compaction_complete session.model_change
        subagent.started subagent.completed skill.invoked session.shutdown
        session.usage_record session.usage_checkpoint
    """.split()),
    "role": {"user", "assistant", "system", "developer", "tool"},
    "stop_reason": {"tool_use", "end_turn", "max_tokens", "stop_sequence", "pause_turn", "refusal"},
    "status": {"pending", "in_progress", "completed", "cancelled", "running", "failed", "waiting", "idle"},
    "precision": {"call", "snapshot", "checkpoint"},
}
ID_KEYS = {"id", "uuid", "parentuuid", "parentid", "sessionid", "parentsessionid",
           "agentid", "messageid", "requestid", "callid", "tooluseid", "toolcallid",
           "toolcallids", "turnid", "parentthreadid", "threadid", "forkedfrom", "continuedfrom"}
PATH_KEYS = {"cwd", "path", "filepath", "directory", "project", "projectpath",
             "workspace", "workspacepath", "repository", "filename"}
TIME_KEYS = {"timestamp", "starttime", "endtime", "createdat", "updatedat", "startedat", "completedat"}
ISO_TIME = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\Z")
UUID = re.compile(r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\Z")
SECRET = re.compile(r"sk-|ghp_|github_pat_|AKIA[A-Z0-9]{12,}|xox[bp]-|-----BEGIN .*PRIVATE KEY-----|Bearer\s+\S+", re.I)
SECRET_FIELD = re.compile(r"(?:key|token|secret|password|credential|credentials|authorization)\Z")


class CaptureError(Exception):
    """Safe diagnostic: never includes source values or a JSON decoder excerpt."""


class MissingDecoder(CaptureError):
    """Compressed capture prerequisite is missing; plain capture still works."""


def normalized(key):
    return key.replace("_", "").lower()


def placeholder(value):
    # Python len counts Unicode code points. Preserve only layout whitespace.
    return "".join(c if c in "\n\r\t " else "x" for c in value)


def base_digits(number, alphabet):
    digits = ""
    while number:
        number, remainder = divmod(number, len(alphabet))
        digits = alphabet[remainder] + digits
    return digits or alphabet[0]


class Sanitizer:
    def __init__(self):
        self.maps = {"id": {}, "key": {}, "path": {}}
        self.used = {"id": set(), "key": set(SCHEMA_KEYS), "path": set()}
        self.time_origin = None

    def pseudonym(self, value, category):
        if not value:
            return value
        mapping = self.maps[category]
        if value in mapping:
            return mapping[value]
        is_uuid = category == "id" and UUID.fullmatch(value)
        width = 32 if is_uuid else len(value)
        prefix = "/Users/dev/" if category == "path" else ""
        if prefix:
            width = max(1, len(value) - len(prefix))
        alphabet = "0123456789abcdef" if is_uuid else "0123456789abcdefghijklmnopqrstuvwxyz"
        for number in range(1, len(self.used[category]) + 3):
            suffix = base_digits(number, alphabet)
            if len(suffix) > width:
                raise CaptureError("too many distinct short identifiers or keys to sanitize safely")
            result = prefix + suffix.rjust(width, "0")
            if is_uuid:
                result = "-".join((result[:8], result[8:12], result[12:16], result[16:20], result[20:]))
            if result != value and result not in self.used[category]:
                mapping[value] = result
                self.used[category].add(result)
                return result
        raise CaptureError("cannot allocate a distinct sanitized identifier")

    def timestamp(self, value):
        match = ISO_TIME.fullmatch(value)
        if not match:
            return placeholder(value)
        try:
            original = datetime.fromisoformat(value.replace("Z", "+00:00"))
            if self.time_origin is None:
                self.time_origin = original
            shifted = datetime(2000, 1, 1, tzinfo=timezone.utc) + (original - self.time_origin)
            result = shifted.strftime("%Y-%m-%dT%H:%M:%S")
            if match[1]:
                width = len(match[1]) - 1
                result += "." + (f"{shifted.microsecond:06d}" + "000")[:width]
            return result + ("Z" if match[2] == "Z" else "+00:00")
        except (ValueError, OverflowError):
            return placeholder(value)

    def transform(self, value, key="", secret_context=False):
        secret_context = secret_context or bool(SECRET_FIELD.search(normalized(key)))
        if isinstance(value, dict):
            out = {}
            for name, child in value.items():
                safe_name = name if name in SCHEMA_KEYS else self.pseudonym(name, "key")
                if safe_name in out:
                    raise CaptureError("sanitized object keys collided")
                out[safe_name] = self.transform(child, name, secret_context)
            return out
        if isinstance(value, list):
            return [self.transform(child, key, secret_context) for child in value]
        # Credentials are not accounting. Even numeric credentials must not pass
        # through a general "keep numbers" rule, including inside secret objects.
        if secret_context:
            if isinstance(value, str):
                return placeholder(value)
            if value is None:
                return None
            if isinstance(value, bool):
                return False
            if isinstance(value, int) or isinstance(value, float) and math.isfinite(value):
                return type(value)(0)
            raise CaptureError("unsupported value in credential metadata")
        if isinstance(value, str):
            field = normalized(key)
            if field in ID_KEYS:
                return self.pseudonym(value, "id")
            if field in PATH_KEYS:
                return self.pseudonym(value, "path")
            if field in TIME_KEYS:
                return self.timestamp(value)
            if value in ENUMS.get(key, set()):
                return value
            return placeholder(value)
        if value is None or isinstance(value, (bool, int)):
            return value
        if isinstance(value, float) and math.isfinite(value):
            return value
        raise CaptureError("unsupported JSON value")


def object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CaptureError("duplicate JSON object key")
        result[key] = value
    return result


def invalid_constant(_):
    raise CaptureError("non-finite JSON number")


def decode(text):
    try:
        return json.loads(text, object_pairs_hook=object_pairs, parse_constant=invalid_constant)
    except (ValueError, RecursionError):
        raise CaptureError("invalid JSON (source text omitted)") from None


def parse_records(raw, suffix):
    try:
        text = raw.decode("utf-8")
    except UnicodeError:
        raise CaptureError("input must be UTF-8") from None
    if suffix == ".jsonl":
        if not text.endswith("\n"):
            raise CaptureError("JSONL must end with a newline; partial records are not captured")
        records = [decode(line) for line in text.split("\n") if line.strip()]
        if not records or any(not isinstance(record, dict) for record in records):
            raise CaptureError("JSONL must contain JSON objects")
        return records
    result = decode(text)
    if not isinstance(result, (dict, list)):
        raise CaptureError("JSON must contain an object or array")
    return [result]


def decompress_jsonl(raw):
    if zstd is None:
        raise MissingDecoder(".jsonl.zst capture requires Python 3.14+ with compression.zstd")
    try:
        # ZstdFile handles concatenated frames. Bounded reads avoid trusting the
        # frame's claimed size or materializing an arbitrarily large expansion.
        options = {zstd.DecompressionParameter.window_log_max: MAX_ZSTD_WINDOW_LOG}
        with zstd.ZstdFile(io.BytesIO(raw), options=options) as stream:
            decoded = stream.read(MAX_BYTES + 1)
    except (zstd.ZstdError, EOFError):
        raise CaptureError("invalid, incomplete or unsupported zstd input (source details omitted)") from None
    if len(decoded) > MAX_BYTES:
        raise CaptureError("decoded input exceeds the 64 MiB capture limit; select a smaller reviewed source")
    return decoded


def encode_records(records, suffix):
    if suffix == ".jsonl":
        return ("".join(json.dumps(r, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n"
                        for r in records)).encode("utf-8")
    return (json.dumps(records[0], ensure_ascii=False, allow_nan=False, indent=2) + "\n").encode("utf-8")


def validate_sanitized(original, sanitized, encoded, suffix):
    """Re-parse, re-transform, and inspect *all* strings including object keys."""
    if parse_records(encoded, suffix) != sanitized:
        raise CaptureError("sanitized serialization did not round-trip")
    verifier = Sanitizer()
    expected = [verifier.transform(record) for record in original]
    if expected != sanitized:
        raise CaptureError("sanitized output differs from the sanitization policy")

    def check(value):
        if isinstance(value, dict):
            for key, child in value.items():
                check(key)
                check(child)
        elif isinstance(value, list):
            for child in value:
                check(child)
        elif isinstance(value, str) and SECRET.search(value):
            raise CaptureError("secret-like pattern remains after sanitization")
    check(sanitized)


def within(path, root):
    return path == root or root in path.parents


def signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def source_signature(path):
    return signature(path.stat())


def workspace_title_fixture(raw):
    """Capture the known Copilot scalar shapes, never any YAML values."""
    result = []
    found = set()
    captured = 0
    for line in raw.decode("utf-8", errors="strict").splitlines():
        field = re.fullmatch(r"(name|summary):[ \t]*(.*)", line)
        if not field:
            continue
        key, value = field.groups()
        if key in found:
            raise CaptureError("repeated workspace title field")
        found.add(key)
        value = value.strip()
        if not value:
            continue
        if value.startswith('"'):
            result.append(f"{key}: " + json.dumps('Synthetic "quoted" title \\ item'))
        elif value.startswith("'"):
            result.append(f"{key}: 'Synthetic ''quoted'' title'")
        elif value in {"|", "|-", "|+", ">", ">-", ">+"}:
            result.extend((f"{key}: {value}", "  Synthetic block title", "  with continuation"))
        elif value[:1] not in ("|", ">", "!", "*", "&", "[", "{", "#"):
            result.append(f"{key}: Synthetic ordinary title")
        else:
            continue
        captured += 1
    if not result:
        raise CaptureError("no supported workspace title scalar")
    return ("\n".join(result) + "\n").encode("utf-8"), captured


def reject_protected_destination(path):
    """Check spelled, canonical and intermediate symlink-target ancestry.

    The input's root is irrelevant: a fixture must never be published into *any*
    agent-named directory. Case folding is conservative on macOS filesystems.
    """
    pending = [path]
    checked = set()
    while pending:
        candidate = pending.pop()
        if candidate in checked:
            continue
        checked.add(candidate)
        for ancestor in (candidate, *candidate.parents):
            if ancestor.name.casefold() in PROTECTED_NAMES:
                raise CaptureError("output and marker must not be under any protected agent directory")
            if ancestor.is_symlink():
                target = Path(os.readlink(ancestor))
                pending.append(target if target.is_absolute() else ancestor.parent / target)
        resolved = candidate.resolve()
        if resolved != candidate:
            pending.append(resolved)


def paths(input_path, output_path, source_root):
    source = Path(input_path).resolve(strict=True)
    root = Path(source_root).resolve(strict=True) if source_root else source.parent
    output = Path(output_path).absolute()
    marker = Path(str(output) + ".sanitized")
    if not root.is_dir() or not within(source, root):
        raise CaptureError("input must be inside the declared source root")
    suffix = ".jsonl" if source.name.endswith(".jsonl.zst") else source.suffix
    if not source.is_file() or (suffix not in {".json", ".jsonl"} and source.name != "workspace.yaml"):
        raise CaptureError("input must be a regular .json, .jsonl, .jsonl.zst or workspace.yaml file")
    if output.suffix != suffix:
        raise CaptureError(f"output extension must be {suffix}; fixtures are always uncompressed")
    boundaries = [root, source.parent]
    boundaries += [p for p in (source, *source.parents) if p.name.casefold() in PROTECTED_NAMES]
    for target in (output, marker):
        reject_protected_destination(target)
        if os.path.lexists(target):
            raise CaptureError("output and marker must not already exist (including symlinks/hardlinks)")
        resolved = target.resolve()
        if any(within(resolved, boundary) for boundary in boundaries):
            raise CaptureError("output and marker must be outside every source boundary")
    if not output.parent.is_dir():
        raise CaptureError("output parent directory must already exist")
    # Use the canonical parent; a symlink alias never weakens containment checks.
    return source, output.resolve(), marker.resolve(), suffix


def open_directory(path):
    """Pin a canonical destination directory, following no symlink components."""
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open("/", flags)
    try:
        for component in path.parts[1:]:
            next_fd = os.open(component, flags, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def write_stage(parent_fd, data):
    filename = ".agentdash-sanitized-" + secrets.token_hex(16)
    fd = os.open(filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=parent_fd)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        return filename
    except BaseException:
        os.unlink(filename, dir_fd=parent_fd)
        raise


def capture(input_path, output_path, source_root=None):
    """Publish a new fixture and digest marker, with no overwrite operation."""
    stages = []
    published = None
    parent_fd = None
    try:
        source, output, marker, suffix = paths(input_path, output_path, source_root)
        parent_fd = open_directory(output.parent)
        parent_identity = signature(os.fstat(parent_fd))[:2]
        before = source_signature(source)
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                raise CaptureError("input must be a regular file")
            if signature(os.fstat(handle.fileno())) != before:
                raise CaptureError("source changed before capture could begin")
            limit = MAX_WORKSPACE_BYTES if suffix == ".yaml" else MAX_BYTES
            raw = handle.read(limit + 1)
            if signature(os.fstat(handle.fileno())) != before:
                raise CaptureError("source changed while being read")
        if len(raw) > limit:
            raise CaptureError("input exceeds its format's capture limit; select a smaller reviewed source")
        if suffix == ".yaml":
            encoded, record_count = workspace_title_fixture(raw)
        else:
            if source.suffix == ".zst":
                raw = decompress_jsonl(raw)
            records = parse_records(raw, suffix)
            sanitizer = Sanitizer()
            sanitized = [sanitizer.transform(record) for record in records]
            encoded = encode_records(sanitized, suffix)
            validate_sanitized(records, sanitized, encoded, suffix)
            record_count = len(records)
        if source_signature(source) != before:
            raise CaptureError("source changed during capture; retry on a stable file")
        if signature(os.stat(output.parent, follow_symlinks=False))[:2] != parent_identity:
            raise CaptureError("output parent changed during capture")
        marker_bytes = (json.dumps({"sanitizer_version": 1, "sha256": hashlib.sha256(encoded).hexdigest(),
            "records": record_count, "unicode_length": "not-retained" if suffix == ".yaml" else "code-points",
            "review_required": True}, indent=2) + "\n").encode()
        stages.append(write_stage(parent_fd, encoded))
        stages.append(write_stage(parent_fd, marker_bytes))
        # Hard-link publication is atomic and refuses an existing destination.
        # A marker is linked only after output bytes and validation are complete.
        os.link(stages[0], output.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd, follow_symlinks=False)
        published = (output.name, os.stat(output.name, dir_fd=parent_fd, follow_symlinks=False).st_ino)
        os.link(stages[1], marker.name, src_dir_fd=parent_fd, dst_dir_fd=parent_fd, follow_symlinks=False)
        published = None
    except (OSError, ValueError, RecursionError, UnicodeError):
        raise CaptureError("capture failed; no validated marker was published (source details omitted)") from None
    finally:
        if published:
            name, inode = published
            # Only roll back the file this invocation created, never user work.
            try:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                if stat.S_ISREG(current.st_mode) and current.st_ino == inode:
                    os.unlink(name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        for stage in stages:
            try:
                os.unlink(stage, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        if parent_fd is not None:
            os.close(parent_fd)


def main():
    parser = argparse.ArgumentParser(description="Sanitize one JSON, JSONL, .jsonl.zst, or Copilot workspace.yaml into a new fixture.")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--source-root", type=Path,
                        help="full source boundary; defaults to input parent; output must be outside it")
    args = parser.parse_args()
    try:
        capture(args.input, args.output, args.source_root)
    except CaptureError as error:
        print(f"fixture-capture: {error}", file=sys.stderr)
        return 2 if isinstance(error, MissingDecoder) else 1
    print("fixture-capture: sanitized fixture and digest marker created; human review required")
    return 0


if __name__ == "__main__":
    sys.exit(main())
