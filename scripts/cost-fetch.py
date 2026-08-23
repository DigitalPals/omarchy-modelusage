#!/usr/bin/env python3
"""Estimate API-equivalent model costs from local provider transcripts.

The scanner reads only usage metadata from the session files already owned by
Claude Code, Codex, and Kimi Code. Prompts, responses, and tool output are never
copied into plugin state or emitted to QML.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import time
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from model_usage_common import atomic_write_json, clean_message


SCHEMA_VERSION = 1
SCAN_CACHE_VERSION = 1
RATE_CACHE_VERSION = 1
PROVIDER_ORDER = ("claude", "codex", "kimi")
PROVIDER_NAMES = {
    "claude": "Claude Code",
    "codex": "OpenAI Codex",
    "kimi": "Kimi Code",
}
LITELLM_RATES_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/"
    "model_prices_and_context_window.json"
)
RATE_TTL_SECONDS = 24 * 60 * 60
CACHE_RETENTION_DAYS = 32
MTIME_SLACK_SECONDS = 36 * 60 * 60
MAX_RATE_BYTES = 32 * 1024 * 1024
FORK_COPY_MAX_GAP_MS = 1000
MAX_TRANSCRIPT_LINE_BYTES = 1024 * 1024
MAX_TRANSCRIPT_FILE_BYTES = 128 * 1024 * 1024
MAX_TRANSCRIPT_SCAN_BYTES = 512 * 1024 * 1024
MAX_TRANSCRIPT_RECORDS_PER_FILE = 20_000
MAX_TRANSCRIPT_RECORDS_TOTAL = 50_000
MAX_TRANSCRIPT_FILES_PER_PROVIDER = 10_000
MAX_TRANSCRIPT_DIRECTORIES_PER_PROVIDER = 2_000
MAX_SCAN_CACHE_BYTES = 32 * 1024 * 1024
MAX_SCAN_CACHE_FILES = 10_000
MAX_MODEL_NAME_CHARS = 256
MAX_MODEL_GROUPS = 512


class TranscriptLimitError(ValueError):
    """A transcript exceeded a resource ceiling and must be skipped atomically."""


@dataclass(frozen=True)
class UsageRecord:
    provider: str
    timestamp_ms: int
    model: str
    session_id: str
    uncached_input: int
    cached_input: int
    cache_creation: int
    output: int
    reasoning: int
    reported_cost_usd: float | None
    dedupe_key: str | None

    @property
    def total_tokens(self) -> int:
        return self.uncached_input + self.cached_input + self.cache_creation + self.output


def finite_number(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        result = float(value)
    elif isinstance(value, str):
        try:
            result = float(value.strip())
        except ValueError:
            return None
    else:
        return None
    return result if math.isfinite(result) else None


def nonnegative_int(value: Any) -> int:
    parsed = finite_number(value)
    return max(0, int(parsed)) if parsed is not None else 0


def parse_timestamp_ms(value: Any) -> int | None:
    numeric = finite_number(value)
    if numeric is not None:
        if numeric < 10_000_000_000:
            numeric *= 1000
        return int(numeric) if numeric > 0 else None
    if not isinstance(value, str):
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None


def iso_timestamp(epoch_seconds: int | float | None) -> str | None:
    if epoch_seconds is None:
        return None
    return datetime.fromtimestamp(epoch_seconds, tz=timezone.utc).isoformat().replace("+00:00", "Z")


def opaque_id(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def read_bounded_json(path: Path, max_bytes: int) -> Any:
    with path.open("rb") as handle:
        raw = handle.read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise ValueError(f"JSON input exceeds the {max_bytes}-byte limit")
    return json.loads(raw)


def bounded_jsonl_lines(path: Path) -> Iterable[str]:
    with path.open("rb") as handle:
        consumed = 0
        while True:
            raw = handle.readline(MAX_TRANSCRIPT_LINE_BYTES + 1)
            if not raw:
                return
            consumed += len(raw)
            if consumed > MAX_TRANSCRIPT_FILE_BYTES:
                raise TranscriptLimitError("transcript file is unexpectedly large")
            if len(raw) > MAX_TRANSCRIPT_LINE_BYTES:
                raise TranscriptLimitError("transcript line is unexpectedly large")
            yield raw.decode("utf-8", errors="replace")


def bounded_model(value: Any) -> str:
    if not isinstance(value, str):
        return ""
    return value.strip()[:MAX_MODEL_NAME_CHARS]


def state_path(name: str, state_dir: Path | None = None) -> Path:
    if state_dir is None:
        state_home = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state"))
        state_dir = state_home / "omarchy" / "model-usage"
    return state_dir / name


def serialize_record(record: UsageRecord) -> list[Any]:
    return [
        record.timestamp_ms,
        record.model,
        record.session_id,
        record.uncached_input,
        record.cached_input,
        record.cache_creation,
        record.output,
        record.reasoning,
        record.reported_cost_usd,
        record.dedupe_key,
    ]


def deserialize_record(provider: str, row: Any) -> UsageRecord | None:
    if not isinstance(row, list) or len(row) != 10:
        return None
    timestamp = finite_number(row[0])
    model = bounded_model(row[1])
    session_id = row[2][:128] if isinstance(row[2], str) else ""
    if timestamp is None or not model or not isinstance(row[2], str):
        return None
    numeric = [finite_number(value) for value in row[3:8]]
    if any(value is None or value < 0 for value in numeric):
        return None
    reported = finite_number(row[8])
    if reported is not None and reported < 0:
        reported = None
    dedupe = row[9][:128] if isinstance(row[9], str) else None
    return UsageRecord(
        provider=provider,
        timestamp_ms=int(timestamp),
        model=model,
        session_id=session_id,
        uncached_input=int(numeric[0] or 0),
        cached_input=int(numeric[1] or 0),
        cache_creation=int(numeric[2] or 0),
        output=int(numeric[3] or 0),
        reasoning=int(numeric[4] or 0),
        reported_cost_usd=reported,
        dedupe_key=dedupe,
    )


def load_scan_cache(path: Path) -> dict[str, dict[str, Any]]:
    try:
        document = read_bounded_json(path, MAX_SCAN_CACHE_BYTES)
    except (OSError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
        return {}
    if not isinstance(document, dict) or document.get("schemaVersion") != SCAN_CACHE_VERSION:
        return {}
    files = document.get("files")
    if not isinstance(files, dict):
        return {}
    cache: dict[str, dict[str, Any]] = {}
    cached_records = 0
    for key, entry in files.items():
        if len(cache) >= MAX_SCAN_CACHE_FILES:
            break
        if not isinstance(key, str) or len(key) != 64 or not isinstance(entry, dict):
            continue
        provider = entry.get("p")
        if provider not in PROVIDER_ORDER:
            continue
        size = finite_number(entry.get("s"))
        modified = finite_number(entry.get("m"))
        rows = entry.get("r")
        if (
            size is None
            or modified is None
            or not isinstance(rows, list)
            or len(rows) > MAX_TRANSCRIPT_RECORDS_PER_FILE
            or cached_records + len(rows) > MAX_TRANSCRIPT_RECORDS_TOTAL
        ):
            continue
        records: list[UsageRecord] = []
        corrupt = False
        for row in rows:
            record = deserialize_record(provider, row)
            if record is None:
                corrupt = True
                break
            records.append(record)
        if not corrupt:
            cache[key] = {
                "s": int(size),
                "m": int(modified),
                "p": provider,
                "records": records,
            }
            cached_records += len(records)
    return cache


def save_scan_cache(path: Path, cache: dict[str, dict[str, Any]]) -> None:
    files: dict[str, Any] = {}
    cached_records = 0
    for key, entry in cache.items():
        if len(files) >= MAX_SCAN_CACHE_FILES:
            break
        records = entry.get("records")
        if (
            not isinstance(records, list)
            or len(records) > MAX_TRANSCRIPT_RECORDS_PER_FILE
            or cached_records + len(records) > MAX_TRANSCRIPT_RECORDS_TOTAL
        ):
            continue
        files[key] = {
            "s": int(entry["s"]),
            "m": int(entry["m"]),
            "p": entry["p"],
            "r": [serialize_record(record) for record in records],
        }
        cached_records += len(records)
    atomic_write_json(path, {"schemaVersion": SCAN_CACHE_VERSION, "files": files})


def record_from_claude(document: Any) -> UsageRecord | None:
    if not isinstance(document, dict) or document.get("type") != "assistant":
        return None
    message = document.get("message")
    if not isinstance(message, dict):
        return None
    usage = message.get("usage")
    model = bounded_model(message.get("model"))
    timestamp = parse_timestamp_ms(document.get("timestamp"))
    if not isinstance(usage, dict) or not model or timestamp is None:
        return None
    message_id = message.get("id") if isinstance(message.get("id"), str) else ""
    request_id = document.get("requestId") if isinstance(document.get("requestId"), str) else ""
    raw_dedupe = f"{message_id}:{request_id}" if message_id or request_id else ""
    raw_session = document.get("sessionId") if isinstance(document.get("sessionId"), str) else ""
    cost = finite_number(document.get("costUSD"))
    if cost is not None and cost < 0:
        cost = None
    record = UsageRecord(
        provider="claude",
        timestamp_ms=timestamp,
        model=model,
        session_id=opaque_id("claude:" + raw_session) if raw_session else "",
        uncached_input=nonnegative_int(usage.get("input_tokens")),
        cached_input=nonnegative_int(usage.get("cache_read_input_tokens")),
        cache_creation=nonnegative_int(usage.get("cache_creation_input_tokens")),
        output=nonnegative_int(usage.get("output_tokens")),
        reasoning=0,
        reported_cost_usd=cost,
        dedupe_key=opaque_id("claude:" + raw_dedupe) if raw_dedupe else None,
    )
    return record if record.total_tokens > 0 else None


def parse_claude_file(path: Path, retention_start_ms: int) -> list[UsageRecord] | None:
    records: list[UsageRecord] = []
    seen: set[str] = set()
    try:
        for line in bounded_jsonl_lines(path):
            if '"usage"' not in line:
                continue
            try:
                record = record_from_claude(json.loads(line))
            except (json.JSONDecodeError, RecursionError):
                continue
            if record is None or record.timestamp_ms < retention_start_ms:
                continue
            if record.dedupe_key is not None:
                if record.dedupe_key in seen:
                    continue
                seen.add(record.dedupe_key)
            if len(records) >= MAX_TRANSCRIPT_RECORDS_PER_FILE:
                raise TranscriptLimitError("too many usage records in one transcript")
            records.append(record)
    except (OSError, TranscriptLimitError):
        return None
    return records


def codex_forked(payload: dict[str, Any]) -> bool:
    if isinstance(payload.get("forked_from_id"), str):
        return True
    source = payload.get("source")
    if not isinstance(source, dict):
        return False
    subagent = source.get("subagent")
    if not isinstance(subagent, dict):
        return False
    spawn = subagent.get("thread_spawn")
    return isinstance(spawn, dict) and isinstance(spawn.get("parent_thread_id"), str)


def parse_codex_file(path: Path, retention_start_ms: int) -> list[UsageRecord] | None:
    records: list[UsageRecord] = []
    model = ""
    session_id = ""
    last_signature: str | None = None
    saw_session_meta = False
    suppressing_fork_copies = False
    fork_copy_anchor_ms = 0
    try:
        for line in bounded_jsonl_lines(path):
            if not any(marker in line for marker in ('"session_meta"', '"turn_context"', '"token_count"')):
                continue
            try:
                document = json.loads(line)
            except (json.JSONDecodeError, RecursionError):
                continue
            if not isinstance(document, dict) or not isinstance(document.get("payload"), dict):
                continue
            payload = document["payload"]
            record_type = document.get("type")
            if record_type == "session_meta":
                if saw_session_meta:
                    continue
                saw_session_meta = True
                raw_id = payload.get("id") or payload.get("session_id")
                if isinstance(raw_id, str):
                    session_id = opaque_id("codex:" + raw_id)
                timestamp = parse_timestamp_ms(document.get("timestamp"))
                if timestamp is not None and codex_forked(payload):
                    suppressing_fork_copies = True
                    fork_copy_anchor_ms = timestamp
                continue
            if record_type == "turn_context":
                model = bounded_model(payload.get("model"))
                continue
            if payload.get("type") != "token_count":
                continue
            info = payload.get("info")
            last = info.get("last_token_usage") if isinstance(info, dict) else None
            timestamp = parse_timestamp_ms(document.get("timestamp"))
            if not isinstance(last, dict) or timestamp is None or not model:
                continue
            signature = json.dumps(last, separators=(",", ":"), sort_keys=True)
            if signature == last_signature:
                continue
            last_signature = signature
            if suppressing_fork_copies:
                if timestamp - fork_copy_anchor_ms < FORK_COPY_MAX_GAP_MS:
                    fork_copy_anchor_ms = timestamp
                    continue
                suppressing_fork_copies = False
            input_tokens = nonnegative_int(last.get("input_tokens"))
            cached = nonnegative_int(last.get("cached_input_tokens"))
            cache_creation = nonnegative_int(last.get("cache_write_input_tokens"))
            output = nonnegative_int(last.get("output_tokens"))
            record = UsageRecord(
                provider="codex",
                timestamp_ms=timestamp,
                model=model,
                session_id=session_id,
                uncached_input=max(0, input_tokens - cached - cache_creation),
                cached_input=cached,
                cache_creation=cache_creation,
                output=output,
                reasoning=min(output, nonnegative_int(last.get("reasoning_output_tokens"))),
                reported_cost_usd=None,
                dedupe_key=None,
            )
            if record.total_tokens > 0 and record.timestamp_ms >= retention_start_ms:
                if len(records) >= MAX_TRANSCRIPT_RECORDS_PER_FILE:
                    raise TranscriptLimitError("too many usage records in one transcript")
                records.append(record)
    except (OSError, TranscriptLimitError):
        return None
    return records


def kimi_events(message_type: str, payload: Any) -> Iterable[tuple[str, dict[str, Any]]]:
    if not isinstance(payload, dict):
        return
    if message_type == "SubagentEvent":
        event = payload.get("event")
        if isinstance(event, dict):
            inner_type = event.get("type")
            if isinstance(inner_type, str):
                yield from kimi_events(inner_type, event.get("payload"))
        return
    yield message_type, payload


def parse_kimi_file(path: Path, retention_start_ms: int) -> list[UsageRecord] | None:
    records: list[UsageRecord] = []
    raw_session = path.parent.name
    session_id = opaque_id("kimi:" + raw_session) if raw_session else ""
    try:
        for line in bounded_jsonl_lines(path):
            if '"token_usage"' not in line:
                continue
            try:
                document = json.loads(line)
            except (json.JSONDecodeError, RecursionError):
                continue
            if not isinstance(document, dict) or not isinstance(document.get("message"), dict):
                continue
            timestamp = parse_timestamp_ms(document.get("timestamp"))
            if timestamp is None or timestamp < retention_start_ms:
                continue
            message = document["message"]
            message_type = message.get("type")
            if not isinstance(message_type, str):
                continue
            for event_type, payload in kimi_events(message_type, message.get("payload")):
                if event_type != "StatusUpdate":
                    continue
                usage = payload.get("token_usage")
                if not isinstance(usage, dict):
                    continue
                raw_message_id = payload.get("message_id")
                if isinstance(raw_message_id, str) and raw_message_id:
                    dedupe_source = "kimi:" + raw_message_id
                else:
                    dedupe_source = "kimi:" + str(timestamp) + ":" + json.dumps(
                        usage, separators=(",", ":"), sort_keys=True
                    )
                record = UsageRecord(
                    provider="kimi",
                    timestamp_ms=timestamp,
                    model="<unattributed>",
                    session_id=session_id,
                    uncached_input=nonnegative_int(usage.get("input_other")),
                    cached_input=nonnegative_int(usage.get("input_cache_read")),
                    cache_creation=nonnegative_int(usage.get("input_cache_creation")),
                    output=nonnegative_int(usage.get("output")),
                    reasoning=0,
                    reported_cost_usd=None,
                    dedupe_key=opaque_id(dedupe_source),
                )
                if record.total_tokens > 0:
                    if len(records) >= MAX_TRANSCRIPT_RECORDS_PER_FILE:
                        raise TranscriptLimitError("too many usage records in one transcript")
                    records.append(record)
    except (OSError, TranscriptLimitError):
        return None
    return records


PARSERS: dict[str, Callable[[Path, int], list[UsageRecord] | None]] = {
    "claude": parse_claude_file,
    "codex": parse_codex_file,
    "kimi": parse_kimi_file,
}


def transcript_root(provider: str) -> Path:
    if provider == "claude":
        configured = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude")).expanduser()
        nested = configured / ".claude" / "projects"
        return nested if nested.is_dir() else configured / "projects"
    if provider == "codex":
        return Path(os.environ.get("CODEX_HOME") or (Path.home() / ".codex")).expanduser() / "sessions"
    return Path(os.environ.get("KIMI_SHARE_DIR") or (Path.home() / ".kimi")).expanduser() / "sessions"


def discover_transcripts(
    provider: str, root: Path, retention_start_ms: int
) -> tuple[list[tuple[Path, os.stat_result, str]], set[str], int, bool]:
    candidates: list[tuple[Path, os.stat_result, str]] = []
    live: set[str] = set()
    errors = 0
    complete = True
    pending = [root]
    visited_directories = 0
    stop = False

    while pending and not stop:
        if visited_directories >= MAX_TRANSCRIPT_DIRECTORIES_PER_PROVIDER:
            errors += 1
            complete = False
            break
        directory = pending.pop()
        visited_directories += 1
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            if (
                                visited_directories + len(pending)
                                >= MAX_TRANSCRIPT_DIRECTORIES_PER_PROVIDER
                            ):
                                errors += 1
                                complete = False
                                stop = True
                                break
                            pending.append(Path(entry.path))
                            continue
                        if not entry.is_file(follow_symlinks=False):
                            continue
                    except OSError:
                        errors += 1
                        complete = False
                        continue
                    name = entry.name
                    if provider == "kimi":
                        if name != "wire.jsonl":
                            continue
                    elif not name.endswith(".jsonl"):
                        continue
                    if len(live) >= MAX_TRANSCRIPT_FILES_PER_PROVIDER:
                        errors += 1
                        complete = False
                        stop = True
                        break
                    path = Path(entry.path)
                    key = opaque_id(str(path.absolute()))
                    live.add(key)
                    try:
                        stats = entry.stat(follow_symlinks=False)
                    except OSError:
                        errors += 1
                        complete = False
                        continue
                    if int(stats.st_mtime * 1000) >= retention_start_ms:
                        candidates.append((path, stats, key))
        except OSError:
            errors += 1
            complete = False
    candidates.sort(key=lambda item: (item[1].st_mtime_ns, str(item[0])), reverse=True)
    return candidates, live, errors, complete


def scan_transcripts(
    provider_ids: list[str], state_dir: Path | None, now_ms: int
) -> tuple[list[UsageRecord], list[dict[str, Any]]]:
    cache_path = state_path("cost-scan-cache.json", state_dir)
    cache = load_scan_cache(cache_path)
    retention_start_ms = now_ms - int((CACHE_RETENTION_DAYS * 86400 + MTIME_SLACK_SECONDS) * 1000)
    records: list[UsageRecord] = []
    coverage: list[dict[str, Any]] = []
    walked: set[str] = set()
    live_by_provider: dict[str, set[str] | None] = {}
    cache_changed = False
    scanned_input_bytes = 0

    for provider in provider_ids:
        root = transcript_root(provider)
        source = {
            "id": provider,
            "name": PROVIDER_NAMES[provider],
            "status": "ok",
            "message": "",
            "scannedFiles": 0,
            "skippedFiles": 0,
            "sessions": 0,
        }
        if not root.is_dir():
            source.update(status="missing", message="No local transcript directory was found.")
            coverage.append(source)
            continue

        walked.add(provider)
        candidates, live, discovery_errors, discovery_complete = discover_transcripts(
            provider, root, retention_start_ms
        )
        live_by_provider[provider] = live if discovery_complete else None
        source["skippedFiles"] += discovery_errors
        provider_record_count = 0
        for path, stats, key in candidates:
            size = int(stats.st_size)
            modified = int(stats.st_mtime_ns)
            entry = cache.get(key)
            parsed: list[UsageRecord] | None
            cache_hit = (
                entry is not None
                and entry.get("p") == provider
                and entry.get("s") == size
                and entry.get("m") == modified
            )
            if cache_hit:
                parsed = entry["records"]
            else:
                if entry is not None:
                    del cache[key]
                    cache_changed = True
                if (
                    size > MAX_TRANSCRIPT_FILE_BYTES
                    or scanned_input_bytes + size > MAX_TRANSCRIPT_SCAN_BYTES
                ):
                    parsed = None
                else:
                    scanned_input_bytes += size
                    parsed = PARSERS[provider](path, retention_start_ms)
            if parsed is None:
                source["skippedFiles"] += 1
                continue
            if len(records) + len(parsed) > MAX_TRANSCRIPT_RECORDS_TOTAL:
                source["skippedFiles"] += 1
                continue
            if not cache_hit:
                cache[key] = {
                    "s": size,
                    "m": modified,
                    "p": provider,
                    "records": parsed,
                }
                cache_changed = True
            source["scannedFiles"] += 1
            provider_record_count += len(parsed)
            records.extend(parsed)

        incomplete = source["skippedFiles"] > 0
        messages: list[str] = []
        if incomplete:
            messages.append(
                "Some transcript files were unreadable or exceeded safety limits; "
                "totals may be incomplete."
            )
            source["status"] = "partial" if source["scannedFiles"] > 0 else "failed"
        if provider == "kimi" and provider_record_count > 0 and source["status"] != "failed":
            source["status"] = "partial"
            messages.append(
                "Kimi records tokens but not reliable historical model names; cost is unavailable."
            )
        if messages:
            source["message"] = " ".join(messages)
        elif not candidates:
            source["message"] = "No recent usage transcripts were found."
        coverage.append(source)

    for key, entry in list(cache.items()):
        provider = entry.get("p")
        too_old = int(entry.get("m", 0)) // 1_000_000 < retention_start_ms
        provider_live = live_by_provider.get(provider)
        deleted = provider in walked and provider_live is not None and key not in provider_live
        if too_old or deleted:
            del cache[key]
            cache_changed = True

    if cache_changed:
        try:
            save_scan_cache(cache_path, cache)
        except OSError:
            pass
    return records, coverage


def normalize_model_name(model: str) -> str:
    normalized = model.strip().lower().rsplit("/", 1)[-1]
    return normalized[:MAX_MODEL_NAME_CHARS]


UNPRICEABLE_MODELS = {
    "",
    "<synthetic>",
    "synthetic",
    "<unattributed>",
    "opus",
    "sonnet",
    "haiku",
    "fable",
}


def parse_rate_table(document: Any) -> dict[str, tuple[float, float, float, float]]:
    rates: dict[str, tuple[float, float, float, float]] = {}
    if not isinstance(document, dict):
        return rates
    for name, raw in document.items():
        if not isinstance(name, str) or not isinstance(raw, dict):
            continue
        input_rate = finite_number(raw.get("input_cost_per_token"))
        output_rate = finite_number(raw.get("output_cost_per_token"))
        if input_rate is None or output_rate is None or input_rate < 0 or output_rate < 0:
            continue
        cache_read = finite_number(raw.get("cache_read_input_token_cost"))
        cache_create = finite_number(raw.get("cache_creation_input_token_cost"))
        rates[normalize_model_name(name)] = (
            input_rate,
            output_rate,
            cache_read if cache_read is not None and cache_read >= 0 else input_rate,
            cache_create if cache_create is not None and cache_create >= 0 else input_rate,
        )
    return rates


def load_rate_cache(path: Path) -> tuple[int, dict[str, tuple[float, float, float, float]]] | None:
    try:
        document = read_bounded_json(path, MAX_RATE_BYTES)
    except (OSError, ValueError, json.JSONDecodeError, UnicodeDecodeError):
        return None
    if not isinstance(document, dict) or document.get("schemaVersion") != RATE_CACHE_VERSION:
        return None
    fetched = finite_number(document.get("fetchedAt"))
    raw_rates = document.get("rates")
    if fetched is None or not isinstance(raw_rates, dict):
        return None
    rates: dict[str, tuple[float, float, float, float]] = {}
    for model, row in raw_rates.items():
        if not isinstance(model, str) or not isinstance(row, list) or len(row) != 4:
            continue
        values = [finite_number(value) for value in row]
        if any(value is None or value < 0 for value in values):
            continue
        normalized = normalize_model_name(model)
        if normalized:
            rates[normalized] = (
                values[0] or 0,
                values[1] or 0,
                values[2] or 0,
                values[3] or 0,
            )
    return (int(fetched), rates) if rates else None


def save_rate_cache(
    path: Path, fetched_at: int, rates: dict[str, tuple[float, float, float, float]]
) -> None:
    atomic_write_json(
        path,
        {
            "schemaVersion": RATE_CACHE_VERSION,
            "fetchedAt": fetched_at,
            "rates": {model: list(row) for model, row in rates.items()},
        },
    )


def fetch_rate_document(timeout: float) -> Any:
    request = urllib.request.Request(
        LITELLM_RATES_URL,
        headers={"Accept": "application/json", "User-Agent": "omarchy-model-usage/1"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        body = response.read(MAX_RATE_BYTES + 1)
    if len(body) > MAX_RATE_BYTES:
        raise ValueError("pricing table is unexpectedly large")
    return json.loads(body)


def load_rates(
    state_dir: Path | None, timeout: float, now: int
) -> tuple[dict[str, tuple[float, float, float, float]], dict[str, Any]]:
    cache_path = state_path("cost-model-rates.json", state_dir)
    cached = load_rate_cache(cache_path)
    cached_at = cached[0] if cached else None
    cached_rates = cached[1] if cached else {}
    if cached_at is not None and now - cached_at < RATE_TTL_SECONDS:
        return cached_rates, {
            "status": "cached",
            "source": LITELLM_RATES_URL,
            "fetchedAt": iso_timestamp(cached_at),
            "knownModels": len(cached_rates),
            "message": "",
        }

    try:
        rates = parse_rate_table(fetch_rate_document(timeout))
        if not rates:
            raise ValueError("pricing table contains no usable model rates")
        try:
            save_rate_cache(cache_path, now, rates)
        except OSError:
            pass
        return rates, {
            "status": "fresh",
            "source": LITELLM_RATES_URL,
            "fetchedAt": iso_timestamp(now),
            "knownModels": len(rates),
            "message": "",
        }
    except Exception:
        if cached_rates:
            return cached_rates, {
                "status": "cached",
                "source": LITELLM_RATES_URL,
                "fetchedAt": iso_timestamp(cached_at),
                "knownModels": len(cached_rates),
                "message": "The live model-price refresh failed; cached prices are in use.",
            }
        return {}, {
            "status": "unavailable",
            "source": LITELLM_RATES_URL,
            "fetchedAt": None,
            "knownModels": 0,
            "message": "Model prices are unavailable. Token counts remain usable.",
        }


def local_zone(name: str | None = None):
    candidates: list[str] = []
    if name:
        candidates.append(name)
    environment_zone = os.environ.get("TZ", "").lstrip(":")
    if environment_zone and not environment_zone.startswith("/"):
        candidates.append(environment_zone)
    try:
        resolved = str(Path("/etc/localtime").resolve())
        marker = "/zoneinfo/"
        if marker in resolved:
            candidates.append(resolved.split(marker, 1)[1])
    except OSError:
        pass
    try:
        configured = Path("/etc/timezone").read_text(encoding="utf-8").strip()
        if configured:
            candidates.append(configured)
    except OSError:
        pass
    for candidate in candidates:
        try:
            return ZoneInfo(candidate)
        except ZoneInfoNotFoundError:
            continue
    return datetime.now().astimezone().tzinfo or timezone.utc


def empty_cell() -> dict[str, Any]:
    return {
        "uncachedInputTokens": 0,
        "cachedInputTokens": 0,
        "cacheCreationTokens": 0,
        "outputTokens": 0,
        "reasoningTokens": 0,
        "cost": 0.0,
        "cacheSavings": 0.0,
        "records": 0,
        "pricedRecords": 0,
        "providerReportedRecords": 0,
        "unpricedRecords": 0,
        "rateMatchedRecords": 0,
        "rateAvailableRecords": 0,
        "sessions": set(),
    }


def add_record(
    cell: dict[str, Any],
    record: UsageRecord,
    rates: dict[str, tuple[float, float, float, float]],
) -> None:
    cell["uncachedInputTokens"] += record.uncached_input
    cell["cachedInputTokens"] += record.cached_input
    cell["cacheCreationTokens"] += record.cache_creation
    cell["outputTokens"] += record.output
    cell["reasoningTokens"] += record.reasoning
    cell["records"] += 1
    if record.session_id:
        cell["sessions"].add(record.session_id)

    normalized_model = normalize_model_name(record.model)
    rate = None if normalized_model in UNPRICEABLE_MODELS else rates.get(normalized_model)
    if record.reported_cost_usd is not None:
        cell["cost"] += record.reported_cost_usd
        cell["pricedRecords"] += 1
        cell["providerReportedRecords"] += 1
    elif rate is not None and normalize_model_name(record.model) not in UNPRICEABLE_MODELS:
        input_rate, output_rate, cache_read_rate, cache_create_rate = rate
        cell["cost"] += (
            record.uncached_input * input_rate
            + record.cached_input * cache_read_rate
            + record.cache_creation * cache_create_rate
            + record.output * output_rate
        )
        cell["pricedRecords"] += 1
        cell["rateMatchedRecords"] += 1
    else:
        cell["unpricedRecords"] += 1

    if rate is not None:
        input_rate, _, cache_read_rate, _ = rate
        cell["cacheSavings"] += record.cached_input * max(0, input_rate - cache_read_rate)
        cell["rateAvailableRecords"] += 1


def finish_cell(cell: dict[str, Any]) -> dict[str, Any]:
    records = int(cell["records"])
    priced = int(cell["pricedRecords"])
    total_tokens = (
        cell["uncachedInputTokens"]
        + cell["cachedInputTokens"]
        + cell["cacheCreationTokens"]
        + cell["outputTokens"]
    )
    if records == 0:
        cost: float | None = 0.0
        cache_savings: float | None = 0.0
        source = "none"
    elif priced == 0:
        cost = None
        cache_savings = (
            round(float(cell["cacheSavings"]), 8) if cell["rateAvailableRecords"] > 0 else None
        )
        source = "unpriced"
    else:
        cost = round(float(cell["cost"]), 8)
        cache_savings = (
            round(float(cell["cacheSavings"]), 8) if cell["rateAvailableRecords"] > 0 else None
        )
        if cell["unpricedRecords"] > 0 or (
            cell["providerReportedRecords"] > 0 and cell["rateMatchedRecords"] > 0
        ):
            source = "mixed"
        elif cell["providerReportedRecords"] == records:
            source = "providerReported"
        else:
            source = "modelPriced"
    return {
        "costUsd": cost,
        "cacheSavingsUsd": cache_savings,
        "uncachedInputTokens": int(cell["uncachedInputTokens"]),
        "cachedInputTokens": int(cell["cachedInputTokens"]),
        "cacheCreationTokens": int(cell["cacheCreationTokens"]),
        "outputTokens": int(cell["outputTokens"]),
        "reasoningTokens": int(cell["reasoningTokens"]),
        "totalTokens": int(total_tokens),
        "records": records,
        "pricedRecords": priced,
        "unpricedRecords": int(cell["unpricedRecords"]),
        "sessions": len(cell["sessions"]),
        "costSource": source,
    }


def period_window(days: int, now_ms: int, zone) -> tuple[dict[str, Any], list[str], Callable[[int], str | None]]:
    if days == 1:
        until_ms = now_ms
        since_ms = until_ms - 24 * 60 * 60 * 1000
        keys = [iso_timestamp((since_ms + index * 3_600_000) / 1000) or "" for index in range(24)]

        def hourly_key(timestamp_ms: int) -> str | None:
            if timestamp_ms < since_ms or timestamp_ms > until_ms:
                return None
            index = min(23, max(0, (timestamp_ms - since_ms) // 3_600_000))
            return keys[int(index)]

        return (
            {
                "days": 1,
                "resolution": "hour",
                "since": iso_timestamp(since_ms / 1000),
                "until": iso_timestamp(until_ms / 1000),
                "label": "Past 24 hours",
            },
            keys,
            hourly_key,
        )

    now_local = datetime.fromtimestamp(now_ms / 1000, tz=zone)
    last_day = now_local.date()
    first_day = last_day - timedelta(days=days - 1)
    keys = [(first_day + timedelta(days=index)).isoformat() for index in range(days)]
    allowed = set(keys)

    def daily_key(timestamp_ms: int) -> str | None:
        key = datetime.fromtimestamp(timestamp_ms / 1000, tz=zone).date().isoformat()
        return key if key in allowed else None

    return (
        {
            "days": days,
            "resolution": "day",
            "since": keys[0],
            "until": keys[-1],
            "label": f"Past {days} days",
        },
        keys,
        daily_key,
    )


def aggregate_usage(
    records: list[UsageRecord],
    provider_ids: list[str],
    days: int,
    now_ms: int,
    rates: dict[str, tuple[float, float, float, float]],
    zone_name: str | None = None,
) -> dict[str, Any]:
    zone = local_zone(zone_name)
    period, period_keys, bucket_for = period_window(days, now_ms, zone)
    provider_cells = {provider: empty_cell() for provider in provider_ids}
    model_cells: dict[tuple[str, str], dict[str, Any]] = {}
    period_cells = {key: empty_cell() for key in period_keys}
    period_provider_cells = {
        key: {provider: empty_cell() for provider in provider_ids} for key in period_keys
    }
    total = empty_cell()
    seen: set[str] = set()

    for record in records:
        if record.provider not in provider_cells:
            continue
        if record.dedupe_key is not None:
            if record.dedupe_key in seen:
                continue
            seen.add(record.dedupe_key)
        bucket = bucket_for(record.timestamp_ms)
        if bucket is None:
            continue
        provider_cell = provider_cells[record.provider]
        model_key = (record.provider, record.model)
        if model_key not in model_cells and len(model_cells) >= MAX_MODEL_GROUPS:
            model_key = (record.provider, "<other>")
        model_cell = model_cells.setdefault(model_key, empty_cell())
        add_record(provider_cell, record, rates)
        add_record(model_cell, record, rates)
        add_record(period_cells[bucket], record, rates)
        add_record(period_provider_cells[bucket][record.provider], record, rates)
        add_record(total, record, rates)

    providers: list[dict[str, Any]] = []
    for provider in provider_ids:
        providers.append({"id": provider, "name": PROVIDER_NAMES[provider], **finish_cell(provider_cells[provider])})

    models = [
        {
            "provider": provider,
            "providerName": PROVIDER_NAMES[provider],
            "model": (
                "Unknown model" if model == "<unattributed>"
                else "Other models" if model == "<other>"
                else model
            ),
            **finish_cell(cell),
        }
        for (provider, model), cell in model_cells.items()
    ]
    models.sort(
        key=lambda row: (
            row["costUsd"] is not None,
            row["costUsd"] or 0,
            row["totalTokens"],
        ),
        reverse=True,
    )

    periods: list[dict[str, Any]] = []
    for key in period_keys:
        periods.append(
            {
                "start": key,
                **finish_cell(period_cells[key]),
                "providers": [
                    {"id": provider, **finish_cell(period_provider_cells[key][provider])}
                    for provider in provider_ids
                ],
            }
        )
    return {
        "period": period,
        "totals": finish_cell(total),
        "providers": providers,
        "models": models,
        "periods": periods,
    }


def parse_provider_ids(value: str) -> list[str]:
    requested = {item.strip().lower() for item in value.split(",") if item.strip()}
    return [provider for provider in PROVIDER_ORDER if provider in requested]


def build_payload(
    provider_ids: list[str],
    days: int,
    timeout: float,
    state_dir: Path | None,
    now_ms: int | None = None,
    zone_name: str | None = None,
    rates_override: tuple[dict[str, tuple[float, float, float, float]], dict[str, Any]] | None = None,
) -> dict[str, Any]:
    started = time.monotonic()
    stamp_ms = int(time.time() * 1000) if now_ms is None else int(now_ms)
    records, coverage = scan_transcripts(provider_ids, state_dir, stamp_ms)
    needs_rates = any(
        record.provider != "kimi" and record.reported_cost_usd is None for record in records
    )
    if rates_override is not None:
        rates, pricing = rates_override
    elif needs_rates:
        rates, pricing = load_rates(state_dir, timeout, stamp_ms // 1000)
    else:
        rates = {}
        pricing = {
            "status": "unavailable" if any(record.provider == "kimi" for record in records) else "notNeeded",
            "source": LITELLM_RATES_URL,
            "fetchedAt": None,
            "knownModels": 0,
            "message": "No model-price lookup was needed for this result.",
        }
    result = aggregate_usage(records, provider_ids, days, stamp_ms, rates, zone_name)
    sessions_by_provider = {row["id"]: row["sessions"] for row in result["providers"]}
    coverage_by_provider = {row["id"]: row for row in coverage}
    for source in coverage:
        source["sessions"] = sessions_by_provider.get(source["id"], 0)
    for provider in result["providers"]:
        source = coverage_by_provider.get(provider["id"], {})
        provider["status"] = source.get("status", "missing")
        provider["message"] = source.get("message", "")
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": iso_timestamp(stamp_ms / 1000),
        "pricing": pricing,
        "coverage": coverage,
        "scanDurationMs": max(0, int((time.monotonic() - started) * 1000)),
        **result,
    }


def clean_error(value: Any) -> str:
    return clean_message(value)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--providers", default=",".join(PROVIDER_ORDER))
    parser.add_argument("--days", type=int, choices=(1, 7, 30), default=30)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--time-zone")
    args = parser.parse_args(argv)
    try:
        payload = build_payload(
            parse_provider_ids(args.providers),
            args.days,
            max(1.0, min(20.0, args.timeout)),
            args.state_dir,
            zone_name=args.time_zone,
        )
    except Exception as exc:
        payload = {
            "schemaVersion": SCHEMA_VERSION,
            "generatedAt": iso_timestamp(time.time()),
            "backendError": clean_error(exc),
            "pricing": {
                "status": "unavailable",
                "source": LITELLM_RATES_URL,
                "fetchedAt": None,
                "knownModels": 0,
                "message": "Pricing could not be loaded.",
            },
            "coverage": [],
            "period": {"days": args.days, "resolution": "day", "since": "", "until": "", "label": ""},
            "totals": finish_cell(empty_cell()),
            "providers": [],
            "models": [],
            "periods": [],
            "scanDurationMs": 0,
        }
    json.dump(payload, os.sys.stdout, separators=(",", ":"))
    os.sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
