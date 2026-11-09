"""Read-only CPA Usage Keeper transport for quota account activity."""
from __future__ import annotations

import http.client
import http.cookiejar
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

import proxy_connection as connection

MAX_RESPONSE_BYTES = 32 * 1024 * 1024


class KeeperError(ValueError):
    pass


def normalize_url(value: str) -> str:
    try:
        return connection.normalize_url(value, suffixes=("/api/v1",))
    except connection.SettingError:
        raise KeeperError("Set the CPA Usage Keeper HTTP(S) URL in widget settings.") from None


def read_password(path: Path) -> str:
    try:
        return connection.read_secret(path, ascii_only=False)
    except connection.SettingError:
        raise KeeperError("Keeper password file must be private (0600), owned by you, and contain the login password.") from None


NoRedirects = connection.NoRedirects


class Client:
    def __init__(self, url: str, timeout: float):
        self.url = normalize_url(url)
        self.deadline = time.monotonic() + timeout
        self.opener = urllib.request.build_opener(
            NoRedirects(), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

    def request(self, path: str, payload=None, limit=MAX_RESPONSE_BYTES):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise KeeperError("Keeper activity request timed out.")
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
                        raise KeeperError("Keeper activity request timed out.")
                    chunk = response.read1(min(65536, limit + 1 - size))
                    if not chunk:
                        break
                    chunks.append(chunk)
                    size += len(chunk)
                raw = b"".join(chunks)
            if len(raw) > limit:
                raise KeeperError("Keeper activity exceeds the download limit; check the server.")
            if time.monotonic() > self.deadline:
                raise KeeperError("Keeper activity request timed out.")
            return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as exc:
            code = exc.code
            exc.close()
            if code in (401, 403):
                raise KeeperError("Keeper rejected the login. Check its password in widget settings.") from None
            if code == 404:
                raise KeeperError("Keeper activity endpoint was not found. Use the Keeper URL, not the CLIProxyAPI URL.") from None
            raise KeeperError(f"Keeper activity returned HTTP {code}.") from None
        except (urllib.error.URLError, OSError, TimeoutError, http.client.HTTPException):
            raise KeeperError("Could not reach CPA Usage Keeper. Check the URL, connection, and certificate.") from None
        except (UnicodeError, json.JSONDecodeError):
            raise KeeperError("Keeper returned incomplete or unreadable history.") from None
