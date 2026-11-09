#!/usr/bin/env python3
"""Explicit banked reset actions for CLIProxyAPI and Fusebox; never invoked by quota polling."""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import sys
import time
import urllib.parse
import uuid
from datetime import datetime
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("reset_usage", Path(__file__).with_name("usage-fetch.py"))
assert SPEC and SPEC.loader
usage = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = usage
SPEC.loader.exec_module(usage)
import proxy_connection as connection  # noqa: E402

RESET_URL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"


def identifier(value):
    return isinstance(value, str) and 0 < len(value) <= 512 and not any(ord(c) < 33 or ord(c) == 127 for c in value)


def count(value):
    parsed = usage.number(value)
    return int(parsed) if parsed is not None and parsed >= 0 and parsed == int(parsed) else None


def timestamp(value):
    if not isinstance(value, str):
        raise ValueError("Invalid timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Missing timezone")
    return parsed.timestamp()


def normalize_details(payload, now=None):
    now = time.time() if now is None else now
    if not isinstance(payload, dict) or not isinstance(payload.get("credits"), list):
        raise usage.ProviderFailure("malformed", "Reset details are unavailable. Refresh and try again.")
    available = count(payload.get("available_count"))
    if available is None or len(payload["credits"]) > 1024:
        raise usage.ProviderFailure("malformed", "The server returned invalid reset details.")
    credits = []
    seen = set()
    for credit in payload["credits"]:
        if not isinstance(credit, dict) or credit.get("status") != "available" or credit.get("reset_type") != "codex_rate_limits":
            continue
        credit_id = credit.get("id")
        if not identifier(credit_id) or credit_id in seen:
            raise usage.ProviderFailure("malformed", "The server returned invalid reset identifiers.")
        seen.add(credit_id)
        try:
            expiry = None if credit.get("expires_at") is None else timestamp(credit["expires_at"])
            granted = timestamp(credit["granted_at"])
        except (ValueError, TypeError, KeyError, OverflowError):
            raise usage.ProviderFailure("malformed", "The server returned invalid reset dates.") from None
        if expiry is not None and expiry <= now:
            continue
        credits.append({"id": credit_id, "expiresAt": expiry, "grantedAt": granted,
                        "title": usage.clean_message(credit.get("title") or "Full reset"),
                        "description": usage.clean_message(credit.get("description") or "Reset your current Codex usage limits.")})
    credits.sort(key=lambda c: (c["expiresAt"] if c["expiresAt"] is not None else float("inf"), c["grantedAt"], c["id"]))
    return {"availableCount": available, "applicableAvailableCount": count(payload.get("applicable_available_count")),
            "credits": credits if available > 0 else []}


FUSEBOX_OUTCOMES = {"applied": "reset", "already_used": "already_redeemed",
                    "reconciled_used": "already_redeemed", "refused": "refused", "reconciled_unused": "refused"}


def provider_of(entry):
    return str(entry.get("provider") or entry.get("type") or "").lower()


def find_account(client, account_id, remaining):
    if not isinstance(account_id, str) or not re.fullmatch(r"[0-9a-f]{16}", account_id):
        raise usage.ProviderFailure("config", "Invalid reset account.")
    entries = client.accounts(remaining())
    # Fusebox redeems Claude and Codex resets itself; CLIProxyAPI only Codex.
    providers = ("claude", "codex") if client.implementation == "rust" else ("codex",)
    matches = [entry for entry in entries if provider_of(entry) in providers
               and usage.cliproxy_account_record(provider_of(entry), entry)["accountId"] == account_id]
    if len(matches) != 1:
        raise usage.ProviderFailure("config", "This account changed or is unavailable. Refresh its usage first.")
    return matches[0]


def fusebox_path(entry):
    native = entry.get("_native_id")
    if not isinstance(native, str) or not 0 < len(native) <= 512:
        raise usage.ProviderFailure("config", "This Fusebox account has no usable identity. Refresh its usage first.")
    return "accounts/" + urllib.parse.quote(native, safe="") + "/banked-resets"


def fusebox_failure(error, fallback):
    """Name Fusebox's own reason for refusing a reset read or request."""
    status = getattr(error, "http_status", None)
    detail = getattr(error, "detail", "")
    if status == 404 and not detail.startswith("unknown account"):
        return usage.ProviderFailure("unsupported", "Banked resets are turned off in Fusebox. Enable them under Config, Connections.")
    if status == 404:
        return usage.ProviderFailure("config", "This account changed or is unavailable. Refresh its usage first.")
    if status in (409, 502) and detail:
        return usage.ProviderFailure("http", detail.rstrip(".") + ".")
    return usage.ProviderFailure(error.kind, error.message if status != 502 else fallback)


def normalize_fusebox_view(view, provider, now=None):
    now = time.time() if now is None else now
    if not isinstance(view, dict):
        raise usage.ProviderFailure("malformed", "Fusebox returned invalid reset details.")
    operation = view.get("operation")
    if isinstance(operation, dict) and operation.get("status") in usage.RUST_UNSETTLED_RESETS:
        raise usage.ProviderFailure("config", "An earlier reset on this account has an unknown outcome. Review it in the Fusebox dashboard before using another.")
    if isinstance(view.get("error"), str) and view["error"].strip():
        raise usage.ProviderFailure("http", "Fusebox could not read this account's resets: " + usage.clean_message(view["error"])[:160])
    inventory = view.get("inventory")
    if not isinstance(inventory, dict) or not isinstance(inventory.get("grants", []), list) or len(inventory.get("grants", [])) > 1024:
        raise usage.ProviderFailure("malformed", "Fusebox returned invalid reset details.")
    available = count(inventory.get("available"))
    quote = view.get("quote")
    if not inventory.get("eligible") or not isinstance(quote, str):
        reason = inventory.get("reason")
        raise usage.ProviderFailure("unavailable", usage.clean_message(reason)[:200] if isinstance(reason, str) and reason.strip()
                                    else "No banked reset can be applied to this account right now.")
    try:
        if str(uuid.UUID(quote)) != quote:
            raise ValueError
    except (ValueError, TypeError, AttributeError):
        raise usage.ProviderFailure("malformed", "Fusebox returned an invalid reset confirmation.") from None
    credits, seen = [], set()
    for grant in inventory.get("grants", []):
        if not isinstance(grant, dict) or grant.get("usable") is not True:
            continue
        grant_id = grant.get("id")
        if not identifier(grant_id) or grant_id in seen:
            raise usage.ProviderFailure("malformed", "Fusebox returned invalid reset identifiers.")
        seen.add(grant_id)
        try:
            expiry = None if grant.get("expires_at") is None else timestamp(grant["expires_at"])
            granted = None if grant.get("granted_at") is None else timestamp(grant["granted_at"])
        except (ValueError, TypeError, OverflowError):
            raise usage.ProviderFailure("malformed", "Fusebox returned invalid reset dates.") from None
        if expiry is not None and expiry <= now:
            continue
        clears = [usage.clean_message(c) for c in grant.get("clears", []) if isinstance(c, str)][:8] \
            if isinstance(grant.get("clears"), list) else []
        remaining = count(grant.get("remaining"))
        description = ("Clears " + ", ".join(clears) if clears and "*" not in clears else "Resets the current usage limits.")
        if remaining is not None and remaining > 1:
            description += f" {remaining} uses left in this grant."
        credits.append({"id": grant_id, "expiresAt": expiry, "grantedAt": granted,
                        "title": usage.clean_message(grant.get("label") or "Banked reset")[:80],
                        "description": description, "recommended": grant_id == inventory.get("selected_grant")})
    # Fusebox's recommendation first, then the grant expiring soonest.
    credits.sort(key=lambda c: (not c["recommended"], c["expiresAt"] if c["expiresAt"] is not None else float("inf"), c["id"]))
    if not credits and provider == "codex" and available:
        # Codex may list no credit IDs; Fusebox then uses the one expiring first.
        credits.append({"id": "", "expiresAt": None, "grantedAt": None, "title": "Earliest-expiring reset",
                        "description": "Fusebox selects the reset that expires first.", "unknownExpiry": True})
    if not credits:
        raise usage.ProviderFailure("unavailable", "No usable banked reset was found for this account.")
    return {"availableCount": available if available is not None else len(credits),
            "applicableAvailableCount": count(inventory.get("applicable")),
            "credits": credits, "requestId": quote}


def execute_fusebox(client, entry, action, account_id, target, credit_id, request_id, retry, remaining):
    provider = provider_of(entry)
    if entry.get("disabled") is True:
        raise usage.ProviderFailure("config", "This account is paused in Fusebox.")
    if entry.get("kind") != "oauth":
        raise usage.ProviderFailure("unsupported", "Banked resets need a Claude or Codex subscription sign-in.")
    path = fusebox_path(entry)
    current_target = hashlib.sha256(json.dumps([account_id, entry["_native_id"], provider, "fusebox"]).encode()).hexdigest()
    if action == "prepare":
        try:
            view = client.request(path, remaining(), native=True)
        except usage.ProviderFailure as error:
            raise fusebox_failure(error, "Fusebox could not read this account's banked resets.") from None
        return dict(normalize_fusebox_view(view, provider), target=current_target)
    if action != "consume" or target != current_target or (credit_id and not identifier(credit_id)) \
            or (not credit_id and provider != "codex"):
        raise usage.ProviderFailure("config", "The selected account changed. Open a new reset confirmation.")
    try:
        if str(uuid.UUID(request_id)) != request_id:
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise usage.ProviderFailure("config", "Invalid reset request identifier.") from None
    def post(action_name):
        body = {"action": action_name, "request_id": request_id, "grant_id": credit_id, "confirmed": True}
        try:
            view = client.request(path, remaining(), body, native=True)
        except usage.ProviderFailure as error:
            status = getattr(error, "http_status", None)
            # 4xx refusals happen before dispatch; anything else may have spent a reset.
            failure = fusebox_failure(error, "Fusebox could not complete the reset request.")
            if status not in (400, 401, 403, 404, 409, 429):
                failure.submitted = True
            raise failure from None
        operation = view.get("operation") if isinstance(view, dict) else None
        return (operation.get("status") if isinstance(operation, dict) else None,
                usage.clean_message(operation.get("message"))[:200] if isinstance(operation, dict) else "",
                isinstance(view, dict) and view.get("retryable") is True)

    # Fusebox journals each request ID before spending, so repeating "redeem"
    # with the same ID returns the recorded outcome instead of spending again.
    status, message, retryable = post("redeem")
    if retry and status in usage.RUST_UNSETTLED_RESETS and provider == "claude" and retryable:
        status, message, _ = post("retry")
    if status not in FUSEBOX_OUTCOMES:
        error = usage.ProviderFailure("uncertain", (message.rstrip(".") + ". " if message else "")
                                      + ("Retry checks the same request without spending another reset." if provider == "claude"
                                         else "Check the outcome in the Fusebox dashboard and record it there, then retry to update."))
        error.submitted = True
        raise error
    return {"outcome": FUSEBOX_OUTCOMES[status], "message": message}


def resolve_account(entry, account_id):
    if entry.get("disabled") is True or entry.get("status") == "disabled":
        raise usage.ProviderFailure("config", "This account is paused in CLIProxyAPI.")
    claims = entry.get("id_token") if isinstance(entry.get("id_token"), dict) else {}
    chatgpt_id = entry.get("chatgpt_account_id") or claims.get("chatgpt_account_id")
    index = entry.get("auth_index") or entry.get("authIndex")
    if not identifier(chatgpt_id) or not identifier(index):
        raise usage.ProviderFailure("config", "The managed account is missing its sign-in identifiers.")
    target = hashlib.sha256(json.dumps([account_id, index, chatgpt_id]).encode()).hexdigest()
    headers = {"ChatGPT-Account-Id": chatgpt_id, "User-Agent": "codex-cli",
               "OpenAI-Beta": "codex-1", "Content-Type": "application/json"}
    return entry, target, headers


def execute(client, action, account_id, target="", credit_id="", request_id="", timeout=12, retry=False):
    deadline = time.monotonic() + timeout

    def remaining():
        seconds = deadline - time.monotonic()
        if seconds <= 0:
            raise usage.ProviderFailure("timeout", "The reset request timed out.")
        return seconds

    entry = find_account(client, account_id, remaining)
    if entry.get("_rust") is True:
        return execute_fusebox(client, entry, action, account_id, target, credit_id, request_id, retry, remaining)
    entry, current_target, headers = resolve_account(entry, account_id)
    if action == "prepare":
        details = normalize_details(client.usage(entry, RESET_URL, headers, remaining()))
        return dict(details, target=current_target, requestId=str(uuid.uuid4()))
    if action != "consume" or target != current_target or not identifier(credit_id):
        raise usage.ProviderFailure("config", "The selected account changed. Open a new reset confirmation.")
    try:
        if str(uuid.UUID(request_id)) != request_id:
            raise ValueError()
    except (ValueError, TypeError, AttributeError):
        raise usage.ProviderFailure("config", "Invalid reset request identifier.") from None
    try:
        payload = client.usage(entry, RESET_URL + "/consume", headers, remaining(),
                              data={"credit_id": credit_id, "redeem_request_id": request_id})
    except usage.ProviderFailure as error:
        error.submitted = True
        raise
    outcome = payload.get("code") if isinstance(payload, dict) else None
    if outcome not in ("reset", "nothing_to_reset", "no_credit", "already_redeemed"):
        error = usage.ProviderFailure("malformed", "The server did not confirm the reset outcome.")
        error.submitted = True
        raise error
    return {"outcome": outcome}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--action", required=True, choices=("prepare", "consume"))
    parser.add_argument("--account-id", required=True)
    connection.add_arguments(parser)
    parser.add_argument("--target", default="")
    parser.add_argument("--credit-id", default="")
    parser.add_argument("--request-id", default="")
    parser.add_argument("--retry", action="store_true", help="Retry an uncertain Fusebox Claude reset")
    args = parser.parse_args()
    try:
        client = connection.client_from_args(args)
        result = execute(client, args.action, args.account_id, args.target, args.credit_id, args.request_id,
                         retry=args.retry)
        result.update(ok=True, schemaVersion=1)
    except usage.ProviderFailure as error:
        result = {"schemaVersion": 1, "ok": False, "message": error.message,
                  "uncertain": getattr(error, "submitted", False)}
    except Exception:
        result = {"schemaVersion": 1, "ok": False, "message": "Could not complete the reset request.",
                  "uncertain": args.action == "consume"}
    print(json.dumps(result))


if __name__ == "__main__":
    main()
