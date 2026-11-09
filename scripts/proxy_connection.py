"""Shared Fusebox / CLIProxyAPI connection handling for Model Usage backends.

Every backend that talks to a quota proxy (quotas, account activity, live
activity, banked resets, Fusebox costs, connection tests) uses these helpers
so that URLs, private key files, redirects and implementation detection behave
identically everywhere. Keys are never printed or included in errors.
"""

from __future__ import annotations

import json
import os
import re
import stat
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from model_usage_common import ProviderFailure, clean_message, number

DEFAULT_URL = "http://127.0.0.1:8317"
# Dashboard and management API URLs are accepted and reduced to the server URL.
MANAGEMENT_SUFFIXES = ("/management.html", "/v0/management/auth-files", "/v0/management")
MAX_HTTP_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_SECRET_BYTES = 8192
IMPLEMENTATIONS = ("go", "rust")
EMAIL_PATTERN = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
# Statuses meaning "this API is not served here, or not to this key". Either
# implementation may answer the other's paths with one of them.
ROUTE_ABSENT = (404, 405)
AUTH_REJECTED = (401, 403)


class SettingError(ValueError):
    """An invalid connection setting; callers supply their own display text."""


def implementation_name(implementation: str) -> str:
    if implementation == "rust":
        return "Fusebox"
    if implementation == "go":
        return "CLIProxyAPI"
    return "Fusebox / CLIProxyAPI"


def normalize_url(address: Any, *, suffixes: tuple[str, ...] = MANAGEMENT_SUFFIXES,
                  lowercase_host: bool = False) -> str:
    """Return an HTTP(S) base URL without credentials, query, fragment or dot segments."""
    try:
        if not isinstance(address, str) or any(ord(char) < 32 or ord(char) == 127 for char in address):
            raise ValueError
        parts = urllib.parse.urlsplit(address.strip())
        parts.port  # Validate the port without echoing a possibly secret URL.
        if (parts.scheme not in ("http", "https") or not parts.hostname
                or parts.username is not None or parts.password is not None
                or parts.query or parts.fragment):
            raise ValueError
        path = parts.path.rstrip("/")
        for suffix in suffixes:
            if path.endswith(suffix):
                path = path[:-len(suffix)].rstrip("/")
                break
        if any(segment in (".", "..") for segment in urllib.parse.unquote(path).split("/")):
            raise ValueError
        netloc = parts.netloc.lower() if lowercase_host else parts.netloc
        return urllib.parse.urlunsplit((parts.scheme, netloc, path, "", ""))
    except (TypeError, ValueError, AttributeError):
        raise SettingError("invalid URL") from None


def server_url(address: Any) -> str:
    try:
        return normalize_url(address)
    except SettingError:
        raise ProviderFailure("config", "Proxy URL must be an HTTP(S) server or management URL without credentials, query, or fragment.") from None


def default_key_path() -> Path:
    override = os.environ.get("CLIPROXY_API_KEY_FILE")
    if override:
        return Path(override).expanduser()
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config"))
    return config_home / "omarchy" / "model-usage" / "cliproxy.key"


def key_path(value: Any) -> Path:
    """The configured key file, or the documented default when none is set."""
    text = str(value or "").strip() if not isinstance(value, Path) else str(value)
    return Path(text).expanduser() if text else default_key_path()


def valid_secret(value: str, *, ascii_only: bool = True) -> bool:
    """The same rule management-key.py applies when it saves a secret."""
    if not value or len(value) > MAX_SECRET_BYTES - 1:
        return False
    return all(32 <= ord(char) and (ord(char) <= 126 or not ascii_only) and ord(char) != 127
               for char in value)


def read_secret(path: Path | str, *, ascii_only: bool = True) -> str:
    """Read one secret from a regular, private file owned by this user."""
    try:
        # NONBLOCK also prevents a misconfigured FIFO from stalling the poll.
        fd = os.open(Path(path).expanduser(), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise SettingError("unsafe file")
            raw = os.read(fd, MAX_SECRET_BYTES + 1)
        finally:
            os.close(fd)
    except OSError:
        raise SettingError("unreadable") from None
    try:
        value = raw.decode("utf-8").strip()
    except UnicodeDecodeError:
        value = ""
    if len(raw) > MAX_SECRET_BYTES or not valid_secret(value, ascii_only=ascii_only):
        raise SettingError("invalid secret")
    return value


def read_key(path: Path | str | None) -> str:
    resolved = key_path(path)
    try:
        return read_secret(resolved)
    except SettingError as exc:
        if str(exc) == "unsafe file":
            raise ProviderFailure("config", "Proxy key file must be a regular file owned by you with mode 0600.") from None
        if str(exc) == "unreadable":
            raise ProviderFailure("config", "Proxy management key could not be read. Enter your Management API key in widget settings.") from None
        raise ProviderFailure("config", "Proxy management key file must contain one nonempty ASCII key.") from None


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Authenticated requests must never forward credentials to a redirect.
        return None


def open_url(request: urllib.request.Request, timeout: float):
    return urllib.request.build_opener(NoRedirects()).open(request, timeout=timeout)


def _status(error: ProviderFailure) -> int | None:
    return getattr(error, "http_status", None)


def _rank(error: ProviderFailure) -> int:
    """How much a failed probe says about the server: an absent route says the
    least, an authenticated or server-side answer says the most."""
    status = _status(error)
    if status in ROUTE_ABSENT:
        return 0
    if status in AUTH_REJECTED:
        return 1
    return 2


class ProxyClient:
    """Management API client for Fusebox (Rust) and CLIProxyAPI (Go).

    `implementation` is a hint from an earlier detection. It selects which API
    is tried first; the other is still tried when the first is absent or
    rejects the key, so a server swapped behind the same URL is found again.
    `self.implementation` stays "auto" until an inventory proves which server
    answered.
    """

    def __init__(self, address: str, key: str, implementation: str = "auto"):
        self.base_url = server_url(address)
        self.key = key
        self.preferred = implementation if implementation in IMPLEMENTATIONS else "auto"
        self.implementation = "auto"

    @property
    def name(self) -> str:
        return implementation_name(self.implementation)

    def request(self, path: str, timeout: float, payload: dict[str, Any] | None = None,
                *, native: bool = False) -> Any:
        name = "Fusebox" if native or self.implementation == "rust" else "CLIProxyAPI"
        headers = {"Authorization": "Bearer " + self.key, "Accept": "application/json"}
        body = None
        if payload is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(payload).encode("utf-8")
        prefix = "/api/" if native else "/v0/management/"
        request = urllib.request.Request(self.base_url + prefix + path, data=body, headers=headers)
        try:
            with open_url(request, timeout) as response:
                raw = response.read(MAX_HTTP_RESPONSE_BYTES + 1)
        except urllib.error.HTTPError as exc:
            detail = ""
            if native:
                # Fusebox explains refusals as {"error": "..."}; keep only that text.
                try:
                    reason = json.loads(exc.read(4097)[:4096]).get("error")
                    detail = clean_message(reason)[:200] if isinstance(reason, str) else ""
                except (ValueError, AttributeError, OSError, RecursionError):
                    detail = ""
            exc.close()
            if exc.code in AUTH_REJECTED:
                error = ProviderFailure("config", f"{name} rejected the management key or remote management access.")
            elif exc.code == 429:
                error = ProviderFailure("rate_limited", f"{name} is rate limiting management requests.")
            else:
                error = ProviderFailure("http", f"{name} management endpoint returned HTTP {exc.code}.")
            error.http_status = exc.code
            error.detail = EMAIL_PATTERN.sub("[email]", detail)
            raise error from None
        except (TimeoutError, urllib.error.URLError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            if isinstance(reason, TimeoutError) or "timed out" in str(reason).lower():
                raise ProviderFailure("timeout", f"{name} usage request timed out.") from None
            raise ProviderFailure("network", f"Could not reach {name}. Check the server URL, network, and TLS certificate.") from None
        if len(raw) > MAX_HTTP_RESPONSE_BYTES:
            raise ProviderFailure("malformed", f"{name} returned unexpectedly large usage data.")
        try:
            return json.loads(raw)
        except (ValueError, UnicodeDecodeError, RecursionError):
            raise ProviderFailure("malformed", f"{name} returned unreadable JSON.") from None

    def accounts(self, timeout: float) -> list[dict[str, Any]]:
        """Return the managed account inventory, detecting the implementation."""
        if self.implementation == "rust":
            return self.rust_accounts(timeout)
        if self.implementation == "go":
            return self.go_accounts(timeout)
        deadline = time.monotonic() + timeout
        readers = {"go": self.go_accounts, "rust": self.rust_accounts}
        order = ("go", "rust") if self.preferred == "go" else ("rust", "go")
        try:
            return readers[order[0]](timeout)
        except ProviderFailure as first:
            # Outages, timeouts and rate limits are not reinterpreted as the
            # other implementation; only an absent route, a rejected key, or a
            # response that is not this implementation's inventory are.
            if _status(first) not in (*ROUTE_ABSENT, *AUTH_REJECTED) and first.kind != "malformed":
                raise
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProviderFailure("timeout", "Fusebox / CLIProxyAPI account discovery timed out.") from None
            try:
                return readers[order[1]](remaining)
            except ProviderFailure as second:
                raise self._detection_failure(first, second) from None

    @staticmethod
    def _detection_failure(first: ProviderFailure, second: ProviderFailure) -> ProviderFailure:
        if _status(first) in ROUTE_ABSENT and _status(second) in ROUTE_ABSENT:
            error = ProviderFailure("http", "No Fusebox or CLIProxyAPI management API was found at this URL. Check the URL and that remote management is enabled.")
            error.http_status = _status(second)
            return error
        if _status(first) in AUTH_REJECTED and _status(second) in AUTH_REJECTED:
            error = ProviderFailure("config", "Fusebox / CLIProxyAPI rejected the management key or remote management access.")
            error.http_status = _status(second)
            return error
        return first if _rank(first) >= _rank(second) else second

    def go_accounts(self, timeout: float) -> list[dict[str, Any]]:
        payload = self.request("auth-files", timeout)
        if not isinstance(payload, dict) or not isinstance(payload.get("files"), list):
            raise ProviderFailure("malformed", "CLIProxyAPI returned an invalid account list.")
        self.implementation = "go"
        return [entry for entry in payload["files"] if isinstance(entry, dict)]

    def rust_accounts(self, timeout: float) -> list[dict[str, Any]]:
        payload = self.request("accounts", timeout, native=True)
        if not isinstance(payload, list) or len(payload) > 4096:
            raise ProviderFailure("malformed", "Fusebox returned an invalid account list.")
        entries, seen = [], set()
        for row in payload:
            if (not isinstance(row, dict) or not isinstance(row.get("id"), str)
                    or not 0 < len(row["id"]) <= 512 or not isinstance(row.get("provider"), str)
                    or not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", row["provider"])
                    or not isinstance(row.get("disabled"), bool)
                    or row.get("kind") not in ("oauth", "api-key", "service-account")):
                raise ProviderFailure("malformed", "Fusebox returned an invalid account list.")
            identity = row["id"]
            # Go's OAuth auth-file ID is its filename. Keep hashes/private
            # labels stable across a Go-to-Rust migration of the same files.
            if identity.startswith("file:"):
                filename = identity[5:]
                if (not filename or filename in (".", "..") or "/" in filename or "\\" in filename
                        or row.get("file") != filename):
                    raise ProviderFailure("malformed", "Fusebox returned an invalid account identity.")
                identity = filename
            marker = (row["provider"], identity)
            if marker in seen:
                raise ProviderFailure("malformed", "Fusebox returned duplicate account identities.")
            seen.add(marker)
            entries.append(dict(row, id=identity, _native_id=row["id"], _rust=True))
        self.implementation = "rust"
        return entries

    def usage(self, entry: dict[str, Any], url: str, headers: dict[str, str], timeout: float,
              data: dict[str, Any] | None = None) -> Any:
        if entry.get("_rust") is True or self.implementation == "rust":
            raise ProviderFailure("unsupported", "Fusebox does not expose upstream account actions.")
        index = entry.get("auth_index") or entry.get("authIndex")
        if not isinstance(index, str) or not index.strip():
            raise ProviderFailure("config", "CLIProxyAPI account has no auth_index. Check the account in its management panel.")
        request = {
            "auth_index": index, "method": "POST" if data is not None else "GET", "url": url,
            "header": {"Authorization": "Bearer $TOKEN$", "Accept": "application/json", **headers},
        }
        if data is not None:
            request["data"] = json.dumps(data)
        payload = self.request("api-call", timeout, request)
        if not isinstance(payload, dict):
            raise ProviderFailure("malformed", "CLIProxyAPI returned an invalid usage response.")
        status = number(payload.get("status_code", payload.get("statusCode")))
        if status is None or status != int(status):
            raise ProviderFailure("malformed", "CLIProxyAPI omitted the upstream HTTP status.")
        if status in AUTH_REJECTED:
            raise ProviderFailure("expired", "The managed sign-in was rejected. Sign in again through CLIProxyAPI, then refresh.")
        if status == 429:
            raise ProviderFailure("rate_limited", "The managed provider is rate limiting usage checks.")
        if not 200 <= status < 300:
            raise ProviderFailure("http", f"The managed usage endpoint returned HTTP {int(status)}.")
        body = payload.get("body")
        if isinstance(body, dict):
            return body
        try:
            return json.loads(body)
        except (TypeError, ValueError):
            raise ProviderFailure("malformed", "The managed provider returned unreadable usage data.") from None


def add_arguments(parser, *, url_default: str | None = None) -> None:
    """The connection flags shared by every proxy script.

    `--cliproxy-url` and `--cliproxy-key-file` remain accepted aliases.
    """
    if url_default is None:
        url_default = os.environ.get("CLIPROXY_API_URL") or DEFAULT_URL
    parser.add_argument("--proxy-url", "--cliproxy-url", dest="proxy_url", default=url_default)
    parser.add_argument("--proxy-key-file", "--cliproxy-key-file", dest="proxy_key_file", default="")
    parser.add_argument("--implementation", choices=("auto", *IMPLEMENTATIONS), default="auto",
                        help="Implementation detected earlier; tried first, with fallback")


def client_from_args(args) -> ProxyClient:
    return ProxyClient(args.proxy_url, read_key(args.proxy_key_file), args.implementation)
