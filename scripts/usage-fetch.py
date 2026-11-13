#!/usr/bin/env python3
"""Fetch AI subscription usage for the Omarchy Model Usage plugin.

The provider CLIs own authentication. This process only reads their existing
credentials, performs read-only usage calls, and emits a provider-neutral JSON
contract. Access tokens are never printed, persisted, or included in errors.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import select
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from model_usage_common import ProviderFailure, atomic_write_json, clean_message, number
from proxy_connection import (
    EMAIL_PATTERN, MAX_HTTP_RESPONSE_BYTES, NoRedirects, ProxyClient,
    normalize_url, read_key,
)
from proxy_connection import add_arguments as add_proxy_arguments

SCHEMA_VERSION = 1
PROVIDER_ORDER = ("claude", "codex", "kimi")
PROVIDER_NAMES = {
    "claude": "Claude Code",
    "codex": "OpenAI Codex",
    "kimi": "Kimi Code",
    "antigravity": "Antigravity",
    "gemini": "Gemini",
    "gemini-cli": "Gemini CLI",
    "qwen": "Qwen",
    "github-copilot": "GitHub Copilot",
    "xai": "xAI",
    "openai": "OpenAI",
    "meta": "Meta",
    "devin": "Devin",
    "vertex": "Vertex AI",
    "openai-compat": "OpenAI-compatible",
}
AUTH_COMMANDS = {
    "claude": "claude auth login",
    "codex": "codex login",
    "kimi": "kimi login",
}

FIVE_HOURS = 5 * 60 * 60
SEVEN_DAYS = 7 * 24 * 60 * 60
HISTORY_RETENTION_SECONDS = SEVEN_DAYS
HISTORY_MAX_SAMPLES = 10_080  # One sample/minute/provider for seven days.
MAX_LOCAL_JSON_BYTES = 2 * 1024 * 1024
MAX_CODEX_RPC_LINE_BYTES = 2 * 1024 * 1024
CODEX_RPC_READ_BYTES = 64 * 1024
MAX_CLIPROXY_ACCOUNTS = 32
MAX_CLIPROXY_PROVIDERS = 32
RUST_QUOTA_STALE_SECONDS = 10 * 60


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def read_json(path: Path, max_bytes: int = MAX_LOCAL_JSON_BYTES) -> Any:
    with path.open("rb") as handle:
        raw = handle.read(max_bytes + 1)
    if len(raw) > max_bytes:
        raise ValueError(f"JSON input exceeds the {max_bytes}-byte limit")
    return json.loads(raw)


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def epoch_seconds(value: Any) -> int | None:
    if value is None or value == "":
        return None
    numeric = number(value)
    if numeric is not None:
        if numeric > 10_000_000_000:
            numeric /= 1000
        return int(numeric) if numeric > 0 else None
    if not isinstance(value, str):
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def base_provider(provider_id: str) -> dict[str, Any]:
    return {
        "id": provider_id,
        "name": PROVIDER_NAMES.get(provider_id, provider_id.replace("-", " ").title()),
        "status": "ok",
        "errorKind": "",
        "message": "",
        "authCommand": AUTH_COMMANDS.get(provider_id, ""),
        "plan": "",
        "account": "",
        "source": "",
        "windows": [],
        "credits": None,
        "notice": "",
        "fetchedAt": now_iso(),
        "history": {"h24": [], "d7": []},
    }


def error_provider(provider_id: str, kind: str, message: str) -> dict[str, Any]:
    result = base_provider(provider_id)
    result.update(status="error", errorKind=kind, message=clean_message(message))
    return result


def http_json(url: str, headers: dict[str, str], timeout: float) -> Any:
    request = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.build_opener(NoRedirects()).open(request, timeout=timeout) as response:
            raw = response.read(MAX_HTTP_RESPONSE_BYTES + 1)
            if len(raw) > MAX_HTTP_RESPONSE_BYTES:
                raise ProviderFailure(
                    "malformed", "The provider returned unexpectedly large usage data."
                )
    except urllib.error.HTTPError as exc:
        exc.close()
        if exc.code in (401, 403):
            raise ProviderFailure("expired", "The saved sign-in is no longer accepted.") from None
        if exc.code == 429:
            raise ProviderFailure("rate_limited", "The provider is rate limiting usage checks.") from None
        raise ProviderFailure("http", f"The usage endpoint returned HTTP {exc.code}.") from None
    except (TimeoutError, urllib.error.URLError, OSError) as exc:
        reason = getattr(exc, "reason", exc)
        if isinstance(reason, TimeoutError) or "timed out" in str(reason).lower():
            raise ProviderFailure("timeout", "The usage request timed out.") from None
        raise ProviderFailure("network", "Could not reach the usage endpoint. Check the connection and TLS certificate.") from None

    try:
        return json.loads(raw)
    except (ValueError, RecursionError):
        raise ProviderFailure("malformed", "The provider returned unreadable usage data.") from None


def make_window(
    window_id: str,
    label: str,
    used: float,
    resets_at: Any = None,
    window_seconds: int | None = None,
    detail: str = "",
    model: str | None = None,
) -> dict[str, Any]:
    normalized = clamp(float(used), 0.0, 100.0)
    window = {
        "id": window_id,
        "label": label,
        "used": round(normalized, 2),
        "remaining": round(100.0 - normalized, 2),
        "resetsAt": epoch_seconds(resets_at),
        "windowSeconds": window_seconds,
        "detail": clean_message(detail),
    }
    # A window limited to one model family names it, lowercase ("fable").
    if model:
        window["model"] = model
    return window


# ---------------------------------------------------------------- Claude


def claude_plan(login: dict[str, Any]) -> str:
    tier = str(login.get("rateLimitTier") or "")
    match = re.search(r"max_(\d+x)", tier, re.IGNORECASE)
    if match:
        return "Claude Max " + match.group(1)
    subscription = str(login.get("subscriptionType") or "").strip()
    if subscription:
        return "Claude " + subscription.replace("_", " ").title()
    return ""


def claude_scope_name(entry: dict[str, Any]) -> str:
    scope = entry.get("scope")
    if not isinstance(scope, dict):
        return ""
    for key in ("model", "surface"):
        value = scope.get(key)
        if isinstance(value, dict):
            label = value.get("display_name") or value.get("name") or value.get("id")
        else:
            label = value
        if isinstance(label, str) and label.strip():
            return label.strip()
    return ""


CLAUDE_MODEL_FAMILY = re.compile(r"\b(fable|mythos|opus|sonnet|haiku)\b", re.IGNORECASE)


def claude_scope_model(entry: dict[str, Any]) -> str | None:
    """The model family a structured limit is scoped to, if it names a known one."""
    scope = entry.get("scope")
    model = scope.get("model") if isinstance(scope, dict) else None
    if isinstance(model, dict):
        names = [model.get(key) for key in ("display_name", "name", "id")]
    else:
        names = [model]
    for name in names:
        match = CLAUDE_MODEL_FAMILY.search(name) if isinstance(name, str) else None
        if match:
            return match[1].lower()
    return None


def parse_claude_usage(payload: Any) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    if not isinstance(payload, dict):
        raise ProviderFailure("malformed", "Claude returned an unexpected usage payload.")

    structured = payload.get("limits")

    def used_percent(value: Any) -> float | None:
        parsed = number(value)
        if parsed is None or parsed < 0:
            return None
        # Both the current flat `utilization` fields and structured `percent`
        # fields are percentages. Inferring a fraction from magnitude makes a
        # legitimate 0.5% snapshot render as 50% immediately after a reset.
        return clamp(parsed, 0, 100)

    windows: list[dict[str, Any]] = []
    seen: set[str] = set()

    def add(window: dict[str, Any]) -> None:
        key = window["label"].casefold()
        if key not in seen:
            seen.add(key)
            windows.append(window)

    flat_rows = (
        ("five_hour", "session", "5 hour limit", FIVE_HOURS, None),
        ("seven_day_oauth_apps", "weekly", "Weekly limit", SEVEN_DAYS, None),
        ("seven_day", "weekly", "Weekly limit", SEVEN_DAYS, None),
        ("seven_day_opus", "opus-weekly", "Opus weekly", SEVEN_DAYS, "opus"),
        ("seven_day_sonnet", "sonnet-weekly", "Sonnet weekly", SEVEN_DAYS, "sonnet"),
    )
    for key, window_id, label, seconds, model in flat_rows:
        row = payload.get(key)
        if not isinstance(row, dict):
            continue
        used = used_percent(row.get("utilization"))
        if used is not None:
            add(make_window(window_id, label, used, row.get("resets_at"), seconds, model=model))

    if isinstance(structured, list):
        for index, row in enumerate(structured):
            if not isinstance(row, dict):
                continue
            used = used_percent(row.get("percent"))
            if used is None:
                continue
            kind = str(row.get("kind") or "").lower()
            group = str(row.get("group") or "").lower()
            scope = claude_scope_name(row)
            if "session" in kind or "hour" in kind or group == "session":
                seconds = FIVE_HOURS
                suffix = "session"
                label = f"{scope} session" if scope else "5 hour limit"
            elif "week" in kind or "day" in kind or group == "weekly":
                seconds = SEVEN_DAYS
                suffix = "weekly"
                label = f"{scope} weekly" if scope else "Weekly limit"
            elif "month" in kind:
                seconds = 30 * 24 * 60 * 60
                suffix = "monthly"
                label = f"{scope} monthly" if scope else "Monthly limit"
            else:
                seconds = None
                suffix = kind.replace("_", " ") or "limit"
                label = scope or suffix.title()
            window_id = re.sub(r"[^a-z0-9]+", "-", f"{scope}-{suffix}".lower()).strip("-")
            add(make_window(window_id or f"limit-{index}", label, used, row.get("resets_at"), seconds,
                            model=claude_scope_model(row)))

    # `seven_day_overage_included` is the weekly allowance of the models that
    # continue on extra usage once it is spent: Fable. Claude Code calls it the
    # "Fable limit" and lists the `limits` entry as "Current week (Fable)", so
    # that entry wins when both are present.
    overage = payload.get("seven_day_overage_included")
    if isinstance(overage, dict) and not any(window.get("model") == "fable" for window in windows):
        used = used_percent(overage.get("utilization"))
        if used is not None:
            add(make_window("fable-weekly", "Fable weekly", used, overage.get("resets_at"), SEVEN_DAYS,
                            model="fable"))

    credits = None
    extra = payload.get("extra_usage")
    if isinstance(extra, dict) and extra.get("is_enabled") is True:
        used_cents = number(extra.get("used_credits"))
        limit_cents = number(extra.get("monthly_limit"))
        unlimited = bool(extra.get("unlimited") or extra.get("is_unlimited"))
        used = used_cents / 100 if used_cents is not None else None
        limit = limit_cents / 100 if limit_cents is not None else None
        credits = {
            "label": "Extra usage",
            "currency": str(extra.get("currency") or "USD").upper(),
            "used": used,
            "limit": limit,
            "remaining": max(0.0, limit - used) if used is not None and limit is not None else None,
            "total": None,
            "unlimited": unlimited,
            "resetCreditsAvailable": None,
        }
    return windows, credits


def fetch_claude(timeout: float) -> dict[str, Any]:
    provider_id = "claude"
    config_dir = Path(os.environ.get("CLAUDE_CONFIG_DIR") or (Path.home() / ".claude")).expanduser()
    credentials_path = config_dir / ".credentials.json"
    if not credentials_path.is_file():
        return error_provider(provider_id, "no_credentials", "No Claude Code sign-in was found.")
    try:
        raw = read_json(credentials_path)
        login = raw.get("claudeAiOauth") if isinstance(raw, dict) else None
        if not isinstance(login, dict) or not isinstance(login.get("accessToken"), str):
            raise ValueError("missing OAuth record")
    except (OSError, ValueError, json.JSONDecodeError):
        return error_provider(provider_id, "no_credentials", "Claude Code credentials could not be read.")

    expires_at = epoch_seconds(login.get("expiresAt"))
    if expires_at is not None and expires_at <= int(time.time()):
        return error_provider(provider_id, "expired", "The Claude Code sign-in has expired.")

    try:
        payload = http_json(
            "https://api.anthropic.com/api/oauth/usage",
            {
                "Authorization": "Bearer " + login["accessToken"],
                "anthropic-beta": "oauth-2025-04-20",
                "Accept": "application/json",
            },
            timeout,
        )
        windows, credits = parse_claude_usage(payload)
    except ProviderFailure as exc:
        return error_provider(provider_id, exc.kind, exc.message)

    account = ""
    try:
        account_data = read_json(Path.home() / ".claude.json")
        oauth_account = account_data.get("oauthAccount") if isinstance(account_data, dict) else None
        if isinstance(oauth_account, dict):
            account = str(oauth_account.get("emailAddress") or "")
    except (OSError, ValueError, RecursionError):
        pass

    result = base_provider(provider_id)
    result.update(
        plan=claude_plan(login),
        account=account,
        source="Claude OAuth usage API",
        windows=windows,
        credits=credits,
    )
    if not windows and credits is None:
        result["notice"] = "Claude returned no active usage limits."
    return result


# ---------------------------------------------------------------- Codex


CODEX_PLAN_LABELS = {
    "free": "ChatGPT Free",
    "go": "ChatGPT Go",
    "plus": "ChatGPT Plus",
    "pro": "ChatGPT Pro",
    "prolite": "ChatGPT Pro Lite",
    "team": "ChatGPT Team",
    "business": "ChatGPT Business",
    "self_serve_business_prolite": "ChatGPT Business Pro Lite",
    "self_serve_business_usage_based": "ChatGPT Business",
    "enterprise": "ChatGPT Enterprise",
    "ent26": "ChatGPT Enterprise",
    "enterprise_cbp_automation": "ChatGPT Enterprise",
    "enterprise_cbp_usage_based": "ChatGPT Enterprise",
    "edu": "ChatGPT Edu",
    "edu_plus": "ChatGPT Edu Plus",
    "edu_pro": "ChatGPT Edu Pro",
}


def runtime_environment() -> dict[str, str]:
    env = os.environ.copy()
    home = Path.home()
    extras = (
        home / ".local" / "bin",
        home / ".npm-global" / "bin",
        home / ".local" / "share" / "mise" / "shims",
    )
    existing = env.get("PATH", "")
    env["PATH"] = os.pathsep.join([existing, *(str(path) for path in extras if path.is_dir())])
    return env


class CodexRpcStream:
    """Incrementally read newline-delimited RPC without unbounded readline buffers."""

    def __init__(
        self,
        process: subprocess.Popen[bytes],
        max_line_bytes: int = MAX_CODEX_RPC_LINE_BYTES,
    ) -> None:
        if process.stdin is None or process.stdout is None:
            raise ProviderFailure("rpc", "Codex app-server did not expose its RPC streams.")
        self.process = process
        self.stdin = process.stdin
        self.stdout = process.stdout
        self.max_line_bytes = max_line_bytes
        self.buffer = bytearray()

    def send(self, message: dict[str, Any]) -> None:
        encoded = json.dumps(message, separators=(",", ":")).encode("utf-8") + b"\n"
        self.stdin.write(encoded)
        self.stdin.flush()

    def read_line(self, deadline: float, method: str) -> bytes:
        while True:
            newline = self.buffer.find(b"\n")
            if newline >= 0:
                if newline > self.max_line_bytes:
                    raise ProviderFailure("malformed", "Codex returned oversized RPC data.")
                line = bytes(self.buffer[:newline])
                del self.buffer[: newline + 1]
                return line
            if len(self.buffer) > self.max_line_bytes:
                raise ProviderFailure("malformed", "Codex returned oversized RPC data.")

            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProviderFailure("timeout", f"Codex app-server timed out during {method}.")
            ready, _, _ = select.select([self.stdout], [], [], min(0.25, remaining))
            if not ready:
                if self.process.poll() is not None:
                    raise ProviderFailure("rpc", f"Codex app-server stopped during {method}.")
                continue

            read_size = min(
                CODEX_RPC_READ_BYTES,
                self.max_line_bytes + 1 - len(self.buffer),
            )
            chunk = os.read(self.stdout.fileno(), max(1, read_size))
            if not chunk:
                if self.buffer:
                    line = bytes(self.buffer)
                    self.buffer.clear()
                    return line
                raise ProviderFailure("rpc", f"Codex app-server stopped during {method}.")
            self.buffer.extend(chunk)

    def receive(self, request_id: int, method: str, timeout: float) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            line = self.read_line(deadline, method)
            try:
                message = json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if not isinstance(message, dict) or message.get("id") != request_id:
                continue
            if message.get("error"):
                raw_error = message["error"]
                detail = raw_error.get("message") if isinstance(raw_error, dict) else raw_error
                raise ProviderFailure("rpc", f"Codex RPC failed: {detail}")
            return message


def rpc_request(
    stream: CodexRpcStream,
    request_id: int,
    method: str,
    timeout: float,
    params: dict[str, Any] | None = None,
) -> dict[str, Any]:
    stream.send({"id": request_id, "method": method, "params": params or {}})
    return stream.receive(request_id, method, timeout)


def duration_label(minutes: int | None) -> tuple[str, int | None]:
    if not minutes:
        return "Usage limit", None
    seconds = minutes * 60
    if minutes == 10_080:
        return "Weekly limit", seconds
    if minutes % (24 * 60) == 0:
        days = minutes // (24 * 60)
        return f"{days} day limit", seconds
    if minutes % 60 == 0:
        hours = minutes // 60
        return f"{hours} hour limit", seconds
    return f"{minutes} minute limit", seconds


def parse_codex_rate_limits(
    limits_result: Any,
) -> tuple[list[dict[str, Any]], dict[str, Any] | None, str, str]:
    if not isinstance(limits_result, dict):
        raise ProviderFailure("malformed", "Codex returned an unexpected rate-limit payload.")

    by_limit = limits_result.get("rateLimitsByLimitId")
    snapshots: list[tuple[str, dict[str, Any]]] = []
    if isinstance(by_limit, dict) and by_limit:
        for key in sorted(by_limit):
            value = by_limit[key]
            if isinstance(value, dict):
                snapshots.append((str(key), value))
    else:
        fallback = limits_result.get("rateLimits")
        if isinstance(fallback, dict):
            snapshots.append((str(fallback.get("limitId") or "codex"), fallback))

    windows: list[dict[str, Any]] = []
    credits: dict[str, Any] | None = None
    plan = ""
    reached = ""
    for bucket_id, snapshot in snapshots:
        raw_name = str(snapshot.get("limitName") or "").strip()
        scoped = raw_name or (bucket_id.replace("_", " ").title() if bucket_id not in ("", "codex") else "")
        raw_plan = str(snapshot.get("planType") or "")
        if not plan and raw_plan:
            plan = CODEX_PLAN_LABELS.get(raw_plan, raw_plan.replace("_", " ").title())
        if snapshot.get("rateLimitReachedType") and not reached:
            reached = str(snapshot["rateLimitReachedType"])

        for role in ("primary", "secondary"):
            raw_window = snapshot.get(role)
            if not isinstance(raw_window, dict):
                continue
            used = number(raw_window.get("usedPercent"))
            if used is None:
                continue
            duration_minutes_value = number(raw_window.get("windowDurationMins"))
            duration_minutes = int(duration_minutes_value) if duration_minutes_value is not None else None
            label, seconds = duration_label(duration_minutes)
            if scoped:
                label = f"{scoped} · {label}"
            windows.append(
                make_window(
                    f"{bucket_id}-{role}",
                    label,
                    used,
                    raw_window.get("resetsAt"),
                    seconds,
                )
            )

        individual = snapshot.get("individualLimit")
        if isinstance(individual, dict):
            remaining = number(individual.get("remainingPercent"))
            if remaining is not None:
                label = (scoped + " · " if scoped else "") + "Spend limit"
                used_text = str(individual.get("used") or "")
                limit_text = str(individual.get("limit") or "")
                detail = f"{used_text} used of {limit_text}" if used_text and limit_text else ""
                windows.append(
                    make_window(
                        f"{bucket_id}-spend",
                        label,
                        100 - remaining,
                        individual.get("resetsAt"),
                        None,
                        detail,
                    )
                )

        raw_credits = snapshot.get("credits")
        if credits is None and isinstance(raw_credits, dict):
            balance = number(raw_credits.get("balance"))
            if raw_credits.get("hasCredits") is True or raw_credits.get("unlimited") is True or balance is not None:
                credits = {
                    "label": "Credits",
                    "currency": "",
                    "used": None,
                    "limit": None,
                    "remaining": balance,
                    "total": None,
                    "unlimited": bool(raw_credits.get("unlimited")),
                    "resetCreditsAvailable": None,
                }

    reset_credits = limits_result.get("rateLimitResetCredits")
    if isinstance(reset_credits, dict):
        available = number(reset_credits.get("availableCount"))
        if available is not None and available >= 0 and available.is_integer():
            if credits is None:
                credits = {
                    "label": "Credits",
                    "currency": "",
                    "used": None,
                    "limit": None,
                    "remaining": None,
                    "total": None,
                    "unlimited": False,
                    "resetCreditsAvailable": int(available),
                }
            else:
                credits["resetCreditsAvailable"] = int(available)

    return windows, credits, plan, reached


def fetch_codex(timeout: float) -> dict[str, Any]:
    provider_id = "codex"
    env = runtime_environment()
    codex = shutil.which("codex", path=env.get("PATH"))
    if not codex:
        return error_provider(provider_id, "cli_unavailable", "The Codex CLI was not found in PATH.")

    try:
        process = subprocess.Popen(
            # `never` is accepted by both the older four-state and current
            # two-state Codex approval-policy parsers. Combined with the
            # read-only sandbox, this RPC probe cannot request or perform a
            # workspace mutation.
            [codex, "-s", "read-only", "-a", "never", "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
        )
    except OSError as exc:
        return error_provider(provider_id, "cli_unavailable", f"Could not start Codex: {exc}")

    try:
        rpc = CodexRpcStream(process)
        initialize = {"clientInfo": {"name": "omarchy-model-usage", "version": "1"}}
        rpc_request(rpc, 1, "initialize", timeout, initialize)
        rpc.send({"method": "initialized", "params": {}})

        account_message = rpc_request(rpc, 2, "account/read", min(timeout, 6))
        limits_message = rpc_request(rpc, 3, "account/rateLimits/read", min(timeout, 6))
        account_result = account_message.get("result") or {}
        account = account_result.get("account") if isinstance(account_result, dict) else None
        if not isinstance(account, dict):
            return error_provider(provider_id, "no_credentials", "Codex is not signed in.")

        limits_result = limits_message.get("result") or {}
        windows, credits, limits_plan, reached = parse_codex_rate_limits(limits_result)
        raw_plan = str(account.get("planType") or "")
        plan = limits_plan or CODEX_PLAN_LABELS.get(raw_plan, raw_plan.replace("_", " ").title())
        if account.get("type") == "apiKey" and not plan:
            plan = "API key"

        result = base_provider(provider_id)
        result.update(
            plan=plan,
            account=str(account.get("email") or ""),
            source="Codex app-server RPC",
            windows=windows,
            credits=credits,
        )
        if reached:
            result["notice"] = reached.replace("_", " ").capitalize() + "."
        elif not windows and credits is None:
            result["notice"] = "Codex returned no subscription rate limits."
        return result
    except ProviderFailure as exc:
        return error_provider(provider_id, exc.kind, exc.message)
    except (OSError, BrokenPipeError) as exc:
        return error_provider(provider_id, "rpc", f"Codex app-server stopped unexpectedly: {exc}")
    finally:
        try:
            process.terminate()
            process.wait(timeout=1)
        except Exception:
            try:
                process.kill()
                process.wait(timeout=1)
            except Exception:
                pass


# ---------------------------------------------------------------- Kimi

# Public OAuth client id used by the official Kimi Code CLI.
KIMI_CLIENT_ID = "17e5f671-d194-4dfb-9706-5516cb48c098"
KIMI_USER_AGENT = "kimi-code-cli/0.39.1"
KIMI_DEFAULT_OAUTH_HOST = "https://auth.kimi.com"


def kimi_credentials_path(kimi_home: Path) -> Path | None:
    credentials_dir = kimi_home / "credentials"
    legacy = credentials_dir / "kimi-code.json"
    if legacy.is_file():
        return legacy
    # Newer Kimi Code CLI revisions store one credentials file per OAuth
    # environment, named after the config.toml key "oauth/kimi-code-env-<hash>".
    if not credentials_dir.is_dir():
        return None
    candidates = [p for p in credentials_dir.glob("kimi-code-env-*.json") if p.is_file()]
    if not candidates:
        return None
    return max(candidates, key=lambda p: p.stat().st_mtime)


def kimi_oauth_host(kimi_home: Path) -> str:
    try:
        text = (kimi_home / "config.toml").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return KIMI_DEFAULT_OAUTH_HOST
    match = re.search(r'oauth_host\s*=\s*"([^"]+)"', text[:65536])
    return match.group(1) if match else KIMI_DEFAULT_OAUTH_HOST


def kimi_refresh(path: Path, credentials: dict[str, Any], host: str, timeout: float) -> dict[str, Any] | None:
    # Access tokens live only `expires_in` seconds (currently ~15 minutes), so
    # an idle CLI leaves an expired token behind. Mirror the CLI's own
    # refresh_token grant and persist the rotated tokens back to the same file.
    refresh_token = credentials.get("refresh_token")
    if not isinstance(refresh_token, str) or not refresh_token:
        return None
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": KIMI_CLIENT_ID,
    }).encode()
    request = urllib.request.Request(
        host.rstrip("/") + "/api/oauth/token",
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "Accept": "application/json",
            "User-Agent": KIMI_USER_AGENT,
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read(MAX_HTTP_RESPONSE_BYTES + 1))
        token = payload.get("access_token")
        if not isinstance(token, str) or not token:
            return None
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    updated = dict(credentials)
    updated["access_token"] = token
    if isinstance(payload.get("refresh_token"), str) and payload["refresh_token"]:
        updated["refresh_token"] = payload["refresh_token"]
    expires_in = number(payload.get("expires_in")) or 900
    updated["expires_at"] = int(time.time()) + int(expires_in)
    try:
        atomic_write_json(path, updated)
    except OSError:
        pass  # The fresh token remains usable for this run even if persisting fails.
    return updated


KIMI_TIME_UNITS = {
    "TIME_UNIT_SECOND": 1,
    "TIME_UNIT_MINUTE": 60,
    "TIME_UNIT_HOUR": 60 * 60,
    "TIME_UNIT_DAY": 24 * 60 * 60,
    "TIME_UNIT_WEEK": SEVEN_DAYS,
}


def kimi_window_seconds(raw: Any) -> int | None:
    if not isinstance(raw, dict):
        return None
    duration = number(raw.get("duration"))
    scale = KIMI_TIME_UNITS.get(str(raw.get("timeUnit") or "").upper())
    return int(duration * scale) if duration is not None and scale else None


def friendly_window_label(seconds: int | None) -> str:
    if seconds == SEVEN_DAYS:
        return "Weekly limit"
    if seconds and seconds % (24 * 60 * 60) == 0:
        return f"{seconds // (24 * 60 * 60)} day limit"
    if seconds and seconds % (60 * 60) == 0:
        return f"{seconds // (60 * 60)} hour limit"
    if seconds and seconds % 60 == 0:
        return f"{seconds // 60} minute limit"
    return "Usage limit"


def kimi_usage_row(raw: Any, row_id: str, seconds: int | None, fallback_label: str) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    used = number(raw.get("used"))
    limit = number(raw.get("limit"))
    remaining = number(raw.get("remaining"))
    if used is None and limit is not None and remaining is not None:
        used = limit - remaining
    elif used is None and limit is not None:
        # The current Kimi parser treats an omitted `used` as a fresh window.
        used = 0
    if used is None or limit is None or limit <= 0:
        return None
    label = str(raw.get("name") or raw.get("title") or fallback_label)
    reset = raw.get("resetTime") or raw.get("reset_time") or raw.get("reset_at") or raw.get("resetAt")
    if epoch_seconds(reset) is None:
        reset_in = number(raw.get("reset_in") or raw.get("resetIn") or raw.get("ttl"))
        if reset_in is not None and reset_in > 0:
            reset = time.time() + reset_in
    return make_window(row_id, label, used / limit * 100, reset, seconds)


def parse_kimi_usage(payload: Any) -> tuple[list[dict[str, Any]], dict[str, Any] | None, str]:
    if not isinstance(payload, dict):
        raise ProviderFailure("malformed", "Kimi returned an unexpected usage payload.")

    windows: list[dict[str, Any]] = []
    summary = kimi_usage_row(payload.get("usage"), "weekly", SEVEN_DAYS, "Weekly limit")
    if summary:
        windows.append(summary)
    limits = payload.get("limits")
    if isinstance(limits, list):
        for index, raw in enumerate(limits):
            if not isinstance(raw, dict):
                continue
            detail = raw.get("detail") if isinstance(raw.get("detail"), dict) else raw
            seconds = kimi_window_seconds(raw.get("window"))
            fallback = str(raw.get("name") or friendly_window_label(seconds))
            row = kimi_usage_row(detail, f"limit-{index}", seconds, fallback)
            if row:
                windows.append(row)

    credits = None
    wallet = payload.get("boosterWallet")
    if isinstance(wallet, dict):
        balance = wallet.get("balance")
        if isinstance(balance, dict) and balance.get("type") in (None, "BOOSTER"):
            total_raw = number(balance.get("amount"))
            left_raw = number(balance.get("amountLeft"))
            # Kimi stores balance amounts as fixed-point cents (1e6 units/cent).
            total = total_raw / 100_000_000 if total_raw is not None else None
            remaining = left_raw / 100_000_000 if left_raw is not None else None
            monthly_used = wallet.get("monthlyUsed")
            monthly_limit = wallet.get("monthlyChargeLimit")
            used_cents = number(monthly_used.get("priceInCents")) if isinstance(monthly_used, dict) else None
            limit_cents = number(monthly_limit.get("priceInCents")) if isinstance(monthly_limit, dict) else None
            currency = "USD"
            for money in (monthly_limit, monthly_used):
                if isinstance(money, dict) and money.get("currency"):
                    currency = str(money["currency"]).upper()
                    break
            if any(value is not None for value in (total, remaining, used_cents, limit_cents)):
                limit_enabled = wallet.get("monthlyChargeLimitEnabled") is True
                credits = {
                    "label": "Extra usage",
                    "currency": currency,
                    "used": used_cents / 100 if used_cents is not None else None,
                    "limit": limit_cents / 100 if limit_enabled and limit_cents is not None else None,
                    "remaining": remaining,
                    "total": total,
                    "unlimited": not limit_enabled,
                    "resetCreditsAvailable": None,
                }

    plan = ""
    user = payload.get("user")
    membership = user.get("membership") if isinstance(user, dict) else None
    if isinstance(membership, dict):
        level = str(membership.get("level") or membership.get("name") or "").strip()
        if level:
            plan = "Kimi " + level.replace("LEVEL_", "").replace("_", " ").title()
    return windows, credits, plan


def parse_kimi_profile(payload: Any) -> tuple[str, str]:
    if not isinstance(payload, dict):
        return "", ""
    level = str(payload.get("user_level_name") or "").strip()
    plan = "Kimi " + level if level else ""
    account = str(payload.get("email") or payload.get("username") or payload.get("nickname") or "")
    return plan, account


def fetch_kimi(timeout: float) -> dict[str, Any]:
    provider_id = "kimi"
    kimi_home = Path(os.environ.get("KIMI_CODE_HOME") or (Path.home() / ".kimi-code")).expanduser()
    credentials_path = kimi_credentials_path(kimi_home)
    if credentials_path is None:
        return error_provider(provider_id, "no_credentials", "No Kimi Code sign-in was found.")
    try:
        credentials = read_json(credentials_path)
        token = credentials.get("access_token") if isinstance(credentials, dict) else None
        if not isinstance(token, str) or not token:
            raise ValueError("missing access token")
    except (OSError, ValueError, json.JSONDecodeError):
        return error_provider(provider_id, "no_credentials", "Kimi Code credentials could not be read.")

    expires_at = epoch_seconds(credentials.get("expires_at"))
    if expires_at is not None and expires_at <= int(time.time()):
        refreshed = kimi_refresh(credentials_path, credentials, kimi_oauth_host(kimi_home), timeout)
        if refreshed is not None:
            credentials = refreshed
            token = credentials["access_token"]
        else:
            # The CLI may have refreshed the file concurrently; re-read once.
            try:
                latest = read_json(credentials_path)
            except (OSError, ValueError, json.JSONDecodeError):
                latest = None
            if isinstance(latest, dict):
                latest_expiry = epoch_seconds(latest.get("expires_at"))
                latest_token = latest.get("access_token")
                if isinstance(latest_token, str) and latest_token and (
                    latest_expiry is None or latest_expiry > int(time.time())
                ):
                    credentials = latest
                    token = latest_token
                else:
                    return error_provider(provider_id, "expired", "The Kimi Code sign-in has expired.")
            else:
                return error_provider(provider_id, "expired", "The Kimi Code sign-in has expired.")

    base_url = (os.environ.get("KIMI_CODE_BASE_URL") or "https://api.kimi.com/coding/v1").rstrip("/")
    headers = {
        "Authorization": "Bearer " + token,
        "Accept": "application/json",
        "User-Agent": KIMI_USER_AGENT,
    }
    try:
        payload = http_json(base_url + "/usages", headers, timeout)
        windows, credits, fallback_plan = parse_kimi_usage(payload)
    except ProviderFailure as exc:
        return error_provider(provider_id, exc.kind, exc.message)

    plan = fallback_plan
    account = ""
    try:
        profile = http_json(base_url + "/me", headers, timeout)
        profile_plan, account = parse_kimi_profile(profile)
        plan = profile_plan or plan
    except ProviderFailure:
        # Profile metadata is optional; a successful usage response remains useful.
        pass

    result = base_provider(provider_id)
    result.update(
        plan=plan,
        account=account,
        source="Kimi Code usage API",
        windows=windows,
        credits=credits,
    )
    if not windows and credits is None:
        result["notice"] = "Kimi returned no active usage limits."
    return result


# --------------------------------------------------------------- CLIProxyAPI


def parse_cliproxy_codex(payload: Any) -> tuple[list[dict[str, Any]], dict[str, Any] | None, str]:
    if not isinstance(payload, dict):
        raise ProviderFailure("malformed", "Codex returned an unexpected usage payload.")
    # Translate the proxy's upstream snake_case shape to the existing RPC
    # normalizer, preserving all model-scoped windows and credit semantics.
    snapshots = {}
    extra = payload.get("additional_rate_limits")
    limits = [("codex", "", payload.get("rate_limit"))]
    if isinstance(payload.get("code_review_rate_limit"), dict):
        limits.append(("code-review", "Code review", payload["code_review_rate_limit"]))
    if isinstance(extra, list):
        limits.extend((f"additional-{i}", str(row.get("limit_name") or "Additional limit"), row.get("rate_limit"))
                      for i, row in enumerate(extra) if isinstance(row, dict))
    for bucket_id, label, limit in limits:
        snapshot: dict[str, Any] = {"limitName": label, "planType": payload.get("plan_type")}
        if isinstance(limit, dict):
            for role in ("primary", "secondary"):
                window = limit.get(role + "_window")
                if isinstance(window, dict):
                    seconds = number(window.get("limit_window_seconds"))
                    reset = window.get("reset_at")
                    if epoch_seconds(reset) is None:
                        reset_in = number(window.get("reset_after_seconds"))
                        reset = time.time() + reset_in if reset_in is not None and reset_in >= 0 else None
                    snapshot[role] = {
                        "usedPercent": window.get("used_percent"), "resetsAt": reset,
                        "windowDurationMins": seconds / 60 if seconds is not None else None,
                    }
        if bucket_id == "codex" and isinstance(payload.get("credits"), dict):
            credit = payload["credits"]
            snapshot["credits"] = {"hasCredits": credit.get("has_credits"),
                                   "unlimited": credit.get("unlimited"), "balance": credit.get("balance")}
        snapshots[bucket_id] = snapshot
    normalized: dict[str, Any] = {"rateLimitsByLimitId": snapshots}
    reset_credits = payload.get("rate_limit_reset_credits")
    if isinstance(reset_credits, dict):
        normalized["rateLimitResetCredits"] = {"availableCount": reset_credits.get("available_count")}
    windows, credits, plan, _ = parse_codex_rate_limits(normalized)
    return windows, credits, plan


def parse_antigravity_usage(payload: Any) -> list[dict[str, Any]]:
    if not isinstance(payload, dict) or not isinstance(payload.get("groups"), list):
        raise ProviderFailure("malformed", "Antigravity returned an unexpected quota summary.")
    windows = []
    for i, group in enumerate(payload["groups"]):
        if not isinstance(group, dict) or not isinstance(group.get("buckets"), list):
            continue
        name = clean_message(group.get("displayName") or group.get("display_name") or "Models")
        for j, bucket in enumerate(group["buckets"]):
            if not isinstance(bucket, dict):
                continue
            remaining = number(bucket.get("remainingFraction", bucket.get("remaining_fraction")))
            label = clean_message(bucket.get("window") or bucket.get("displayName") or "Quota")
            reset = bucket.get("resetTime", bucket.get("reset_time"))
            window = make_window(f"antigravity-{i}-{j}", f"{name} · {label}",
                                 100 * (1 - remaining) if remaining is not None else 0, reset)
            if remaining is None:
                window.update(used=None, remaining=None, detail="Quota amount unavailable")
            windows.append(window)
    return windows


def cliproxy_account_record(provider_id: str, entry: dict[str, Any]) -> dict[str, Any]:
    result = base_provider(provider_id)
    identity = str(entry.get("id") or entry.get("name") or entry.get("auth_index") or entry.get("authIndex") or "")
    result.update(source="CLIProxyAPI management API", authCommand="",
                  accountId=hashlib.sha256((provider_id + ":" + identity).encode()).hexdigest()[:16],
                  account=clean_message(entry.get("email") or entry.get("label") or entry.get("account") or "Managed account"))
    result.update(proxyImplementation="rust" if entry.get("_rust") is True else "go",
                  supportsBankedReset=entry.get("_rust") is not True)
    return result


def rust_timestamp(value: Any, *, observed: bool = False, now: float | None = None) -> float | None:
    if value is None:
        return None
    try:
        if not isinstance(value, str) or not 0 < len(value) <= 64:
            raise ValueError
        # Rust emits nanoseconds; Python 3.10's ISO parser accepts only
        # millisecond or microsecond precision. Normalize to microseconds.
        value = re.sub(r"(:\d{2}\.)(\d+)(?=(?:Z|[+-]\d{2}:\d{2})$)",
                       lambda match: match[1] + (match[2] + "000000")[:6], value)
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        stamp = parsed.timestamp()
        current = time.time() if now is None else now
        if parsed.tzinfo is None or stamp <= 0 or (observed and stamp > current + 60):
            raise ValueError
        return stamp
    except (ValueError, TypeError, OverflowError):
        raise ProviderFailure("malformed", "Fusebox returned an invalid quota or activity timestamp.") from None


RUST_QUOTA_PROVIDERS = ("claude", "codex", "meta", "antigravity")
RUST_UNSUPPORTED_NOTICES = {
    "kimi": "Fusebox does not report Kimi Code subscription quotas.",
}
RUST_DURATIONS = {"5h": FIVE_HOURS, "week": SEVEN_DAYS, "day": 86400}
RUST_DURATION_LABELS = {"5h": "5 hour limit", "week": "Weekly limit", "day": "Daily limit"}
RUST_WINDOW_SCOPES = {"oauth apps": "OAuth apps", "overage": "Extra usage"}
# Fusebox's name for Claude's `seven_day_overage_included`: the Fable week,
# read from the flat usage field. `week fable` reads the same allowance from
# the typed limits and wins when both are present.
RUST_CLAUDE_FABLE_OVERAGE = "week overage"
RUST_CODEX_SUBSCRIPTIONS = {
    # Fusebox reads ChatGPT's active subscription SKU; usage's `pro` alone is ambiguous.
    "chatgptprolite": ("prolite", "ChatGPT Pro Lite"),
    "chatgptpro": ("pro", "ChatGPT Pro"),
    "chatgptpromax": ("promax", "Codex Pro 500"),
}
RUST_CLAUDE_PLANS = {"pro": "Claude Pro", "max_5x": "Claude Max", "max_20x": "Claude Ultra", "ultra": "Claude Ultra"}
RUST_COOLDOWN_TEXT = {"quota": "Usage limit used up", "rate_limit": "Rate limited", "credit": "Out of credits"}
RUST_PRIORITY_TEXT = {"first": "Takes new sessions first", "last": "Takes new sessions last"}
RUST_UNSETTLED_RESETS = ("pending", "unknown")
SIGN_IN_ERROR = re.compile(
    r"invalid_grant|refresh token|sign in again|re-?authenticat|unauthori[sz]ed|\b401\b"
    r"|token (?:has )?expired|expired token|revoked", re.IGNORECASE)


def rust_text(value: Any, limit: int = 128) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or len(value) > limit:
        raise ProviderFailure("malformed", "Fusebox returned invalid account metadata.")
    return value.strip() or None


def rust_percent(value: Any) -> float | None:
    if value is None:
        return None
    parsed = number(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else None
    if parsed is None or not 0 <= parsed <= 100:
        raise ProviderFailure("malformed", "Fusebox returned an invalid quota amount or model scope.")
    return parsed


def rust_duration(name: str) -> tuple[str, int | None]:
    if name in RUST_DURATION_LABELS:
        return RUST_DURATION_LABELS[name], RUST_DURATIONS[name]
    match = re.fullmatch(r"(\d{1,6})([dhms])", name)
    if not match:
        return name.title(), None
    amount, unit = int(match[1]), match[2]
    seconds = amount * {"d": 86400, "h": 3600, "m": 60, "s": 1}[unit]
    noun = {"d": "day", "h": "hour", "m": "minute", "s": "second"}[unit]
    return f"{amount} {noun} limit", seconds


def rust_window(provider_id: str, row: Any, now: float) -> dict[str, Any] | None:
    if not isinstance(row, dict) or not isinstance(row.get("name"), str) or not 0 < len(row["name"]) <= 128:
        raise ProviderFailure("malformed", "Fusebox returned an invalid quota window.")
    used = rust_percent(row.get("used"))
    model = row.get("model")
    if used is None or (model is not None and (not isinstance(model, str) or not 0 < len(model) <= 128)):
        raise ProviderFailure("malformed", "Fusebox returned an invalid quota amount or model scope.")
    reset = rust_timestamp(row.get("resets_at"), now=now)
    # A cached window past its reset cannot claim fresh capacity.
    if reset is not None and reset <= now:
        return None
    name = row["name"]
    # Fusebox names scoped windows "<duration> <scope>", e.g. "week opus".
    base, _, scope = name.partition(" ")
    label, seconds = rust_duration(base)
    window_id = None if model or scope else {
        "5h": "session" if provider_id == "claude" else "codex-primary",
        "week": "weekly" if provider_id == "claude" else "codex-secondary",
    }.get(name) if provider_id in ("claude", "codex") else None
    window_id = window_id or "rust-" + hashlib.sha256(json.dumps([name, model]).encode()).hexdigest()[:16]
    if rust_is_fable_overage(provider_id, row):
        model = "fable"
    if model:
        # "Fable weekly", like the local Claude reading; other durations keep theirs.
        label = model.title() + (" weekly" if base == "week" else " · " + label)
    else:
        scope_label = RUST_WINDOW_SCOPES.get(scope, scope.title() if scope else "")
        if scope_label:
            label = scope_label + " · " + label
    return make_window(window_id, label, used, reset, seconds, model=model.lower() if model else None)


def rust_is_fable_overage(provider_id: str, row: dict[str, Any]) -> bool:
    return provider_id == "claude" and row.get("name") == RUST_CLAUDE_FABLE_OVERAGE and not row.get("model")


def rust_limits(rows: Any, now: float) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    """Typed limits: account/model caps route chat; features, overage and credits inform."""
    if rows is None:
        return [], None
    if not isinstance(rows, list) or len(rows) > 128:
        raise ProviderFailure("malformed", "Fusebox returned invalid quota limits.")
    windows, credits = [], None
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("scope"), dict):
            raise ProviderFailure("malformed", "Fusebox returned an invalid quota limit.")
        name, limit_id = rust_text(row.get("name")), rust_text(row.get("id"), 256)
        kind = row["scope"].get("kind")
        value = row["scope"].get("value")
        if not name or not limit_id or kind not in (
                "account", "model", "models", "model_families", "feature", "overage", "credits"):
            raise ProviderFailure("malformed", "Fusebox returned an invalid quota limit.")
        used_percent = rust_percent(row.get("used_percent"))
        amounts = {key: number(row.get(key)) if isinstance(row.get(key), (int, float)) and not isinstance(row.get(key), bool) else None
                   for key in ("used", "limit", "remaining")}
        reset = rust_timestamp(row.get("resets_at"), now=now)
        if reset is not None and reset <= now:
            continue
        unit = rust_text(row.get("unit"), 32) or ""
        if kind == "overage":
            if row.get("enabled") is not True:
                continue
            # Claude reports extra usage in USD cents.
            scale = 100 if unit.lower() == "usd cents" else 1
            used = amounts["used"] / scale if amounts["used"] is not None else None
            cap = amounts["limit"] / scale if amounts["limit"] is not None else None
            credits = {"label": "Extra usage", "currency": "USD" if scale == 100 else "", "used": used, "limit": cap,
                       "remaining": max(0.0, cap - used) if used is not None and cap is not None else None,
                       "total": None, "unlimited": row.get("unlimited") is True, "resetCreditsAvailable": None}
            continue
        if kind == "credits":
            if amounts["remaining"] is not None or row.get("unlimited") is True:
                credits = {"label": "Credits", "currency": "", "used": None, "limit": None,
                           "remaining": amounts["remaining"], "total": None,
                           "unlimited": row.get("unlimited") is True, "resetCreditsAvailable": None}
            continue
        if used_percent is None or row.get("unlimited") is True:
            continue
        # A provider gate only matters while it blocks; an open gate duplicates its windows.
        if limit_id.endswith(":gate") and used_percent < 100:
            continue
        scoped = kind in ("model", "models", "model_families")
        if scoped:
            values = value if isinstance(value, list) else [value]
            if not values or len(values) > 32 or not all(isinstance(v, str) and 0 < len(v) <= 128 for v in values):
                raise ProviderFailure("malformed", "Fusebox returned an invalid quota limit scope.")
        label = name + (" · Limit reached" if limit_id.endswith(":gate") else "")
        detail = ""
        if amounts["used"] is not None and amounts["limit"] is not None:
            detail = f"{amounts['used']:g} of {amounts['limit']:g}{' ' + unit if unit else ''} used"
        informational = kind == "feature" or row.get("enabled") is False
        if informational:
            detail = (detail + " · " if detail else "") + "Separate allowance; does not limit ordinary requests"
        window = make_window("rust-limit-" + hashlib.sha256(limit_id.encode()).hexdigest()[:16],
                             label, used_percent, reset, None, detail)
        if informational:
            window["informational"] = True
        windows.append(window)
    return windows, credits


def rust_plan(provider_id: str, quota: dict[str, Any]) -> tuple[str, str]:
    raw_plan = rust_text(quota.get("plan")) or ""
    plan_name = rust_text(quota.get("plan_name")) or ""
    subscription = rust_text(quota.get("subscription_plan")) or ""
    if provider_id == "codex":
        if subscription in RUST_CODEX_SUBSCRIPTIONS:
            return RUST_CODEX_SUBSCRIPTIONS[subscription]
        return raw_plan, CODEX_PLAN_LABELS.get(raw_plan, raw_plan.replace("_", " ").title())
    if provider_id == "claude":
        label = "Claude " + plan_name if plan_name else RUST_CLAUDE_PLANS.get(raw_plan, "")
        return raw_plan, label or ("Claude " + raw_plan.replace("_", " ").title() if raw_plan else "")
    return raw_plan, plan_name or raw_plan.replace("_", " ").title()


def rust_status_items(entry: dict[str, Any], quota: dict[str, Any], now: float) -> list[dict[str, Any]]:
    """Short account facts Fusebox knows beyond the quota windows."""
    items: list[dict[str, Any]] = []

    def stamp(value: Any) -> float | None:
        try:
            return rust_timestamp(value, now=now)
        except ProviderFailure:
            return None

    cooldowns = entry.get("cooldowns") if isinstance(entry.get("cooldowns"), dict) else {}
    kinds = entry.get("cooldown_kinds") if isinstance(entry.get("cooldown_kinds"), dict) else {}
    for model in sorted(cooldowns, key=lambda key: (key != "*", key))[:4]:
        until, kind = stamp(cooldowns[model]), kinds.get(model)
        if until is None or until <= now or kind == "checking" or not isinstance(model, str) or len(model) > 128:
            continue
        text = RUST_COOLDOWN_TEXT.get(kind, "Cooling down")
        items.append({"kind": "cooldown", "text": text if model == "*" else clean_message(model) + " · " + text, "at": until})
    wait = stamp(quota.get("usage_wait_until"))
    if wait is not None and wait > now:
        items.append({"kind": "warning", "text": "Provider usage checks are rate limited", "at": wait})
    if quota.get("subscription_inactive") is True:
        items.append({"kind": "warning", "text": "Subscription is not active; these are the last reported limits", "at": None})
    if quota.get("no_five_hour_limit") is True:
        items.append({"kind": "info", "text": "No 5-hour limit", "at": None})
    renewal = quota.get("renewal")
    if isinstance(renewal, dict) and (at := stamp(renewal.get("at"))) is not None:
        text = "Ends" if renewal.get("ends") is True else "Renews"
        items.append({"kind": "renewal", "text": text, "at": at, "estimated": renewal.get("estimated") is True})
    priority = RUST_PRIORITY_TEXT.get(entry.get("priority"))
    if priority:
        items.append({"kind": "info", "text": priority, "at": None})
    resets = entry.get("banked_resets")
    operation = resets.get("operation") if isinstance(resets, dict) else None
    if isinstance(operation, dict) and operation.get("status") in RUST_UNSETTLED_RESETS:
        items.append({"kind": "warning", "text": "A banked reset needs review in the Fusebox dashboard", "at": None})
    error = entry.get("last_error")
    if isinstance(error, str) and error.strip() and not SIGN_IN_ERROR.search(error):
        message = EMAIL_PATTERN.sub("[email]", clean_message(error))[:160]
        items.append({"kind": "error", "text": "Last error: " + message, "at": None})
    return items


def rust_reset_credits(provider_id: str, entry: dict[str, Any]) -> int | None:
    if provider_id not in ("claude", "codex") or entry.get("kind") != "oauth":
        return None
    resets = entry.get("banked_resets")
    if not isinstance(resets, dict) or resets.get("error") or not isinstance(resets.get("inventory"), dict):
        return None
    operation = resets.get("operation")
    if isinstance(operation, dict) and operation.get("status") in RUST_UNSETTLED_RESETS:
        return None
    available = number(resets["inventory"].get("available"))
    if available is None or available < 0 or available != int(available) or available > 10_000:
        return None
    # Like Fusebox's dashboard, show nothing for accounts without banked resets.
    # An ineligible count still opens the dialog, which names Fusebox's reason.
    return int(available) or None


def fetch_rust_account(provider_id: str, entry: dict[str, Any]) -> dict[str, Any]:
    result = cliproxy_account_record(provider_id, entry)
    result.update(source="Fusebox accounts API", supportsBankedReset=False, statusItems=[])
    if entry.get("disabled") is True:
        result.update(status="disabled", notice="This account is paused in Fusebox.")
        return result
    if entry.get("kind") != "oauth":
        result.update(status="unsupported", notice="API keys and service accounts have no subscription quota.")
        return result
    if provider_id not in RUST_QUOTA_PROVIDERS:
        result.update(status="unsupported", notice=RUST_UNSUPPORTED_NOTICES.get(
            provider_id, "Fusebox does not report subscription quotas for this provider."))
        return result
    try:
        quota = entry.get("quota")
        if not isinstance(quota, dict) or not isinstance(quota.get("windows"), list) or len(quota["windows"]) > 128:
            raise ProviderFailure("malformed", "Fusebox returned invalid quota data.")
        now = time.time()
        observed = rust_timestamp(quota.get("updated_at"), observed=True, now=now)
        windows, seen, fable_overage = [], set(), None
        for row in quota["windows"]:
            window = rust_window(provider_id, row, now)
            if window is None:
                continue
            if window["id"] in seen:
                raise ProviderFailure("malformed", "Fusebox returned duplicate quota windows.")
            seen.add(window["id"])
            windows.append(window)
            if rust_is_fable_overage(provider_id, row):
                fable_overage = window
        if fable_overage is not None and any(
                window is not fable_overage and window.get("model") == "fable" and window["windowSeconds"] == SEVEN_DAYS
                for window in windows):
            windows.remove(fable_overage)
        limit_windows, credits = rust_limits(quota.get("limits"), now)
        windows.extend(window for window in limit_windows if window["id"] not in seen)
        reset_credits = rust_reset_credits(provider_id, entry)
        if reset_credits is not None:
            credits = dict(credits or {"label": "Credits", "currency": "", "used": None, "limit": None,
                                       "remaining": None, "total": None, "unlimited": False},
                           resetCreditsAvailable=reset_credits)
        result["statusItems"] = rust_status_items(entry, quota, now)
        error = entry.get("last_error")
        if isinstance(error, str) and SIGN_IN_ERROR.search(error):
            raise ProviderFailure("expired", "Fusebox reports that this sign-in was rejected. Sign in again in the Fusebox dashboard.")
        if observed is None or not windows:
            raise ProviderFailure("quota_unavailable", "Subscription quotas are not available in the Fusebox cache yet.")
        plan_type, plan = rust_plan(provider_id, quota)
        result.update(windows=windows, credits=credits, quotaUpdatedAt=observed,
                      fetchedAt=datetime.fromtimestamp(observed, timezone.utc).isoformat(),
                      planType=clean_message(plan_type), plan=clean_message(plan),
                      supportsBankedReset=reset_credits is not None,
                      stale=now - observed > RUST_QUOTA_STALE_SECONDS)
        if result["stale"]:
            result["notice"] = "Last known reading · The Fusebox quota cache is more than 10 minutes old."
    except ProviderFailure as exc:
        result.update(status="error", errorKind=exc.kind, message=exc.message)
    return result


def fetch_cliproxy_account(provider_id: str, entry: dict[str, Any], client: ProxyClient, timeout: float) -> dict[str, Any]:
    if entry.get("_rust") is True:
        return fetch_rust_account(provider_id, entry)
    result = cliproxy_account_record(provider_id, entry)
    if entry.get("disabled") is True or entry.get("status") == "disabled":
        result.update(status="disabled", notice="This account is paused in CLIProxyAPI.")
        return result
    if provider_id not in (*PROVIDER_ORDER, "antigravity"):
        result.update(status="unsupported", notice="This provider does not expose a supported quota lookup.")
        return result
    try:
        if provider_id == "claude":
            payload = client.usage(entry, "https://api.anthropic.com/api/oauth/usage",
                                   {"anthropic-beta": "oauth-2025-04-20", "User-Agent": "claude-code/2.1.0 (external, cli)"}, timeout)
            windows, credits = parse_claude_usage(payload)
            plan = claude_plan(entry)
        elif provider_id == "codex":
            claims = entry.get("id_token") if isinstance(entry.get("id_token"), dict) else {}
            account_id = entry.get("chatgpt_account_id") or claims.get("chatgpt_account_id")
            if not isinstance(account_id, str) or not account_id:
                raise ProviderFailure("config", "CLIProxyAPI Codex account has no ChatGPT account ID. Sign in again through CLIProxyAPI.")
            payload = client.usage(entry, "https://chatgpt.com/backend-api/wham/usage",
                                   {"ChatGPT-Account-Id": account_id, "User-Agent": "codex-cli"}, timeout)
            windows, credits, plan = parse_cliproxy_codex(payload)
            raw_plan = str(payload.get("plan_type") or claims.get("plan_type") or entry.get("plan_type") or "")
            result["planType"] = clean_message(raw_plan)
            plan = plan or CODEX_PLAN_LABELS.get(raw_plan, raw_plan.replace("_", " ").title())
        elif provider_id == "kimi":
            payload = client.usage(entry, "https://api.kimi.com/coding/v1/usages", {}, timeout)
            windows, credits, plan = parse_kimi_usage(payload)
        else:
            project = entry.get("project_id")
            if not isinstance(project, str) or not project:
                raise ProviderFailure("config", "Antigravity quota lookup needs a project ID on this CLIProxyAPI account.")
            payload = client.usage(entry, "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
                                   {"Content-Type": "application/json", "User-Agent": "antigravity/cli/1.0.13 (aidev_client; os_type=linux; arch=amd64)"},
                                   timeout, data={"project": project})
            windows, credits, plan = parse_antigravity_usage(payload), None, ""
        result.update(windows=windows, credits=credits, plan=clean_message(plan),
                      account=clean_message(entry.get("email") or entry.get("label") or entry.get("account") or ""))
        if not windows and credits is None:
            result["notice"] = "The managed account returned no subscription limits."
    except ProviderFailure as exc:
        result.update(status="error", errorKind=exc.kind, message=exc.message)
    except Exception:
        # Arbitrary proxy metadata/exception text must not expose credentials.
        result.update(status="error", errorKind="malformed", message="Could not read this CLIProxyAPI account's usage.")
    return result


def collect_cliproxy(provider_ids: list[str], timeout: float, address: str, key_file: Path | str | None,
                     discover: bool = False, metadata: dict[str, Any] | None = None,
                     implementation: str = "auto") -> list[dict[str, Any]]:
    if not provider_ids and not discover:
        return []
    overall_deadline = time.monotonic() + timeout if discover else None
    try:
        client = ProxyClient(address, read_key(key_file), implementation)
        entries = client.accounts(timeout)
        if metadata is not None:
            metadata["proxyImplementation"] = client.implementation if client.implementation != "auto" else "go"
    except ProviderFailure as exc:
        if discover:
            provider_ids = ["cliproxy"]
        return [dict(error_provider(provider_id, exc.kind, exc.message),
                     source="CLIProxyAPI management API", authCommand="") for provider_id in provider_ids]

    if discover:
        discovered = {str(entry.get("provider") or entry.get("type") or "unknown").lower() for entry in entries}
        provider_ids = sorted(provider for provider in discovered if re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,63}", provider))
        if len(provider_ids) > MAX_CLIPROXY_PROVIDERS:
            provider_ids = provider_ids[:MAX_CLIPROXY_PROVIDERS]
    discovery_deadline = overall_deadline if discover else None

    def fetch(provider_id: str) -> dict[str, Any]:
        matching = [entry for entry in entries
                    if str(entry.get("provider") or entry.get("type") or "").lower() == provider_id
                    and (discover or (entry.get("disabled") is not True and entry.get("status") != "disabled"))]
        if not matching:
            return dict(error_provider(provider_id, "no_credentials", "No enabled account was found. Add a sign-in through CLIProxyAPI, then refresh."),
                        source="CLIProxyAPI management API", authCommand="")
        deadline = discovery_deadline if discover else time.monotonic() + timeout

        def account(entry: dict[str, Any]) -> dict[str, Any]:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return dict(cliproxy_account_record(provider_id, entry), status="error", errorKind="timeout",
                            message="CLIProxyAPI account checks timed out.")
            return fetch_cliproxy_account(provider_id, entry, client, remaining)

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            readings = list(pool.map(account, matching[:MAX_CLIPROXY_ACCOUNTS]))
        successful = [reading for reading in readings if reading["status"] == "ok" and not reading.get("stale")]
        # A rotating pool still has capacity when one account is exhausted.
        # Select by the binding window, never sum unrelated percentages.
        active = [reading for reading in readings if reading["status"] != "disabled"]
        stale = [reading for reading in active if reading["status"] == "ok"]
        candidates = successful or stale
        best = dict(max(candidates, key=lambda reading: 100 - used if (used := dynamic_window_used(reading)) is not None else -1) if candidates else (active or readings)[0])
        if discover:
            best["accounts"] = readings
        best["accountCount"] = len(matching)
        best["availableCount"] = len(successful)
        notes = [best["notice"]] if best["notice"] else []
        if len(matching) > 1 and best["status"] not in ("disabled", "unsupported"):
            notes.append(f"{len(successful)} of {len(matching)} accounts checked successfully. Showing the account with the most remaining quota." if successful
                         else "Only last-known quota readings are available." if stale
                         else f"None of {len(matching)} accounts could be checked.")
        if len(matching) > MAX_CLIPROXY_ACCOUNTS:
            notes.append(f"Only the first {MAX_CLIPROXY_ACCOUNTS} accounts were checked.")
        best["notice"] = " ".join(notes)
        if best["status"] == "error" and len(matching) > 1:
            best["message"] += f" All {len(readings)} checked accounts failed."
        return best

    if not provider_ids:
        return []
    with concurrent.futures.ThreadPoolExecutor(max_workers=min(4, len(provider_ids))) as pool:
        return list(pool.map(fetch, provider_ids))


# --------------------------------------------------------------- History


def history_path(state_dir: Path | None = None) -> Path:
    if state_dir is None:
        state_home = Path(os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state"))
        state_dir = state_home / "omarchy" / "model-usage"
    return state_dir / "history.json"


def empty_history() -> dict[str, Any]:
    return {"schemaVersion": 1, "providers": {provider_id: [] for provider_id in PROVIDER_ORDER}}


def load_history(path: Path) -> dict[str, Any]:
    try:
        raw = read_json(path)
    except (OSError, ValueError, json.JSONDecodeError):
        return empty_history()
    if not isinstance(raw, dict) or raw.get("schemaVersion") != 1 or not isinstance(raw.get("providers"), dict):
        return empty_history()
    result = empty_history()
    for provider_id in list(dict.fromkeys([*PROVIDER_ORDER, *raw["providers"]]))[:MAX_CLIPROXY_PROVIDERS + 3]:
        rows = raw["providers"].get(provider_id)
        if not isinstance(rows, list):
            continue
        valid: list[list[float]] = []
        for row in rows:
            if not isinstance(row, list) or len(row) != 2:
                continue
            stamp = number(row[0])
            used = number(row[1])
            if stamp is not None and used is not None:
                valid.append([int(stamp), round(clamp(used, 0, 100), 2)])
        valid.sort(key=lambda row: row[0])
        result["providers"][provider_id] = valid[-HISTORY_MAX_SAMPLES:]
    return result


def dynamic_window_used(provider: dict[str, Any]) -> float | None:
    windows = provider.get("windows")
    if provider.get("status") != "ok" or not isinstance(windows, list) or not windows:
        return None
    used_values = [
        clamp(value, 0, 100)
        for row in windows
        # Feature allowances are shown, but never select or limit the account.
        if isinstance(row, dict) and row.get("informational") is not True
        and (value := number(row.get("used"))) is not None
    ]
    if not used_values:
        return None
    return max(used_values)


def bucket_history(samples: list[list[float]], now: int, buckets: int, span: int) -> list[float]:
    if not samples:
        return []
    start = now - span
    width = span / buckets
    output: list[float | None] = [None] * buckets
    prior = 0.0
    for stamp, used in samples:
        if stamp < start:
            prior = used
            continue
        if stamp > now:
            continue
        index = min(buckets - 1, max(0, int((stamp - start) / width)))
        output[index] = max(output[index] if output[index] is not None else 0, used)
    last = prior
    final: list[float] = []
    for value in output:
        if value is not None:
            last = value
        final.append(round(last, 2))
    return final


def update_and_attach_history(
    providers: list[dict[str, Any]], state_dir: Path | None = None, now: int | None = None
) -> None:
    stamp = int(time.time()) if now is None else int(now)
    path = history_path(state_dir)
    history = load_history(path)
    cutoff = stamp - HISTORY_RETENTION_SECONDS
    changed = False
    by_id = {provider["id"]: provider for provider in providers}
    for provider_id in dict.fromkeys([*history["providers"], *by_id]):
        samples = [row for row in history["providers"].get(provider_id, []) if cutoff <= row[0] <= stamp + 300]
        provider = by_id.get(provider_id)
        used = dynamic_window_used(provider) if provider else None
        observation = int(provider.get("quotaUpdatedAt", stamp)) if provider else stamp
        if provider and provider.get("proxyImplementation") == "rust" and (provider.get("stale") or (samples and observation <= samples[-1][0])):
            used = None
        if used is not None:
            if samples and observation - samples[-1][0] < 60:
                samples[-1] = [observation, round(used, 2)]
            else:
                samples.append([observation, round(used, 2)])
            changed = True
        samples = samples[-HISTORY_MAX_SAMPLES:]
        history["providers"][provider_id] = samples
        if provider is not None:
            provider["history"] = {
                "h24": bucket_history(samples, stamp, 24, 24 * 60 * 60),
                "d7": bucket_history(samples, stamp, 7, SEVEN_DAYS),
            }
    if changed:
        try:
            atomic_write_json(path, history)
        except OSError:
            # History persistence must never suppress otherwise valid live data.
            pass


# --------------------------------------------------------------- Orchestration


FETCHERS: dict[str, Callable[[float], dict[str, Any]]] = {
    "claude": fetch_claude,
    "codex": fetch_codex,
    "kimi": fetch_kimi,
}


def safe_fetch(provider_id: str, timeout: float) -> dict[str, Any]:
    try:
        result = FETCHERS[provider_id](timeout)
        if not isinstance(result, dict) or result.get("id") != provider_id:
            raise ValueError("invalid normalized result")
        return result
    except Exception:
        return error_provider(provider_id, "internal", "The provider collector could not read usage data.")


def collect_providers(provider_ids: list[str], timeout: float) -> list[dict[str, Any]]:
    if not provider_ids:
        return []
    results: dict[str, dict[str, Any]] = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(provider_ids)) as executor:
        futures = {executor.submit(safe_fetch, provider_id, timeout): provider_id for provider_id in provider_ids}
        for future in concurrent.futures.as_completed(futures):
            provider_id = futures[future]
            try:
                results[provider_id] = future.result()
            except Exception:
                results[provider_id] = error_provider(provider_id, "internal", "The provider collector could not read usage data.")
    return [results[provider_id] for provider_id in provider_ids]


def parse_provider_ids(value: str) -> list[str]:
    requested = {item.strip().lower() for item in value.split(",") if item.strip()}
    return [provider_id for provider_id in PROVIDER_ORDER if provider_id in requested]


def build_payload(
    provider_ids: list[str], timeout: float, state_dir: Path | None,
    source: str = "direct", proxy_url: str = "http://127.0.0.1:8317",
    key_file: Path | str | None = None, implementation: str = "auto",
) -> dict[str, Any]:
    metadata: dict[str, Any] = {}
    proxy = source in ("proxy", "cliproxy")
    if proxy:
        providers = collect_cliproxy(provider_ids, timeout, proxy_url, key_file, discover=True,
                                     metadata=metadata, implementation=implementation)
        try:
            server = normalize_url(proxy_url)
        except ValueError:
            server = "invalid"
        server_id = hashlib.sha256(server.encode("utf-8")).hexdigest()[:16]
        state_dir = history_path(state_dir).parent / ("cliproxy-" + server_id)
    else:
        providers = collect_providers(provider_ids, timeout)
    update_and_attach_history(providers, state_dir)
    return {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": now_iso(),
        "providers": providers,
        # The output contract keeps its original source identifier.
        "source": "cliproxy" if proxy else "direct",
        **metadata,
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--providers", default=",".join(PROVIDER_ORDER))
    parser.add_argument("--timeout", type=float, default=12.0)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--source", choices=("direct", "proxy", "cliproxy"), default="direct",
                        help="direct CLI sign-ins, or proxy for Fusebox / CLIProxyAPI (cliproxy is an alias)")
    add_proxy_arguments(parser)
    args = parser.parse_args(argv)

    provider_ids = parse_provider_ids(args.providers)
    timeout = clamp(args.timeout, 1.0, 30.0)
    try:
        payload = build_payload(provider_ids, timeout, args.state_dir, args.source, args.proxy_url,
                                args.proxy_key_file, args.implementation)
    except Exception as exc:
        payload = {
            "schemaVersion": SCHEMA_VERSION,
            "generatedAt": now_iso(),
            "providers": [],
            "backendError": clean_message(exc),
        }
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
