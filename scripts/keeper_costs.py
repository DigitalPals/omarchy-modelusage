"""Read archived CPA Usage Keeper events without touching CPA's consuming queue.

Keeper exports canonical input/output totals (cache and reasoning are subsets).
Only sanitized accounting metadata crosses this module's boundary. Its own cost
estimates are deliberately ignored so widget price overrides remain authoritative.
"""
from __future__ import annotations

import hashlib
import http.client
import http.cookiejar
import json
import os
import re
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

MAX_RESPONSE_BYTES = 32 * 1024 * 1024
MAX_EVENTS = 50_000
MAX_PROVIDERS = 64
MAX_TOKENS = 10**15
CLIENT_NAMES = {
    "all": "All apps", "t3": "T3 Code", "codex-cli": "Codex CLI",
    "codex-exec": "Codex Exec", "digital-brain": "Digital Brain", "other": "Other / unknown",
}


def client_id(value):
    """Keep only a known app family, never a raw user agent or client identity."""
    if not isinstance(value, str):
        return "other"
    product = value[:256].lower().split("/", 1)[0].strip()
    return {
        "t3code_desktop": "t3", "t3code": "t3", "t3-code": "t3",
        "codex-tui": "codex-cli", "codex_cli_rs": "codex-cli",
        "codex_exec": "codex-exec", "digital_brain": "digital-brain",
    }.get(product, "other")


class KeeperError(ValueError):
    pass


def normalize_url(value: str) -> str:
    try:
        if any(ord(c) < 32 or ord(c) == 127 for c in value):
            raise ValueError
        url = urllib.parse.urlsplit(value.strip())
        url.port
        if (url.scheme not in ("http", "https") or not url.hostname or url.username is not None
                or url.password is not None or url.query or url.fragment):
            raise ValueError
        path = url.path.rstrip("/")
        if path.endswith("/api/v1"):
            path = path[:-7]
        if any(p in (".", "..") for p in urllib.parse.unquote(path).split("/")):
            raise ValueError
        return urllib.parse.urlunsplit((url.scheme, url.netloc, path, "", ""))
    except (ValueError, TypeError, AttributeError):
        raise KeeperError("Set the CPA Usage Keeper HTTP(S) URL in Costs settings.") from None


def read_password(path: Path) -> str:
    try:
        fd = os.open(path.expanduser(), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ValueError
            raw = os.read(fd, 8193)
        finally:
            os.close(fd)
        value = raw.decode("utf-8").strip()
        if not value or len(raw) > 8192 or any(ord(c) < 32 for c in value):
            raise ValueError
        return value
    except (OSError, ValueError, UnicodeError):
        raise KeeperError("Keeper password file must be private (0600), owned by you, and contain the login password.") from None


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, url: str, timeout: float):
        self.url = normalize_url(url)
        self.deadline = time.monotonic() + timeout
        self.opener = urllib.request.build_opener(
            NoRedirects(), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(self, path: str, payload=None, limit=MAX_RESPONSE_BYTES):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise KeeperError("Keeper history request timed out.")
        headers = {"Accept": "application/json", "X-CPA-Usage-Keeper-Request": "fetch"}
        data = None
        if payload is not None:
            data = json.dumps(payload).encode()
            headers["Content-Type"] = "application/json"
        req = urllib.request.Request(self.url + "/api/v1/" + path, headers=headers, data=data)
        try:
            with self.opener.open(req, timeout=remaining) as response:
                chunks, size = [], 0
                while size <= limit:
                    if time.monotonic() > self.deadline:
                        raise KeeperError("Keeper history request timed out.")
                    chunk = response.read1(min(65536, limit + 1 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                raw = b"".join(chunks)
            if len(raw) > limit:
                raise KeeperError("Keeper history exceeds the download limit; select a shorter period.")
            if time.monotonic() > self.deadline:
                raise KeeperError("Keeper history request timed out.")
            return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            code = exc.code
            exc.close()
            if code in (401, 403):
                raise KeeperError("Keeper rejected the login. Check its password in Costs settings.") from None
            if code == 404:
                raise KeeperError("Keeper history endpoint was not found. Use the Keeper URL, not the CLIProxyAPI URL.") from None
            raise KeeperError(f"Keeper history returned HTTP {code}.") from None
        except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException):
            raise KeeperError("Could not reach CPA Usage Keeper. Check the URL, connection, and certificate.") from None
        except (UnicodeError, json.JSONDecodeError):
            raise KeeperError("Keeper returned incomplete or unreadable history.") from None


def token(row, key):
    value = row.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= MAX_TOKENS:
        raise ValueError
    return value


def normalize_event(row, server_id):
    if not isinstance(row, dict):
        raise ValueError
    timestamp = str(row.get("timestamp", "")).replace("Z", "+00:00")
    # Go exports RFC3339Nano; Python 3.10 accepts at most six fraction digits.
    timestamp = re.sub(r"(\.\d{6})\d+(?=[+-]\d{2}:\d{2}$)", r"\1", timestamp)
    stamp = datetime.fromisoformat(timestamp)
    if stamp.tzinfo is None:
        raise ValueError
    model = row.get("model")
    event_id = row.get("id")
    if not isinstance(model, str) or not model.strip() or len(model) > 256:
        raise ValueError
    if not isinstance(event_id, str) or not event_id or len(event_id) > 256:
        raise ValueError
    # source_type is Keeper's resolved provider, not its credential type.
    provider = row.get("source_type") or "proxy"
    if not isinstance(provider, str) or not re.fullmatch(r"[A-Za-z0-9_.-]{1,64}", provider):
        provider = "proxy"
    provider = provider.lower()
    input_total, output = token(row, "input_tokens"), token(row, "output_tokens")
    cached, creation = token(row, "cache_read_tokens"), token(row, "cache_creation_tokens")
    reasoning, total = token(row, "reasoning_tokens"), token(row, "total_tokens")
    if cached + creation > input_total or reasoning > output or total != input_total + output:
        raise ValueError
    return {
        "provider": provider, "timestamp_ms": int(stamp.timestamp() * 1000),
        "model": model.strip(), "session_id": "",
        "uncached_input": input_total - cached - creation, "cached_input": cached,
        "cache_creation": creation, "output": output, "reasoning": reasoning,
        "reported_cost_usd": None,
        "dedupe_key": hashlib.sha256((server_id + ":" + event_id).encode()).hexdigest(),
        "client_id": client_id(row.get("user_agent")), "origin": "archive",
    }


def collect(url: str, password_file: Path | None, timeout: float, start_ms: int, end_ms: int):
    client = Client(url, timeout)
    logged_in = False
    try:
        if password_file:
            client.request("auth/login", {"password": read_password(password_file)}, limit=64 * 1024)
            logged_in = True
        status = client.request("status", limit=64 * 1024)
        if not isinstance(status, dict):
            raise KeeperError("Keeper returned an invalid collection status.")
        try:
            zone = ZoneInfo(status.get("timezone", "UTC"))
        except (ValueError, TypeError, ZoneInfoNotFoundError):
            raise KeeperError("Keeper must report an IANA timezone such as Europe/Amsterdam or UTC.") from None
        # Keeper's custom hourly API allows only aligned hours in the last day.
        # Export enclosing server-calendar days, then filter exact local bounds.
        query = urllib.parse.urlencode({
            "range": "custom", "unit": "day", "format": "json",
            "start": datetime.fromtimestamp(start_ms / 1000, zone).date().isoformat(),
            "end": datetime.fromtimestamp(end_ms / 1000, zone).date().isoformat(),
        })
        document = client.request("usage/events/export?" + query)
    finally:
        if logged_in:
            # Release this scan's ephemeral session; never persist cookies.
            client.deadline = time.monotonic() + 1
            try:
                client.request("auth/logout", {}, limit=64 * 1024)
            except KeeperError:
                pass
    if not isinstance(status, dict) or not isinstance(document, dict):
        raise KeeperError("Keeper returned an invalid history document.")
    rows = document.get("events")
    if (not isinstance(rows, list) or type(document.get("total_count")) is not int
            or document["total_count"] != len(rows)):
        raise KeeperError("Keeper returned an incomplete history export.")
    if len(rows) > MAX_EVENTS:
        raise KeeperError("Keeper history exceeds 50,000 events; select a shorter period.")
    server_id = hashlib.sha256(client.url.encode()).hexdigest()
    records, seen, providers = [], set(), set()
    skipped = 0
    for row in rows:
        try:
            record = normalize_event(row, server_id)
        except (ValueError, TypeError, OverflowError):
            skipped += 1
            continue
        if not start_ms <= record["timestamp_ms"] <= end_ms:
            continue
        if record["dedupe_key"] in seen:
            continue
        seen.add(record["dedupe_key"])
        providers.add(record["provider"])
        if len(providers) > MAX_PROVIDERS:
            raise KeeperError("Keeper history contains too many providers.")
        records.append(record)
    if rows and skipped == len(rows):
        raise KeeperError("Keeper history has no readable token records. Check the Keeper version and token accounting.")
    messages = ["Saved requests only; earlier activity and collection gaps may be missing."]
    if skipped:
        messages.append(f"Skipped {skipped} invalid token records.")
    healthy = status.get("running") is True and not status.get("last_error") and not status.get("last_warning")
    if not records and not healthy:
        raise KeeperError("Keeper reports a collection problem and has no saved usage in this period.")
    if not healthy:
        messages.append("Keeper reports a collection problem; saved history may be incomplete.")
    return records, {
        # A healthy live connection cannot establish historical completeness.
        "status": "partial",
        "message": " ".join(messages), "skippedRecords": skipped,
        "firstRecordAt": min((r["timestamp_ms"] for r in records), default=None),
        "collectorHealthy": healthy,
    }
