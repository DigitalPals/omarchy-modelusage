#!/usr/bin/env python3
"""Test a Fusebox / CLIProxyAPI connection before its settings are saved.

Reads one JSON request on stdin so that a draft management key never appears
in process arguments:

    {"url": "...", "key": "draft key or empty", "keyFile": "saved key file or empty",
     "requireFusebox": false}

Prints one JSON result. Only the account inventory is read; no provider or
upstream calls are made, and the key is never printed.
"""

from __future__ import annotations

import json
import sys
import time

from model_usage_common import ProviderFailure
import fusebox_costs
import proxy_connection as connection

MAX_REQUEST_BYTES = 65536


def plural(count: int, word: str) -> str:
    return f"{count} {word}" + ("" if count == 1 else "s")


def describe(implementation: str, entries: list[dict]) -> tuple[str, list[dict]]:
    counts: dict[str, int] = {}
    for entry in entries:
        provider = str(entry.get("provider") or entry.get("type") or "unknown").lower()
        counts[provider] = counts.get(provider, 0) + 1
    providers = [{"id": provider, "accounts": count} for provider, count in sorted(counts.items())]
    name = connection.implementation_name(implementation)
    if not entries:
        return f"Connected to {name} · no managed accounts yet.", providers
    return (f"Connected to {name} · {plural(len(entries), 'account')} across "
            f"{plural(len(providers), 'provider')}."), providers


def run(request: dict, timeout: float = 10) -> dict:
    """Test the account API; on Fusebox, also the usage history Costs reads.

    `requireFusebox` (a separate Costs server) fails without usage history;
    for the Limits connection it is reported beside a passing result."""
    result = {"schemaVersion": 1, "ok": False, "implementation": "", "providers": [], "accounts": 0, "message": ""}
    started = time.monotonic()
    try:
        url = request.get("url")
        if not isinstance(url, str) or not url.strip():
            raise ProviderFailure("config", "Enter the server URL.")
        draft = request.get("key")
        if isinstance(draft, str) and draft.strip():
            key = draft.strip()
            if not connection.valid_secret(key):
                raise ProviderFailure("config", "Enter a nonempty management API key using ASCII characters.")
        else:
            key_file = request.get("keyFile")
            key = connection.read_key(key_file if isinstance(key_file, str) else "")
        client = connection.ProxyClient(url, key)
        entries = client.accounts(timeout)
        result["implementation"] = client.implementation
        if request.get("requireFusebox") is True and client.implementation != "rust":
            result["message"] = "This server is CLIProxyAPI, which records no usage history. Costs needs Fusebox."
            return result
        result["message"], result["providers"] = describe(client.implementation, entries)
        result["accounts"] = len(entries)
        if client.implementation == "rust":
            # The panel stops waiting after 15 seconds; keep both checks inside that.
            usage_ok, usage_message = fusebox_costs.probe(url, key, max(1.0, min(5.0, 13 - (time.monotonic() - started))))
            if request.get("requireFusebox") is True and not usage_ok:
                result["message"] = usage_message
                return result
            result["usage"] = {"ok": usage_ok, "message": usage_message}
        result["ok"] = True
    except ProviderFailure as exc:
        detail = getattr(exc, "detail", "")
        result["message"] = exc.message + (" " + detail if detail else "")
    except Exception:
        # Never include exception text: it may contain request details.
        result["message"] = "Could not test the connection."
    return result


def main() -> int:
    try:
        request = json.loads(sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)[:MAX_REQUEST_BYTES])
        if not isinstance(request, dict):
            raise ValueError
    except (ValueError, UnicodeDecodeError, RecursionError):
        request = {}
    print(json.dumps(run(request)), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
