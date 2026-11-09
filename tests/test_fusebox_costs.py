from __future__ import annotations

import contextlib
import io
import json
import os
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs, urlsplit

from test_cost_backend import costs
import fusebox_costs as fusebox

KEY = "synthetic-fusebox-management-key"
NOW = int(time.time() * 1000)
TODAY = datetime.fromtimestamp(NOW / 1000, timezone.utc).date()
# Expensive enough that any accidental repricing would be obvious.
RATES = ({"claude-opus-test": (1.0, 1.0, 1.0, 1.0), "gpt-test": (1.0, 1.0, 1.0, 1.0)},
         {"status": "ok", "source": "test", "fetchedAt": None, "knownModels": 2, "message": ""})


def aggregate(observations, cost, unpriced=0, **extra):
    return {"observations": observations, "estimated_cost_nanos": cost, "unpriced": unpriced,
            "partial": 0, "tokens": {"input": 1000, "cache_read": 200, "cache_write": 30,
                                     "output": 400, "reasoning": 100, "write_5m": 30}, **extra}


TRENDS = {
    "anthropic": [{"date": TODAY.isoformat(), "group": "claude-opus-test", **aggregate(4, 3_250_000_000, 1)}],
    "openai": [{"date": TODAY.isoformat(), "group": "gpt-test", **aggregate(2, 500_000_000)}],
    "meta": [{"date": TODAY.isoformat(), "group": None, **aggregate(3, None, 3)}],
}


def record(provider, model, at=NOW - 60_000):
    return costs.UsageRecord(provider=provider, timestamp_ms=at, model=model, session_id="s",
                             uncached_input=10, cached_input=0, cache_creation=0, output=10,
                             reasoning=0, reported_cost_usd=None, dedupe_key=None)


LOCAL = ([record("claude", "claude-opus-test"), record("codex", "gpt-test")],
         [{"id": "claude", "name": "Claude Code", "status": "ok", "message": "", "scannedFiles": 1, "skippedFiles": 0},
          {"id": "codex", "name": "OpenAI Codex", "status": "ok", "message": "", "scannedFiles": 1, "skippedFiles": 0}])


class FuseboxServer:
    def __init__(self):
        self.requests = []
        self.mode = "ok"
        self.items = []
        self.weak = 0
        self.total_offset = 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                parts = urlsplit(self.path)
                query = {k: v[0] for k, v in parse_qs(parts.query).items()}
                owner.requests.append((parts.path, query, self.headers.get("Authorization")))
                if owner.mode == "unauthorized":
                    return self.reply(401, {"error": "unauthorized"})
                if owner.mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "http://127.0.0.1:9/elsewhere")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if owner.mode == "large":
                    return self.reply(200, {"pad": "x" * (fusebox.MAX_DASHBOARD_BYTES + 10)})
                if parts.path == "/api/usage/dashboard":
                    provider = query.get("provider")
                    trend = TRENDS.get(provider) if provider else [r for rows in TRENDS.values() for r in rows]
                    observed = sum(r["observations"] for r in trend) + (0 if provider else owner.total_offset)
                    return self.reply(200, {
                        "range": {}, "facets": {"providers": sorted(TRENDS), "accounts": [{"id": "private-account"}]},
                        "pricing": {"version": "t3-test", "basis": "Published API rates"},
                        "combined": {"totals": {"observations": observed, "weak_identity": owner.weak}, "trend": trend}})
                if parts.path == "/api/usage/observations":
                    offset, limit = int(query["offset"]), int(query["limit"])
                    return self.reply(200, {"items": owner.items[offset:offset + limit], "total": len(owner.items),
                                            "limit": limit, "offset": offset})
                self.reply(404, {"error": "missing"})

            def reply(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FuseboxCostTests(unittest.TestCase):
    def setUp(self):
        self.server = FuseboxServer()
        self.addCleanup(self.server.close)
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.key = self.root / "fusebox.key"
        self.key.write_text(KEY + "\n")
        os.chmod(self.key, 0o600)
        patcher = mock.patch.object(costs, "scan_transcripts", return_value=LOCAL)
        patcher.start()
        self.addCleanup(patcher.stop)

    def build(self, days=7, overlap="fusebox", url=None, **extra):
        config = {"url": url or self.server.url + "/management.html", "keyFile": str(self.key), "overlap": overlap}
        return costs.build_payload(["claude", "codex"], days, 5, self.root / "state", now_ms=NOW,
                                   zone_name="UTC", rates_override=RATES, fusebox=config, **extra)

    @staticmethod
    def sources(payload):
        return {source["id"]: source for source in payload["sources"]}

    def test_daily_uses_fusebox_estimates_buckets_and_replaces_transcripts(self):
        payload = self.build()
        providers = {p["id"]: p for p in payload["providers"]}
        self.assertEqual(list(providers), ["claude", "codex", "meta"])
        claude = providers["claude"]
        # Fusebox's $3.25 is kept; the $1/token test rate is never applied.
        self.assertEqual((claude["records"], claude["pricedRecords"], claude["unpricedRecords"]), (4, 3, 1))
        self.assertAlmostEqual(claude["costUsd"], 3.25)
        self.assertEqual((claude["uncachedInputTokens"], claude["cachedInputTokens"],
                          claude["cacheCreationTokens"], claude["outputTokens"], claude["reasoningTokens"]),
                         (1000, 200, 30, 400, 100))
        self.assertEqual(claude["costSource"], "mixed")
        self.assertEqual(providers["codex"]["costSource"], "fuseboxEstimated")
        self.assertIsNone(providers["meta"]["costUsd"])
        self.assertEqual(providers["meta"]["name"], "Meta")
        self.assertIn("Unknown model", {m["model"] for m in payload["models"]})
        self.assertAlmostEqual(payload["totals"]["costUsd"], 3.75)
        self.assertEqual(payload["totals"]["records"], 9)
        sources = self.sources(payload)
        for local in ("local-claude", "local-codex"):
            self.assertEqual(sources[local]["status"], "replaced")
            self.assertFalse(sources[local]["included"])
        self.assertTrue(all(sources[f"fusebox-{p}"]["included"] for p in ("claude", "codex", "meta")))
        self.assertEqual(payload["pricing"]["fusebox"], {"version": "t3-test", "basis": "Published API rates"})
        self.assertEqual(payload["periods"][-1]["historyStatus"], "recorded")
        self.assertNotIn("private-account", json.dumps(payload))
        self.assertNotIn(KEY, json.dumps(payload))

    def test_dashboard_requests_follow_the_range_contract_with_bearer_only(self):
        self.build(days=7)
        paths = {(path, query.get("provider")) for path, query, _ in self.server.requests}
        self.assertEqual(paths, {("/api/usage/dashboard", None), ("/api/usage/dashboard", "anthropic"),
                                 ("/api/usage/dashboard", "meta"), ("/api/usage/dashboard", "openai")})
        for _, query, auth in self.server.requests:
            self.assertEqual(auth, "Bearer " + KEY)
            self.assertEqual(query["start"], (TODAY - timedelta(days=6)).isoformat())
            self.assertEqual(query["end"], (TODAY + timedelta(days=1)).isoformat())  # Exclusive local midnight.
            self.assertEqual((query["timezone"], query["stack"]), ("UTC", "model"))
            self.assertNotIn(KEY, json.dumps(query))

    def test_transcript_mode_excludes_fusebox_claude_and_openai_only(self):
        payload = self.build(overlap="transcripts")
        sources = self.sources(payload)
        self.assertEqual(sources["fusebox-claude"]["status"], "excluded")
        self.assertEqual(sources["fusebox-codex"]["status"], "excluded")
        self.assertTrue(sources["fusebox-meta"]["included"])
        self.assertTrue(sources["local-claude"]["included"])
        providers = {p["id"]: p for p in payload["providers"]}
        # Local records are repriced locally; Fusebox's copy is not added.
        self.assertEqual(providers["claude"]["records"], 1)
        self.assertEqual(providers["codex"]["records"], 1)
        self.assertEqual(providers["meta"]["records"], 3)
        statuses = {row["id"]: row["status"] for row in payload["coverage"]}
        self.assertEqual(statuses["claude"], "ok")

    def test_transcript_mode_without_readable_transcripts_keeps_all_fusebox_history(self):
        with mock.patch.object(costs, "scan_transcripts", return_value=([], [])):
            payload = self.build(overlap="transcripts")
        self.assertEqual([p["id"] for p in payload["providers"]], ["claude", "codex", "meta"])
        self.assertAlmostEqual(payload["totals"]["costUsd"], 3.75)

    def test_unreadable_fusebox_falls_back_to_transcripts_and_reports_why(self):
        self.server.mode = "unauthorized"
        payload = self.build()
        sources = self.sources(payload)
        self.assertEqual(sources["fusebox"]["status"], "unavailable")
        self.assertIn("rejected the management key", sources["fusebox"]["message"])
        self.assertTrue(sources["local-claude"]["included"])
        self.assertNotIn(KEY, json.dumps(payload))

    def test_offline_server_reuses_private_snapshot_labelled_stale(self):
        fresh = self.build()
        self.server.mode = "unauthorized"
        stale = self.build()
        sources = self.sources(stale)
        self.assertEqual(sources["fusebox-claude"]["status"], "stale")
        self.assertIn("Saved Fusebox history", sources["fusebox-claude"]["message"])
        self.assertEqual(sources["local-claude"]["status"], "replaced")
        self.assertEqual(fresh["totals"]["records"], stale["totals"]["records"])
        snapshots = list((self.root / "state" / "fusebox").glob("fusebox-usage-*.json"))
        self.assertEqual(len(snapshots), 1)
        self.assertEqual(snapshots[0].stat().st_mode & 0o777, 0o600)
        text = snapshots[0].read_text()
        self.assertNotIn(KEY, text)
        self.assertNotIn("private-account", text)

    def test_unreconciled_totals_and_weak_identities_are_disclosed(self):
        self.server.total_offset = 5
        self.server.weak = 7
        sources = self.sources(self.build())
        self.assertEqual(sources["fusebox-claude"]["status"], "partial")
        self.assertIn("did not reconcile", sources["fusebox-claude"]["message"])
        self.assertIn("7 imported Fusebox entries", sources["fusebox-claude"]["message"])

    def test_past_day_pages_combined_observations_without_double_counting(self):
        old = NOW - 25 * 3_600_000
        self.server.items = [
            {"id": 9, "event_at_ms": NOW - 1000, "provider": "openai", "actual_model": "gpt-test",
             "tokens": {"input": 5, "output": 2}, "estimated_cost_nanos": 1_000_000, "account_id": "private-account"},
            {"id": 8, "event_at_ms": NOW - 2000, "provider": "anthropic", "actual_model": None,
             "requested_model": "claude-opus-test", "tokens": {"input": 7, "output": 3}, "estimated_cost_nanos": None},
            {"id": 8, "event_at_ms": NOW - 2000, "provider": "anthropic", "actual_model": None,
             "requested_model": "claude-opus-test", "tokens": {"input": 7, "output": 3}, "estimated_cost_nanos": None},
            {"id": 7, "event_at_ms": NOW - 3000, "provider": "grok", "actual_model": "grok-test",
             "tokens": {"input": 1, "output": 1}, "estimated_cost_nanos": 2_000_000},
            {"id": 6, "event_at_ms": old, "provider": "openai", "actual_model": "gpt-test",
             "tokens": {"input": 1, "output": 1}, "estimated_cost_nanos": 5_000_000_000},
            {"id": 5, "event_at_ms": old - 1, "provider": "openai", "actual_model": "gpt-test",
             "tokens": {"input": 1, "output": 1}, "estimated_cost_nanos": 5_000_000_000},
        ]
        with mock.patch.object(fusebox, "PAGE_SIZE", 2):
            payload = self.build(days=1)
        offsets = [int(q["offset"]) for path, q, _ in self.server.requests if path == "/api/usage/observations"]
        self.assertEqual(offsets, [0, 2, 4])  # Stops at the first page older than 24 hours.
        providers = {p["id"]: p for p in payload["providers"]}
        self.assertEqual(providers["codex"]["records"], 1)
        self.assertEqual((providers["claude"]["records"], providers["claude"]["unpricedRecords"]), (1, 1))
        self.assertEqual(providers["grok"]["name"], "Grok")
        self.assertAlmostEqual(payload["totals"]["costUsd"], 0.003)
        self.assertEqual(payload["period"]["resolution"], "hour")
        self.assertEqual(sum(row["records"] for row in payload["periods"]), 3)

    def test_page_ceiling_marks_past_day_partial(self):
        self.server.items = [{"id": i, "event_at_ms": NOW - 1000 - i, "provider": "openai", "actual_model": "gpt-test",
                              "tokens": {}, "estimated_cost_nanos": 1} for i in range(10)]
        with mock.patch.object(fusebox, "PAGE_SIZE", 2), mock.patch.object(fusebox, "MAX_PAGES", 3):
            sources = self.sources(self.build(days=1))
        self.assertEqual(sources["fusebox-codex"]["status"], "partial")
        self.assertIn("oldest are not shown", sources["fusebox-codex"]["message"])

    def test_redirects_oversized_and_invalid_inputs_fail_closed(self):
        for mode, phrase in (("redirect", "HTTP 302"), ("large", "unexpectedly large")):
            with self.subTest(mode=mode):
                self.server.mode = mode
                sources = self.sources(costs.build_payload(
                    ["claude"], 7, 5, self.root / ("state-" + mode), now_ms=NOW, zone_name="UTC",
                    rates_override=RATES, fusebox={"url": self.server.url, "keyFile": str(self.key), "overlap": "fusebox"}))
                self.assertIn(phrase, sources["fusebox"]["message"])
                self.assertTrue(sources["local-claude"]["included"])
        self.assertTrue(all(path.startswith("/api/usage/") for path, _, _ in self.server.requests))
        with self.assertRaises(fusebox.FuseboxError):
            fusebox.normalize_url("https://user:secret@example.com")
        self.assertEqual(fusebox.normalize_url("https://Fusebox.example/prefix/management.html"),
                         "https://fusebox.example/prefix")
        os.chmod(self.key, 0o644)
        summary, state, error = fusebox.collect({"url": self.server.url, "keyFile": str(self.key)},
                                                7, NOW - 86400000, NOW, "UTC", timezone.utc, self.root, 5)
        self.assertEqual((summary, state), (None, "unavailable"))
        self.assertIn("private (0600)", error)
        with self.assertRaises(ValueError):
            costs.build_payload(["claude"], 7, 5, self.root, now_ms=NOW, rates_override=RATES,
                                fusebox={"url": self.server.url, "keyFile": str(self.key), "overlap": "both"})

    def test_custom_prices_still_override_fusebox_estimates(self):
        overrides = json.dumps({"gpt-test": {"inputCostPerMillionTokens": 1, "outputCostPerMillionTokens": 1}})
        payload = self.build(price_overrides=overrides)
        codex = {p["id"]: p for p in payload["providers"]}["codex"]
        self.assertEqual(codex["costSource"], "customPriced")
        self.assertAlmostEqual(codex["costUsd"], (1000 + 200 + 30 + 400) / 1_000_000)  # Cache rates default to input.

    def test_cli_passes_fusebox_options_and_never_prints_the_key(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output), mock.patch.object(costs, "load_rates", return_value=RATES):
            costs.main(["--days", "7", "--state-dir", str(self.root / "cli"), "--time-zone", "UTC",
                        "--fusebox-url", self.server.url, "--fusebox-key-file", str(self.key),
                        "--fusebox-overlap", "transcripts"])
        payload = json.loads(output.getvalue())
        self.assertNotIn("backendError", payload)
        self.assertEqual(self.sources(payload)["fusebox-claude"]["status"], "excluded")
        self.assertNotIn(KEY, output.getvalue())


if __name__ == "__main__":
    unittest.main()
