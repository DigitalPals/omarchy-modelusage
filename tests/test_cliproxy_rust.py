from __future__ import annotations

import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from contextlib import contextmanager
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock

from test_backend import ROOT, BACKEND, fixture, usage
import proxy_connection as connection

NOW = 1893456060


def account(**overrides):
    return dict(fixture("cliproxy-rust-accounts.json")[0], _rust=True, **overrides)


@contextmanager
def proxy_server(document=None, legacy_status=401, native_status=200, usage_state=None):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            requests.append((self.command, self.path))
            if self.headers.get("Authorization") != "Bearer test-management-key":
                status, payload = 401, {"error": "unauthorized"}
            elif self.path == "/v0/management/auth-files":
                status, payload = legacy_status, {"error": "unsupported"}
            elif self.path == "/api/accounts":
                status, payload = native_status, document if document is not None else fixture("cliproxy-rust-accounts.json")
            elif self.path == "/api/usage/status" and usage_state is not None:
                status, payload = 200, {"health": {"state": usage_state}, "imports": [], "collectors": []}
            else:
                status, payload = 404, {}
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())

        def do_POST(self):
            requests.append((self.command, self.path))
            self.send_error(500, "Actions must not be called")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class RustQuotaTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(usage.time, "time", return_value=NOW)
        patch.start()
        self.addCleanup(patch.stop)

    def test_windows_plan_and_unavailable_credits(self):
        row = usage.fetch_rust_account("claude", account())
        self.assertEqual(row["status"], "ok")
        self.assertEqual([w["remaining"] for w in row["windows"]], [75, 50, 30])
        self.assertEqual([w["windowSeconds"] for w in row["windows"][:2]], [18000, 604800])
        self.assertIn("Opus", row["windows"][2]["label"])
        self.assertEqual(row["quotaUpdatedAt"], NOW - 60)
        self.assertFalse(row["stale"])
        self.assertFalse(row["supportsBankedReset"])
        self.assertIsNone(row["credits"])
        codex = dict(fixture("cliproxy-rust-accounts.json")[2], _rust=True)
        row = usage.fetch_rust_account("codex", codex)
        self.assertEqual(row["planType"], "pro")
        self.assertEqual(row["plan"], "ChatGPT Pro")
        self.assertEqual(len(row["windows"]), 1)
        self.assertEqual(row["windows"][0]["used"], 0)

    def test_missing_cache_expired_windows_and_invalid_times_do_not_claim_capacity(self):
        for quota in ({"windows": [], "updated_at": None},
                      {"windows": [], "updated_at": "2030-01-01T00:00:00Z"},
                      {"windows": [{"name": "5h", "used": 80, "resets_at": "2029-12-31T00:00:00Z"}], "updated_at": "2030-01-01T00:00:00Z"},
                      {"windows": [{"name": "5h", "used": 80}], "updated_at": "2030-01-01T00:00:00"},
                      {"windows": [{"name": "5h", "used": 80}], "updated_at": "2031-01-01T00:00:00Z"}):
            with self.subTest(quota=quota):
                row = usage.fetch_rust_account("claude", account(quota=quota))
                self.assertEqual(row["status"], "error")
                self.assertEqual(row["windows"], [])
                self.assertIsNone(row["credits"])

    def test_invalid_quota_numbers_windows_and_metadata_are_errors(self):
        for change in ({"used": True}, {"used": "20"}, {"used": -1}, {"used": 101},
                       {"used": float("nan")}, {"used": float("inf")}, {"used": None},
                       {"model": {}}, {"resets_at": "bad"}, {"name": ""}):
            quota = copy.deepcopy(account()["quota"])
            quota["windows"][0].update(change)
            with self.subTest(change=change):
                self.assertEqual(usage.fetch_rust_account("claude", account(quota=quota))["errorKind"], "malformed")
        for change in ({"plan": {}}, {"windows": [{}] * 129}, {"windows": [account()["quota"]["windows"][0]] * 2}):
            quota = dict(account()["quota"], **change)
            self.assertEqual(usage.fetch_rust_account("claude", account(quota=quota))["status"], "error")

    def test_disabled_and_unqueried_providers_stay_visible(self):
        self.assertEqual(usage.fetch_rust_account("claude", account(disabled=True))["status"], "disabled")
        self.assertEqual(usage.fetch_rust_account("gemini", account(provider="gemini"))["status"], "unsupported")
        self.assertEqual(usage.fetch_rust_account("codex", account(kind="api-key"))["status"], "unsupported")

    def test_stale_cache_and_repeated_observations_do_not_extend_history(self):
        row = usage.fetch_rust_account("claude", account())
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary)
            usage.update_and_attach_history([row], state, now=NOW)
            original = (state / "history.json").read_text()
            usage.update_and_attach_history([row], state, now=NOW + 120)
            self.assertEqual((state / "history.json").read_text(), original)
            with mock.patch.object(usage.time, "time", return_value=NOW + 601):
                stale = usage.fetch_rust_account("claude", account())
            self.assertTrue(stale["stale"])
            usage.update_and_attach_history([stale], state, now=NOW + 601)
            self.assertEqual((state / "history.json").read_text(), original)
            self.assertEqual(stale["fetchedAt"], row["fetchedAt"])


class RustIntegrationTests(unittest.TestCase):
    def test_legacy_auth_failures_and_missing_paths_detect_rust_with_same_key(self):
        for status in (401, 403, 404, 405):
            with self.subTest(status=status), proxy_server(legacy_status=status) as (url, requests):
                # A Go hint left over from an earlier server still finds Fusebox.
                client = connection.ProxyClient(url, "test-management-key", "go")
                rows = client.accounts(2)
                self.assertEqual(client.implementation, "rust")
                self.assertEqual(len(rows), 4)
                self.assertEqual(rows[0]["id"], "claude-one.json")
                self.assertEqual(usage.cliproxy_account_record("claude", rows[0])["accountId"],
                                 usage.cliproxy_account_record("claude", {"id": "claude-one.json"})["accountId"])
                client.accounts(2)
                self.assertEqual(requests[-1], ("GET", "/api/accounts"))
                with self.assertRaises(usage.ProviderFailure):
                    client.usage(rows[0], "https://upstream.invalid/action", {}, 1, data={})
                self.assertTrue(all(method == "GET" for method, _ in requests))

    def test_wrong_key_and_invalid_native_shape_never_succeed(self):
        with proxy_server() as (url, requests):
            client = connection.ProxyClient(url, "wrong-key")
            with self.assertRaises(usage.ProviderFailure) as error:
                client.accounts(2)
            self.assertEqual(error.exception.kind, "config")
            self.assertEqual(client.implementation, "auto")
        for document in ({"files": []}, [None], [{"id": "x", "provider": "codex"}],
                         [dict(account(), disabled="false")], [dict(account(), file="mismatch.json")],
                         [account(), account()], [{}] * 4097):
            with self.subTest(document=str(document)[:80]), proxy_server(document=document) as (url, requests):
                client = connection.ProxyClient(url, "test-management-key")
                with self.assertRaises(usage.ProviderFailure) as error:
                    client.accounts(2)
                self.assertEqual(error.exception.kind, "malformed")
                self.assertEqual(client.implementation, "auto")

    def test_empty_inventory_is_valid_and_legacy_outages_are_not_reinterpreted(self):
        with proxy_server(document=[]) as (url, requests):
            client = connection.ProxyClient(url, "test-management-key")
            self.assertEqual(client.accounts(2), [])
            self.assertEqual(client.implementation, "rust")
        with proxy_server(legacy_status=500) as (url, requests):
            with self.assertRaises(usage.ProviderFailure):
                connection.ProxyClient(url, "test-management-key", "go").accounts(2)
            self.assertEqual(requests, [("GET", "/v0/management/auth-files")])
        with proxy_server(native_status=500) as (url, requests):
            with self.assertRaises(usage.ProviderFailure):
                connection.ProxyClient(url, "test-management-key").accounts(2)
            self.assertEqual(requests, [("GET", "/api/accounts")])

    def test_fusebox_is_probed_first_and_needs_one_request(self):
        for hint in ("auto", "rust"):
            with self.subTest(hint=hint), proxy_server() as (url, requests):
                client = connection.ProxyClient(url, "test-management-key", hint)
                self.assertEqual(len(client.accounts(2)), 4)
                self.assertEqual(client.implementation, "rust")
                self.assertEqual(requests, [("GET", "/api/accounts")])

    def test_detection_failures_name_both_implementations_when_ambiguous(self):
        with proxy_server(legacy_status=404, native_status=404) as (url, requests):
            with self.assertRaises(usage.ProviderFailure) as error:
                connection.ProxyClient(url, "test-management-key").accounts(2)
            self.assertEqual(error.exception.kind, "http")
            self.assertIn("No Fusebox or CLIProxyAPI management API", error.exception.message)
        with proxy_server() as (url, requests):
            with self.assertRaises(usage.ProviderFailure) as error:
                connection.ProxyClient(url, "wrong-key").accounts(2)
            self.assertEqual(error.exception.kind, "config")
            self.assertIn("Fusebox / CLIProxyAPI rejected", error.exception.message)
        # A route that is absent says less than an authenticated rejection.
        with proxy_server(legacy_status=404, native_status=403) as (url, requests):
            with self.assertRaises(usage.ProviderFailure) as error:
                connection.ProxyClient(url, "test-management-key").accounts(2)
            self.assertIn("Fusebox rejected", error.exception.message)

    def test_detection_shares_a_deadline(self):
        client = connection.ProxyClient("https://proxy.invalid", "key")
        failure = usage.ProviderFailure("config", "Rejected")
        failure.http_status = 401
        with mock.patch.object(client, "request", side_effect=failure) as request, \
                mock.patch.object(usage.time, "monotonic", side_effect=[100, 102]):
            with self.assertRaises(usage.ProviderFailure) as error:
                client.accounts(1)
        self.assertEqual(error.exception.kind, "timeout")
        self.assertEqual(request.call_count, 1)

    def test_native_response_limit_is_enforced(self):
        with proxy_server(document=[{"padding": "x" * (usage.MAX_HTTP_RESPONSE_BYTES + 1)}]) as (url, requests):
            with self.assertRaises(usage.ProviderFailure) as error:
                connection.ProxyClient(url, "test-management-key").accounts(2)
            self.assertEqual(error.exception.kind, "malformed")

    def test_subprocess_discovery_and_native_activity_only_read_account_api(self):
        document = fixture("cliproxy-rust-accounts.json")
        now = time.time()
        for row in document:
            row["last_used"] = datetime.fromtimestamp(now - 30, timezone.utc).isoformat() if row["last_used"] else None
            if row["quota"]["updated_at"]:
                row["quota"]["updated_at"] = datetime.fromtimestamp(now - 20, timezone.utc).isoformat()
        with proxy_server(document=document) as (url, requests), tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "key"
            key.write_text("test-management-key")
            key.chmod(0o600)
            args = ["--cliproxy-url", url, "--cliproxy-key-file", str(key), "--timeout", "2"]
            output = subprocess.check_output([sys.executable, "-B", str(BACKEND), "--source", "cliproxy",
                                              "--state-dir", temporary, *args], text=True)
            result = json.loads(output)
            self.assertEqual(result["proxyImplementation"], "rust")
            self.assertEqual(len(result["providers"]), 3)
            self.assertEqual(next(p for p in result["providers"] if p["id"] == "codex")["status"], "ok")
            activity = json.loads(subprocess.check_output([sys.executable, "-B", str(ROOT / "scripts/proxy-activity.py"), *args]))
            self.assertEqual(activity["error"], "")
            self.assertEqual(len(activity["providers"]), 2)
            self.assertEqual(next(p for p in activity["providers"] if p["id"] == "claude")["status"], "ambiguous")
            self.assertNotIn("test-management-key", output)
            self.assertNotIn("file:", output)
            self.assertTrue(all(method == "GET" and path in ("/api/accounts", "/v0/management/auth-files") for method, path in requests))

RESET_QUOTE = "3f1c2a9e-8b7d-4c6e-9f0a-1b2c3d4e5f60"


def full_claude(**overrides):
    row = account(**overrides.pop("base", {}))
    row["quota"] = dict(row["quota"], plan="max_20x", plan_name="Ultra", no_five_hour_limit=True,
                        renewal={"at": "2030-01-12T00:00:00Z", "estimated": False, "ends": False,
                                 "period": "monthly", "manual": False},
                        limits=[
                            {"id": "cowork", "name": "Weekly Cowork", "scope": {"kind": "feature", "value": "cowork"},
                             "used_percent": 90, "used": None, "limit": None, "remaining": None, "unit": None,
                             "unlimited": None, "enabled": None, "resets_at": "2030-01-08T00:00:00Z"},
                            {"id": "extra_usage", "name": "Monthly extra usage", "scope": {"kind": "overage"},
                             "used_percent": 25, "used": 500, "limit": 2000, "remaining": None, "unit": "USD cents",
                             "unlimited": None, "enabled": True, "resets_at": "2030-02-01T00:00:00Z"},
                            {"id": "scoped:weekly_scoped:claude-haiku", "name": "Haiku", "scope": {"kind": "model", "value": "claude-haiku"},
                             "used_percent": 80, "used": None, "limit": None, "remaining": None, "unit": None,
                             "unlimited": None, "enabled": True, "resets_at": "2030-01-08T00:00:00Z"},
                            {"id": "codex:gate", "name": "Account allowance", "scope": {"kind": "account"},
                             "used_percent": 0, "used": None, "limit": None, "remaining": None, "unit": None,
                             "unlimited": None, "enabled": None, "resets_at": None},
                        ])
    row.update(cooldowns={"claude-opus-4": "2030-01-01T00:31:00Z", "*": "2029-12-31T00:00:00Z"},
               cooldown_kinds={"claude-opus-4": "rate_limit", "*": "quota"}, priority="last",
               last_error="Upstream 529 overloaded for one@example.invalid",
               banked_resets={"checked_at": "2030-01-01T00:00:00Z", "error": None, "quote": RESET_QUOTE,
                              "operation": None, "retryable": False,
                              "inventory": {"available": 2, "applicable": 1, "eligible": True, "grants": [],
                                            "reason": None, "selected_grant": None}})
    row.update(overrides)
    return row


class FuseboxQuotaTests(unittest.TestCase):
    def setUp(self):
        patch = mock.patch.object(usage.time, "time", return_value=NOW)
        patch.start()
        self.addCleanup(patch.stop)

    def test_full_snapshot_maps_limits_credits_plan_and_account_facts(self):
        row = usage.fetch_rust_account("claude", full_claude())
        self.assertEqual(row["status"], "ok")
        self.assertEqual(row["plan"], "Claude Ultra")
        labels = {w["label"]: w for w in row["windows"]}
        self.assertTrue(labels["Weekly Cowork"]["informational"])
        self.assertEqual(labels["Haiku"]["used"], 80)
        self.assertNotIn("informational", labels["Haiku"])
        self.assertFalse(any("Account allowance" in label for label in labels))
        # Informational allowances never become the binding window.
        self.assertEqual(usage.dynamic_window_used(row), 80)
        self.assertEqual(row["credits"]["label"], "Extra usage")
        self.assertEqual((row["credits"]["used"], row["credits"]["limit"], row["credits"]["remaining"]), (5, 20, 15))
        self.assertEqual(row["credits"]["resetCreditsAvailable"], 2)
        self.assertTrue(row["supportsBankedReset"])
        texts = [item["text"] for item in row["statusItems"]]
        self.assertIn("claude-opus-4 · Rate limited", texts)
        self.assertIn("No 5-hour limit", texts)
        self.assertIn("Renews", texts)
        self.assertIn("Takes new sessions last", texts)
        self.assertFalse(any("Usage limit used up" in text for text in texts))  # Expired cooldown.
        error = next(text for text in texts if text.startswith("Last error"))
        self.assertNotIn("example.invalid", error)

    def test_sign_in_failures_and_unsettled_resets(self):
        row = usage.fetch_rust_account("claude", full_claude(last_error="OAuth refresh failed: invalid_grant"))
        self.assertEqual((row["status"], row["errorKind"]), ("error", "expired"))
        resets = dict(full_claude()["banked_resets"], operation={"status": "unknown", "request_id": RESET_QUOTE})
        row = usage.fetch_rust_account("claude", full_claude(banked_resets=resets))
        self.assertIsNone(row["credits"]["resetCreditsAvailable"] if "resetCreditsAvailable" in row["credits"] else None)
        self.assertFalse(row["supportsBankedReset"])
        self.assertTrue(any("needs review" in item["text"] for item in row["statusItems"]))
        row = usage.fetch_rust_account("claude", full_claude(banked_resets=None))
        self.assertFalse(row["supportsBankedReset"])

    def test_codex_tiers_credits_spending_and_gates(self):
        base = dict(fixture("cliproxy-rust-accounts.json")[2], _rust=True)
        base["quota"] = dict(base["quota"], subscription_plan="chatgptpromax", limits=[
            {"id": "individual_spending", "name": "Individual spending limit", "scope": {"kind": "account"},
             "used_percent": 60, "used": 30, "limit": 50, "remaining": None, "unit": None,
             "unlimited": None, "enabled": None, "resets_at": None},
            {"id": "credits", "name": "Account credits", "scope": {"kind": "credits"}, "used_percent": None,
             "used": None, "limit": None, "remaining": 12.5, "unit": None, "unlimited": False, "enabled": None,
             "resets_at": None},
            {"id": "codex:gate", "name": "Account allowance", "scope": {"kind": "account"}, "used_percent": 100,
             "used": None, "limit": None, "remaining": None, "unit": None, "unlimited": None, "enabled": None,
             "resets_at": "2030-01-02T00:00:00Z"},
        ])
        row = usage.fetch_rust_account("codex", base)
        self.assertEqual((row["planType"], row["plan"]), ("promax", "Codex Pro 500"))
        self.assertEqual(row["credits"]["remaining"], 12.5)
        labels = [w["label"] for w in row["windows"]]
        self.assertIn("Individual spending limit", labels)
        self.assertIn("Account allowance · Limit reached", labels)
        self.assertEqual(usage.dynamic_window_used(row), 100)
        spending = next(w for w in row["windows"] if w["label"] == "Individual spending limit")
        self.assertEqual(spending["detail"], "30 of 50 used")
        lite = dict(base, quota=dict(base["quota"], subscription_plan="chatgptprolite"))
        self.assertEqual(usage.fetch_rust_account("codex", lite)["planType"], "prolite")

    def test_meta_antigravity_and_unsupported_providers(self):
        meta = account(provider="meta", quota={"updated_at": "2030-01-01T00:00:00Z", "plan_name": "Max Usage", "windows": [
            {"name": "5h", "used": 40, "resets_at": "2030-01-01T04:00:00Z"},
            {"name": "week", "used": 10, "resets_at": "2030-01-07T00:00:00Z"}]})
        row = usage.fetch_rust_account("meta", meta)
        self.assertEqual((row["status"], row["plan"]), ("ok", "Max Usage"))
        self.assertEqual([w["label"] for w in row["windows"]], ["5 hour limit", "Weekly limit"])
        antigravity = account(provider="antigravity", quota={"updated_at": "2030-01-01T00:00:00Z", "windows": [], "limits": [
            {"id": "antigravity:g:b", "name": "Gemini models · 5h", "scope": {"kind": "model_families", "value": ["gemini-"]},
             "used_percent": 35, "used": None, "limit": None, "remaining": None, "unit": None,
             "unlimited": None, "enabled": None, "resets_at": "2030-01-01T03:00:00Z"}]})
        row = usage.fetch_rust_account("antigravity", antigravity)
        self.assertEqual(row["status"], "ok")
        self.assertEqual(row["windows"][0]["remaining"], 65)
        kimi = usage.fetch_rust_account("kimi", account(provider="kimi"))
        self.assertEqual(kimi["status"], "unsupported")
        self.assertIn("Kimi", kimi["notice"])
        self.assertEqual(usage.fetch_rust_account("grok", account(provider="grok"))["status"], "unsupported")

    def test_claude_overage_included_week_is_the_fable_week(self):
        week = {"name": "week", "used": 25, "resets_at": "2030-01-08T00:00:00Z"}
        overage = {"name": "week overage", "used": 40, "resets_at": "2030-01-08T00:00:00Z"}
        fable = {"name": "week fable", "model": "fable", "used": 61, "resets_at": "2030-01-08T00:00:00Z"}
        alone = usage.fetch_rust_account("claude", account(quota=dict(account()["quota"], windows=[week, overage])))
        self.assertEqual([(w["label"], w.get("model")) for w in alone["windows"]],
                         [("Weekly limit", None), ("Fable weekly", "fable")],
                         "Claude Code calls seven_day_overage_included the Fable limit")
        both = usage.fetch_rust_account("claude", account(quota=dict(account()["quota"], windows=[week, overage, fable])))
        self.assertEqual([(w["label"], w["remaining"]) for w in both["windows"]],
                         [("Weekly limit", 75), ("Fable weekly", 39)], "the typed Fable entry wins over the flat field")
        opus = usage.fetch_rust_account("claude", account(quota=dict(account()["quota"], windows=[
            {"name": "5h opus", "model": "opus", "used": 10, "resets_at": "2030-01-01T05:00:00Z"}])))
        self.assertEqual(opus["windows"][0]["label"], "Opus · 5 hour limit", "other durations keep their length")
        self.assertEqual(opus["windows"][0]["model"], "opus")
        codex = usage.fetch_rust_account("codex", account(provider="codex", quota=dict(account()["quota"], windows=[
            {"name": "week overage", "used": 40, "resets_at": "2030-01-08T00:00:00Z"}])))
        self.assertEqual(codex["windows"][0]["label"], "Extra usage · Weekly limit", "only Claude's overage week is Fable")
        self.assertNotIn("model", codex["windows"][0])

    def test_scoped_window_names_and_invalid_limits(self):
        quota = dict(account()["quota"], windows=[
            {"name": "week oauth apps", "used": 30, "resets_at": "2030-01-08T00:00:00Z"},
            {"name": "week fable", "model": "fable", "used": 45, "resets_at": "2030-01-08T00:00:00Z"},
            {"name": "3d", "used": 5, "resets_at": "2030-01-03T00:00:00Z"}])
        row = usage.fetch_rust_account("claude", account(quota=quota))
        self.assertEqual([w["label"] for w in row["windows"]],
                         ["OAuth apps · Weekly limit", "Fable weekly", "3 day limit"])
        self.assertEqual([w.get("model") for w in row["windows"]], [None, "fable", None])
        self.assertEqual(row["windows"][1]["windowSeconds"], usage.SEVEN_DAYS)
        self.assertEqual(row["windows"][2]["windowSeconds"], 3 * 86400)
        for bad in ([{"id": "x", "name": "X", "scope": "account"}], [{"id": "x", "name": "X", "scope": {"kind": "nope"}}],
                    [{"id": "x", "name": "X", "scope": {"kind": "model", "value": 3}, "used_percent": 5}], {}):
            with self.subTest(bad=bad):
                broken = dict(account()["quota"], limits=bad)
                self.assertEqual(usage.fetch_rust_account("claude", account(quota=broken))["errorKind"], "malformed")


@contextmanager
def fusebox_reset_server(view=None, post=None, accounts=None):
    requests = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def reply(self, status, payload):
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(payload).encode())

        def do_GET(self):
            requests.append(("GET", self.path, None))
            if self.path == "/v0/management/auth-files":
                return self.reply(401, {})
            if self.path == "/api/accounts":
                return self.reply(200, accounts if accounts is not None else [full_claude(), fixture("cliproxy-rust-accounts.json")[2]])
            if self.path.endswith("/banked-resets"):
                return self.reply(*(view or (200, {})))
            return self.reply(404, {})

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(("POST", self.path, body))
            return self.reply(*(post or (500, {"error": "unexpected"})))

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


class FuseboxResetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("fusebox_reset_test", ROOT / "scripts/reset-credit.py")
        cls.reset = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.reset)

    def run_reset(self, url, provider, *extra):
        with tempfile.TemporaryDirectory() as temporary:
            key = Path(temporary) / "key"
            key.write_text("test-management-key")
            key.chmod(0o600)
            name = "claude-one.json" if provider == "claude" else "codex-one.json"
            account_id = usage.cliproxy_account_record(provider, {"id": name})["accountId"]
            args = [sys.executable, "-B", str(ROOT / "scripts/reset-credit.py"), "--cliproxy-url", url,
                    "--cliproxy-key-file", str(key), "--account-id", account_id, *extra]
            return json.loads(subprocess.check_output(args)), account_id

    def view(self, **inventory):
        grants = [{"id": "grant-late", "label": "Weekly reset", "remaining": 1, "total": 1, "granted_at": "2026-01-01T00:00:00Z",
                   "expires_at": "2099-02-01T00:00:00Z", "starts_at": None, "clears": ["week"], "usable": True, "reason": None},
                  {"id": "grant-soon", "label": "Full reset", "remaining": 1, "total": 1, "granted_at": None,
                   "expires_at": "2099-01-01T00:00:00Z", "starts_at": None, "clears": ["*"], "usable": True, "reason": None},
                  {"id": "grant-locked", "label": "Locked", "remaining": 1, "total": 1, "granted_at": None,
                   "expires_at": None, "starts_at": None, "clears": [], "usable": False, "reason": "Starts later"}]
        base = {"available": 3, "applicable": 2, "eligible": True, "grants": grants, "reason": None, "selected_grant": "grant-late"}
        base.update(inventory)
        return {"checked_at": "2030-01-01T00:00:00Z", "inventory": base, "error": None, "quote": RESET_QUOTE,
                "operation": None, "retryable": False}

    def test_prepare_and_redeem_claude_through_fusebox(self):
        with fusebox_reset_server(view=(200, self.view())) as (url, requests):
            prepared, account_id = self.run_reset(url, "claude", "--action", "prepare")
            self.assertTrue(prepared["ok"], prepared)
            self.assertEqual(prepared["requestId"], RESET_QUOTE)
            self.assertEqual([c["id"] for c in prepared["credits"]], ["grant-late", "grant-soon"])
            self.assertEqual(prepared["availableCount"], 3)
            self.assertEqual(requests[-1][:2], ("GET", "/api/accounts/file%3Aclaude-one.json/banked-resets"))
            self.assertFalse(any(method == "POST" for method, _, _ in requests))
        applied = {"operation": {"status": "applied", "message": "One banked reset applied", "request_id": RESET_QUOTE}}
        with fusebox_reset_server(post=(200, applied)) as (url, requests):
            result, _ = self.run_reset(url, "claude", "--action", "consume", "--target", prepared["target"],
                                       "--credit-id", "grant-late", "--request-id", RESET_QUOTE)
            self.assertEqual(result["outcome"], "reset")
            self.assertEqual(requests[-1][2], {"action": "redeem", "request_id": RESET_QUOTE,
                                               "grant_id": "grant-late", "confirmed": True})

    def test_refusals_unknown_outcomes_and_retries(self):
        prepared = None
        with fusebox_reset_server(view=(200, self.view())) as (url, _):
            prepared, _ = self.run_reset(url, "claude", "--action", "prepare")
        consume = ["--action", "consume", "--target", prepared["target"], "--credit-id", "grant-late", "--request-id", RESET_QUOTE]
        refused = {"operation": {"status": "refused", "message": "Nothing to reset yet"}}
        with fusebox_reset_server(post=(200, refused)) as (url, _):
            result, _ = self.run_reset(url, "claude", *consume)
            self.assertEqual((result["outcome"], result["message"]), ("refused", "Nothing to reset yet"))
        unknown = {"operation": {"status": "unknown", "message": "Outcome unknown"}}
        with fusebox_reset_server(post=(200, unknown)) as (url, _):
            result, _ = self.run_reset(url, "claude", *consume)
            self.assertFalse(result["ok"])
            self.assertTrue(result["uncertain"])
        with fusebox_reset_server(post=(409, {"error": "Confirmation expired; refresh resets and confirm again"})) as (url, _):
            result, _ = self.run_reset(url, "claude", *consume)
            self.assertFalse(result["uncertain"])
            self.assertIn("Confirmation expired", result["message"])
        with fusebox_reset_server(post=(200, {"operation": {"status": "applied", "message": ""}})) as (url, requests):
            result, _ = self.run_reset(url, "claude", *consume, "--retry")
            # A settled request is read back without a second spending call.
            self.assertEqual(result["outcome"], "reset")
            self.assertEqual([r[2]["action"] for r in requests if r[0] == "POST"], ["redeem"])
        pending = {"operation": {"status": "unknown", "message": "Outcome unknown"}, "retryable": True}
        with fusebox_reset_server(post=(200, pending)) as (url, requests):
            result, _ = self.run_reset(url, "claude", *consume, "--retry")
            self.assertTrue(result["uncertain"])
            self.assertEqual([r[2]["action"] for r in requests if r[0] == "POST"], ["redeem", "retry"])
        with fusebox_reset_server(view=(200, self.view(grants=[], selected_grant=None, available=1))) as (url, requests):
            codex, _ = self.run_reset(url, "codex", "--action", "prepare")
            self.assertEqual([c["id"] for c in codex["credits"]], [""])
        with fusebox_reset_server(post=(200, pending)) as (url, requests):
            result, _ = self.run_reset(url, "codex", "--action", "consume", "--target", codex["target"], "--credit-id", "",
                                       "--request-id", RESET_QUOTE, "--retry")
            # Codex has no retry guarantee: only the idempotent status check is sent.
            self.assertTrue(result["uncertain"])
            self.assertIn("Fusebox dashboard", result["message"])
            self.assertEqual([r[2] for r in requests if r[0] == "POST"],
                             [{"action": "redeem", "request_id": RESET_QUOTE, "grant_id": "", "confirmed": True}])

    def test_disabled_feature_ineligible_and_unsettled_reads_never_post(self):
        cases = [((404, {"error": "Banked resets are turned off"}), "turned off in Fusebox"),
                 ((200, self.view(eligible=False, reason="Weekly limit is not used yet")), "not used yet"),
                 ((200, dict(self.view(), operation={"status": "pending"})), "unknown outcome"),
                 ((200, dict(self.view(), quote="not-a-uuid")), "invalid reset confirmation")]
        for view, expected in cases:
            with self.subTest(expected=expected), fusebox_reset_server(view=view) as (url, requests):
                result, _ = self.run_reset(url, "claude", "--action", "prepare")
                self.assertFalse(result["ok"])
                self.assertIn(expected, result["message"])
                self.assertTrue(all(method == "GET" for method, _, _ in requests))
        # CLIProxyAPI still never treats a Claude account as resettable.
        self.assertEqual(self.reset.FUSEBOX_OUTCOMES["applied"], "reset")


class RustActivityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location("rust_activity_test", ROOT / "scripts/proxy-activity.py")
        cls.activity = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.activity)

    def test_activity_is_private_preserves_paused_latest_and_clears_after_restart(self):
        entries = [dict(row, _rust=True) for row in fixture("cliproxy-rust-accounts.json")]
        result = self.activity.normalize_rust_activity(entries, now=NOW)
        claude = next(p for p in result if p["id"] == "claude")
        self.assertEqual(claude["accountId"], self.activity.usage.cliproxy_account_record("claude", entries[1])["accountId"])
        self.assertNotIn("example.invalid", json.dumps(result))
        self.assertNotIn("claude-two.json", json.dumps(result))
        for entry in entries:
            entry["last_used"] = None
        self.assertEqual(self.activity.normalize_rust_activity(entries, now=NOW), [])

    def test_bad_activity_timestamps_are_not_accepted(self):
        for value in ("2030-01-01T00:00:00", "bad", "2031-01-01T00:00:00Z", 123):
            with self.subTest(value=value), self.assertRaises(self.activity.usage.ProviderFailure):
                self.activity.normalize_rust_activity([account(last_used=value)], now=NOW)

    def test_activity_timestamps_accept_rust_fractional_precision(self):
        for fraction in ("1", "12", "123", "1234", "12345", "123456", "123456789"):
            for timestamp in (f"2030-01-01T00:00:30.{fraction}Z",
                              f"2030-01-01T01:00:30.{fraction}+01:00"):
                with self.subTest(timestamp=timestamp):
                    expected = NOW - 30 + int((fraction + "000000")[:6]) / 1_000_000
                    self.assertEqual(self.activity.usage.rust_timestamp(timestamp, observed=True, now=NOW), expected)
