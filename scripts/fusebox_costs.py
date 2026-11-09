"""Bounded, read-only Fusebox usage analytics for the Costs view.

Fusebox prices every recorded response itself (USD nanounits; null means
unpriced). This module reads only aggregate dashboard metrics for daily
periods and combined observations for the past 24 hours. Account, client,
request and response identifiers are discarded; only provider buckets, model
names, timestamps, token counts and Fusebox's estimates cross into plugin
state or QML.
"""
from __future__ import annotations

import hashlib
import http.client
import json
import os
import re
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

from model_usage_common import atomic_write_json, clean_message

SNAPSHOT_VERSION = 1
MAX_DASHBOARD_BYTES = 8 * 1024 * 1024
MAX_PAGE_BYTES = 4 * 1024 * 1024
PAGE_SIZE = 500
MAX_PAGES = 40  # 20,000 responses in 24 hours, below the transcript record ceiling.
MAX_PROVIDERS = 16
MAX_ROWS = 50_000
MAX_MODEL_CHARS = 256
SNAPSHOT_MAX_AGE_MS = 32 * 86_400_000
PROVIDER_RE = re.compile(r"[a-z0-9][a-z0-9_.-]{0,63}")
# Fusebox records Claude subscriptions as anthropic and ChatGPT as openai.
# Keep them in the plugin's existing buckets so every source charts together.
BUCKETS = {"anthropic": "claude", "openai": "codex"}
NAMES = {
    "antigravity": "Antigravity", "devin": "Devin", "gemini": "Gemini", "grok": "Grok",
    "kimi": "Kimi Code", "meta": "Meta", "vertex": "Vertex AI", "xai": "xAI",
}


class FuseboxError(ValueError):
    pass


def bucket(provider):
    return BUCKETS.get(provider, provider)


def provider_name(provider):
    return NAMES.get(provider, provider.replace("-", " ").replace("_", " ").title())


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def normalize_url(address):
    try:
        if not isinstance(address, str) or any(ord(c) < 32 or ord(c) == 127 for c in address):
            raise ValueError
        parts = urllib.parse.urlsplit(address.strip())
        parts.port  # Validate the port without echoing a possibly secret URL.
        if (parts.scheme not in ("http", "https") or not parts.hostname
                or parts.username is not None or parts.password is not None
                or parts.query or parts.fragment):
            raise ValueError
        path = parts.path.rstrip("/")
        for suffix in ("/management.html", "/v0/management/auth-files", "/v0/management"):
            if path.endswith(suffix):
                path = path[:-len(suffix)].rstrip("/")
                break
        if any(segment in (".", "..") for segment in urllib.parse.unquote(path).split("/")):
            raise ValueError
        return urllib.parse.urlunsplit((parts.scheme, parts.netloc.lower(), path, "", ""))
    except (TypeError, ValueError):
        raise FuseboxError("Enter the Fusebox server HTTP(S) URL without credentials, query, or fragment.") from None


def read_key(path):
    if not path:
        raise FuseboxError("Enter the Fusebox management key in Costs settings.")
    try:
        fd = os.open(Path(path).expanduser(), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError
            raw = os.read(fd, 8193)
        finally:
            os.close(fd)
        value = raw.decode("ascii").strip()
        if not value or len(raw) > 8192 or any(ord(c) < 33 or ord(c) > 126 for c in value):
            raise ValueError
        return value
    except (OSError, ValueError, UnicodeError):
        raise FuseboxError("The Fusebox key file must be private (0600), owned by you, and contain the management key.") from None


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # The management key must never follow a redirect to another origin.
        return None


class Client:
    def __init__(self, url, key, timeout):
        self.url = normalize_url(url)
        self.key = key
        self.deadline = time.monotonic() + timeout

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise FuseboxError("Fusebox usage request timed out.")
        return remaining

    def get(self, path, query, limit):
        request = urllib.request.Request(
            self.url + "/api/usage/" + path + "?" + urllib.parse.urlencode(query),
            headers={"Authorization": "Bearer " + self.key, "Accept": "application/json"})
        try:
            with urllib.request.build_opener(NoRedirects()).open(request, timeout=self.remaining()) as response:
                parts, size = [], 0
                while size <= limit:
                    self.remaining()
                    part = response.read1(min(65536, limit + 1 - size))
                    if not part:
                        break
                    parts.append(part)
                    size += len(part)
        except urllib.error.HTTPError as exc:
            exc.close()
            if exc.code in (401, 403):
                raise FuseboxError("Fusebox rejected the management key or remote management access.") from None
            if exc.code == 404:
                raise FuseboxError("This server does not provide Fusebox usage analytics. Update Fusebox or check the URL.") from None
            if exc.code == 503:
                raise FuseboxError("Fusebox usage analytics is busy or disabled. Check Usage in its dashboard.") from None
            if exc.code == 504:
                raise FuseboxError("Fusebox usage query timed out. Try a shorter period.") from None
            raise FuseboxError(f"Fusebox usage endpoint returned HTTP {exc.code}.") from None
        if size > limit:
            raise FuseboxError("Fusebox returned unexpectedly large usage data.")
        try:
            return json.loads(b"".join(parts))
        except (ValueError, UnicodeDecodeError, RecursionError):
            raise FuseboxError("Fusebox returned unreadable usage data.") from None


def count(value, maximum=10**15):
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= maximum:
        raise ValueError
    return value


def optional_count(value):
    return 0 if value is None else count(value)


def nanos(value):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or abs(value) > 10**21:
        raise ValueError
    return value


def model_name(value):
    if value is None:
        return "<unattributed>"
    if not isinstance(value, str):
        raise ValueError
    value = value.strip()[:MAX_MODEL_CHARS]
    return value or "<unattributed>"


def provider_id(value):
    if not isinstance(value, str) or not PROVIDER_RE.fullmatch(value):
        raise ValueError
    return value


def tokens(raw):
    if raw is None:
        raw = {}
    if not isinstance(raw, dict):
        raise ValueError
    values = [optional_count(raw.get(name)) for name in ("input", "cache_read", "cache_write", "output", "reasoning")]
    values[4] = min(values[4], values[3])  # Reasoning is a detail within output.
    return values


def split(provider, timestamp, model, aggregate):
    """Fusebox aggregates priced and unpriced responses together. Keep the
    priced responses' estimate and count the unpriced remainder separately."""
    observations = count(aggregate.get("observations"))
    unpriced = min(observations, count(aggregate.get("unpriced", 0)))
    cost = nanos(aggregate.get("estimated_cost_nanos"))
    usage = tokens(aggregate.get("tokens"))
    priced = observations - unpriced if cost is not None else 0
    rows = []
    if priced:
        rows.append([provider, timestamp, model, priced, cost, *usage])
    if observations - priced:
        rows.append([provider, timestamp, model, observations - priced, None,
                     *(usage if not priced else [0, 0, 0, 0, 0])])
    return rows


def local_midnight_ms(day, zone):
    return int(datetime.combine(day, datetime.min.time(), zone).timestamp() * 1000)


def daily(client, start_day, end_day, zone_name, zone):
    """One dashboard read per provider: trends are by provider or by model, and
    the plugin needs both. Filtered totals must reconcile with the unfiltered read."""
    base = {"start": start_day.isoformat(), "end": (end_day + timedelta(days=1)).isoformat(),
            "timezone": zone_name, "stack": "model"}
    overview = client.get("dashboard", base, MAX_DASHBOARD_BYTES)
    combined = overview.get("combined") if isinstance(overview, dict) else None
    facets = overview.get("facets") if isinstance(overview, dict) else None
    if not isinstance(combined, dict) or not isinstance(combined.get("totals"), dict) or not isinstance(facets, dict):
        raise FuseboxError("Fusebox returned an unexpected usage dashboard.")
    providers = sorted({provider_id(p) for p in facets.get("providers") or []})
    if len(providers) > MAX_PROVIDERS:
        raise FuseboxError("Fusebox reported too many usage providers.")

    def read(provider):
        if len(providers) == 1:
            return provider, overview
        return provider, client.get("dashboard", {**base, "provider": provider}, MAX_DASHBOARD_BYTES)

    with ThreadPoolExecutor(max_workers=4) as pool:
        documents = list(pool.map(read, providers)) if providers else []
    rows, observed = [], 0
    for provider, document in documents:
        trend = document.get("combined", {}).get("trend") if isinstance(document, dict) else None
        if not isinstance(trend, list) or len(trend) > MAX_ROWS:
            raise FuseboxError("Fusebox returned an unexpected usage trend.")
        for row in trend:
            if not isinstance(row, dict):
                raise ValueError
            day = date.fromisoformat(row.get("date"))
            if not start_day <= day <= end_day:
                continue
            observed += count(row.get("observations"))
            rows.extend(split(bucket(provider), local_midnight_ms(day, zone), model_name(row.get("group")), row))
        if len(rows) > MAX_ROWS:
            raise FuseboxError("Fusebox usage exceeds the record limit. Select a shorter period.")
    totals = combined["totals"]
    expected = count(totals.get("observations", 0))
    notes = []
    status = "ok" if observed == expected else "partial"
    if status == "partial":
        notes.append("Fusebox provider totals did not reconcile; some usage may be missing.")
    weak = optional_count(totals.get("weak_identity"))
    if weak:
        notes.append(f"{weak:,} imported Fusebox entries have no response ID and may repeat proxied requests.")
    pricing = overview.get("pricing") if isinstance(overview.get("pricing"), dict) else {}
    return rows, status, notes, pricing


def hourly(client, since_ms, until_ms, zone_name, zone):
    """Past 24 hours from combined observations, newest first, in bounded pages."""
    start_day = datetime.fromtimestamp(since_ms / 1000, zone).date()
    end_day = datetime.fromtimestamp(until_ms / 1000, zone).date() + timedelta(days=1)
    query = {"start": start_day.isoformat(), "end": end_day.isoformat(), "timezone": zone_name,
             "view": "combined", "limit": PAGE_SIZE}
    rows, status, seen = [], "ok", set()
    for page in range(MAX_PAGES):
        document = client.get("observations", {**query, "offset": page * PAGE_SIZE}, MAX_PAGE_BYTES)
        items = document.get("items") if isinstance(document, dict) else None
        if not isinstance(items, list) or len(items) > PAGE_SIZE:
            raise FuseboxError("Fusebox returned unexpected usage records.")
        older = False
        for item in items:
            if not isinstance(item, dict):
                raise ValueError
            at = count(item.get("event_at_ms"), 10**14)
            if at < since_ms:
                older = True
                continue
            identity = item.get("id")
            if at > until_ms or identity in seen:
                continue  # New responses shift later pages; never count one twice.
            if identity is not None:
                seen.add(count(identity, 2**63))
            model = item.get("actual_model") if item.get("actual_model") is not None else item.get("requested_model")
            usage = tokens(item.get("tokens"))
            cost = nanos(item.get("estimated_cost_nanos"))
            rows.append([bucket(provider_id(item.get("provider"))), at, model_name(model), 1, cost, *usage])
        total = count(document.get("total", 0))
        if older or not items or (page + 1) * PAGE_SIZE >= total:
            break
    else:
        status = "partial"
    notes = ["More than 20,000 Fusebox responses in 24 hours; the oldest are not shown."] if status == "partial" else []
    return rows, status, notes, {}


def load_private_json(path, limit):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_size > limit):
                return None
            raw = os.read(fd, limit + 1)
        finally:
            os.close(fd)
        return json.loads(raw) if len(raw) <= limit else None
    except (OSError, ValueError, RecursionError):
        return None


def validate_rows(rows):
    if not isinstance(rows, list) or len(rows) > MAX_ROWS:
        raise ValueError
    for row in rows:
        if not isinstance(row, list) or len(row) != 10:
            raise ValueError
        provider_id(row[0])
        count(row[1], 10**14)
        if not isinstance(row[2], str) or not 0 < len(row[2]) <= MAX_MODEL_CHARS:
            raise ValueError
        count(row[3])
        nanos(row[4])
        for value in row[5:]:
            count(value)
    return rows


def collect(config, days, since_ms, until_ms, zone_name, zone, state_dir, timeout):
    """Return (summary, state, error). A failed read reuses the last private
    snapshot for this server, period and timezone, labelled stale."""
    try:
        key = read_key(config.get("keyFile", ""))
        url = normalize_url(config.get("url", ""))
    except FuseboxError as exc:
        return None, "unavailable", str(exc)
    cache = state_dir / ("fusebox-usage-" + digest([url, digest(key), days, zone_name]) + ".json")
    error = ""
    try:
        client = Client(url, key, timeout)
        if days == 1:
            rows, status, notes, pricing = hourly(client, since_ms, until_ms, zone_name, zone)
        else:
            start_day = datetime.fromtimestamp(since_ms / 1000, zone).date()
            end_day = datetime.fromtimestamp(until_ms / 1000, zone).date()
            rows, status, notes, pricing = daily(client, start_day, end_day, zone_name, zone)
        summary = {"readAt": int(time.time() * 1000), "status": status, "notes": notes, "rows": rows,
                   "pricing": {"version": clean_message(pricing.get("version") or ""),
                               "basis": clean_message(pricing.get("basis") or "")}}
        try:
            atomic_write_json(cache, {"version": SNAPSHOT_VERSION, "summary": summary})
        except OSError:
            pass
        return summary, "fresh", ""
    except FuseboxError as exc:
        error = str(exc)
    except (OSError, ValueError, TypeError, AttributeError, KeyError, OverflowError,
            urllib.error.URLError, http.client.HTTPException, RecursionError):
        error = "Could not read Fusebox usage. Check the server URL, network, and TLS certificate."
    saved = load_private_json(cache, MAX_DASHBOARD_BYTES * 2)
    if isinstance(saved, dict) and saved.get("version") == SNAPSHOT_VERSION:
        try:
            summary = saved["summary"]
            read_at = count(summary["readAt"], 10**14)
            if time.time() * 1000 - read_at <= SNAPSHOT_MAX_AGE_MS:
                return {"readAt": read_at, "status": "stale", "rows": validate_rows(summary["rows"]),
                        "notes": [clean_message(n) for n in summary.get("notes", [])][:4],
                        "pricing": summary.get("pricing") if isinstance(summary.get("pricing"), dict) else {}}, "stale", error
        except (ValueError, KeyError, TypeError, AttributeError, OverflowError):
            pass
    return None, "unavailable", clean_message(error)
