from __future__ import annotations

import copy
import json
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock
from urllib.parse import parse_qs, urlsplit

from test_cost_backend import costs
import keeper_costs as keeper


EVENT = {
    "id": "12345", "timestamp": "2030-01-15T12:00:00Z", "source_type": "codex",
    "model": "gpt-example", "input_tokens": 2000, "cache_read_tokens": 1500,
    "cache_creation_tokens": 100, "output_tokens": 512, "reasoning_tokens": 64,
    "total_tokens": 2512, "cost_usd": 999, "api_key": "secret-client-key",
    "source": "private@example.invalid", "client_ip": "192.0.2.1", "result": "success",
}
STAMP = costs.parse_timestamp_ms(EVENT["timestamp"])


class KeeperTests(unittest.TestCase):
    def test_canonical_tokens_and_sanitization(self):
        record = keeper.normalize_event(EVENT, "server")
        self.assertEqual(record["uncached_input"], 400)
        self.assertEqual(record["output"], 512)
        self.assertEqual(record["reasoning"], 64)
        self.assertIsNone(record["reported_cost_usd"])
        self.assertEqual(record["session_id"], "")
        encoded = json.dumps(record)
        for secret in ("secret-client-key", "private@example.invalid", "192.0.2.1", '"12345"'):
            self.assertNotIn(secret, encoded)
        other = keeper.normalize_event(EVENT, "other-server")
        self.assertNotEqual(record["dedupe_key"], other["dedupe_key"])
        nano = keeper.normalize_event({**EVENT, "timestamp": "2030-01-15T13:00:00.123456789+01:00"}, "server")
        self.assertEqual(nano["timestamp_ms"], STAMP + 123)

    def test_rejects_inconsistent_missing_negative_and_oversized_tokens(self):
        for changes in ({"input_tokens": 1}, {"reasoning_tokens": 900}, {"total_tokens": 123},
                        {"output_tokens": -1}, {"output_tokens": True}, {"model": "x" * 257},
                        {"total_tokens": 10**18}, {"timestamp": "2030-01-15T12:00:00"}):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                keeper.normalize_event({**EVENT, **changes}, "server")

    def test_private_password_and_url_validation(self):
        self.assertEqual(keeper.normalize_url("https://example.com/keeper/api/v1/"), "https://example.com/keeper")
        for url in ("", "file:///tmp/key", "https://user:secret@example.com", "https://example.com/?key=secret",
                    "https://example.com/../other", "https://example.com/%2e%2e/other"):
            with self.assertRaises(keeper.KeeperError):
                keeper.normalize_url(url)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "password"
            path.write_text("synthetic-password\n")
            path.chmod(0o600)
            self.assertEqual(keeper.read_password(path), "synthetic-password")
            link = Path(tmp) / "link"
            link.symlink_to(path)
            with self.assertRaises(keeper.KeeperError):
                keeper.read_password(link)
            path.chmod(0o644)
            with self.assertRaises(keeper.KeeperError):
                keeper.read_password(path)


class KeeperHTTPTests(unittest.TestCase):
    def setUp(self):
        self.requests = []
        self.events = [copy.deepcopy(EVENT)]
        self.status = {"running": True, "timezone": "Europe/Amsterdam"}
        self.mode = "ok"
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                owner.requests.append((self.path, body))
                if self.headers.get("X-CPA-Usage-Keeper-Request") != "fetch":
                    self.send_error(403)
                    return
                if self.path.endswith("/auth/login"):
                    if body.get("password") != "test-password":
                        self.send_error(401)
                        return
                    self.send_response(200)
                    self.send_header("Set-Cookie", "cpa_usage_keeper_session=synthetic; Path=/keeper")
                    self.end_headers()
                    self.wfile.write(b'{}')
                else:
                    self.send_response(204)
                    self.end_headers()

            def do_GET(self):
                owner.requests.append((self.path, self.headers.get("Cookie")))
                if self.headers.get("Cookie") != "cpa_usage_keeper_session=synthetic":
                    self.send_error(401)
                    return
                if self.path == "/keeper/api/v1/status":
                    body = owner.status
                elif self.path.startswith("/keeper/api/v1/usage/events/export?"):
                    if owner.mode == "redirect":
                        self.send_response(302)
                        self.send_header("Location", "/stolen")
                        self.end_headers()
                        return
                    body = {"events": owner.events, "total_count": len(owner.events)}
                    if owner.mode == "incomplete":
                        body["total_count"] += 1
                else:
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps(body).encode())

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.temp = tempfile.TemporaryDirectory()
        self.password = Path(self.temp.name) / "password"
        self.password.write_text("test-password\n")
        self.password.chmod(0o600)
        self.url = f"http://127.0.0.1:{self.server.server_port}/keeper"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def collect(self):
        return keeper.collect(self.url, self.password, 5, STAMP - 86400000, STAMP)

    def test_authenticated_export_dedupes_and_logs_out_without_consuming_queue(self):
        self.events.append(copy.deepcopy(EVENT))
        records, history = self.collect()
        self.assertEqual(len(records), 1)
        self.assertEqual(history["status"], "partial")
        self.assertTrue(history["collectorHealthy"])
        paths = [r[0] for r in self.requests]
        self.assertTrue(paths[-1].endswith("/auth/logout"))
        self.assertFalse(any("usage-queue" in p for p in paths))
        query = parse_qs(urlsplit(paths[2]).query)
        self.assertEqual(query["unit"], ["day"])
        self.assertEqual(query["start"], ["2030-01-14"])
        self.assertEqual(query["end"], ["2030-01-15"])

    def test_collector_failure_and_invalid_records_are_explicit_partial_coverage(self):
        self.status["last_error"] = "upstream error with api_key=secret"
        self.events.append({**EVENT, "id": "bad", "input_tokens": -10})
        records, history = self.collect()
        self.assertEqual(len(records), 1)
        self.assertEqual(history["status"], "partial")
        self.assertEqual(history["skippedRecords"], 1)
        self.assertNotIn("secret", json.dumps(history))

    def test_incomplete_redirected_or_over_limit_exports_fail_atomically(self):
        for mode in ("incomplete", "redirect"):
            self.mode = mode
            with self.subTest(mode=mode), self.assertRaises(keeper.KeeperError):
                self.collect()
        self.assertFalse(any(p == "/stolen" for p, _ in self.requests))
        self.mode = "ok"
        with mock.patch.object(keeper, "MAX_EVENTS", 0), self.assertRaises(keeper.KeeperError):
            self.collect()

    def test_costs_use_custom_prices_canonical_tokens_and_dynamic_providers(self):
        self.events.append({**EVENT, "id": "23456", "source_type": "kimi", "model": "kimi-known"})
        prices = json.dumps({model: {"inputCostPerMillionTokens": 2, "outputCostPerMillionTokens": 8,
                                   "cacheReadCostPerMillionTokens": 0.5, "cacheWriteCostPerMillionTokens": 3}
                             for model in ("gpt-example", "kimi-known")})
        with mock.patch.object(costs, "scan_transcripts", side_effect=AssertionError("must not read local transcripts")):
            payload = costs.build_payload([], 30, 5, Path(self.temp.name), now_ms=STAMP,
                                          source="keeper", keeper_url=self.url,
                                          keeper_password_file=self.password, price_overrides=prices)
        self.assertAlmostEqual(payload["totals"]["costUsd"], 0.005946 * 2)
        self.assertEqual(payload["totals"]["totalTokens"], 2512 * 2)
        self.assertEqual(payload["totals"]["reasoningTokens"], 128)
        self.assertEqual(payload["totals"]["customPricedRecords"], 2)
        self.assertEqual(payload["totals"]["sessions"], 0)
        self.assertEqual(len(payload["periods"]), 30)
        self.assertEqual(payload["source"], "keeper")
        self.assertNotIn("secret-client-key", json.dumps(payload))

    def test_empty_archive_and_unknown_model_are_distinct(self):
        self.events.clear()
        records, history = self.collect()
        self.assertEqual(records, [])
        self.assertIsNone(history["firstRecordAt"])
        self.events.append({**EVENT, "source_type": "new-provider"})
        payload = costs.build_payload([], 1, 5, Path(self.temp.name), now_ms=STAMP,
                                      source="keeper", keeper_url=self.url, keeper_password_file=self.password,
                                      rates_override=({}, {"status": "unavailable"}))
        self.assertIsNone(payload["totals"]["costUsd"])
        self.assertEqual(payload["totals"]["totalTokens"], 2512)
        self.assertEqual(payload["providers"][0]["id"], "new-provider")

    def test_empty_unhealthy_archive_is_not_a_zero_cost_reading(self):
        self.events.clear()
        self.status["running"] = False
        with self.assertRaises(keeper.KeeperError):
            self.collect()


if __name__ == "__main__":
    unittest.main()
