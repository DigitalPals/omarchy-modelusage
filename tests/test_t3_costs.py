from __future__ import annotations

import base64
import contextlib
import copy
import hashlib
import json
import socket
import struct
import tempfile
import threading
import time
import unittest
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest import mock
from urllib.parse import parse_qs

from test_cost_backend import costs
import t3_costs as t3

STAMP = int(time.time() * 1000)
DAY = datetime.fromtimestamp(STAMP / 1000, timezone.utc).date().isoformat()
QUERY = {"sinceDay": DAY, "untilDay": DAY, "timeZone": "UTC", "resolution": "day"}


def summary(query=QUERY):
    return {"contractVersion": 5, "readAt": costs.iso_timestamp(STAMP / 1000), **query,
        "sources": [{"fingerprint": {"hostId": "private-host", "provider": "codex",
                     "resolvedHomePath": "/private/home/sessions", "volumeId": "3:42"},
                     "status": "ok", "distinctSessions": 2}],
        "buckets": [{"provider": "codex", "day": DAY, "model": "test-model", "records": 5,
            "totals": {"uncachedInputTokens": 100, "cachedInputTokens": 200,
                       "cacheCreationTokens": 10, "outputTokens": 30, "reasoningTokens": 20}}]}


class WireTests(unittest.TestCase):
    def setUp(self):
        self.mode = "ok"
        self.requests = []
        self.exchanges = []
        self.pongs = []
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_POST(self):
                owner.exchanges.append((self.path, parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())))
                body = json.dumps({"access_token": "synthetic-access", "token_type": "Bearer"}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                auth = self.headers.get("Authorization")
                owner.requests.append((self.path, auth))
                if owner.mode == "unavailable":
                    self.send_error(503)
                    return
                if owner.mode == "redirect":
                    self.send_response(302)
                    self.send_header("Location", "http://example.invalid")
                    self.end_headers()
                    return
                if owner.mode == "auth" and auth != "Bearer synthetic-access":
                    self.send_error(401)
                    return
                key = self.headers["Sec-WebSocket-Key"]
                accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                self.send_response(101)
                self.send_header("Upgrade", "websocket")
                self.send_header("Connection", "Upgrade")
                self.send_header("Sec-WebSocket-Accept", "wrong" if owner.mode == "bad-upgrade" else accept)
                self.end_headers()
                if owner.mode == "bad-upgrade":
                    return

                def receive():
                    a, b = self.rfile.read(2)
                    size = b & 127
                    if size == 126:
                        size = struct.unpack("!H", self.rfile.read(2))[0]
                    assert b & 128, "native WebSocket client must mask frames"
                    mask = self.rfile.read(4)
                    body = self.rfile.read(size)
                    return a & 15, bytes(x ^ mask[i % 4] for i, x in enumerate(body))

                def send(op, body, final=True):
                    header = bytes([(128 if final else 0) | op])
                    header += bytes([len(body)]) if len(body) < 126 else b'\x7e' + struct.pack("!H", len(body))
                    self.wfile.write(header + body)
                    self.wfile.flush()

                _, request = receive()
                request = json.loads(request)
                owner.rpc_request = request
                if owner.mode == "oversized":
                    self.wfile.write(b'\x81\x7f' + struct.pack("!Q", t3.MAX_BYTES + 1))
                    return
                if owner.mode == "invalid":
                    send(1, b'[]')
                    return
                document = summary(request["payload"])
                result = json.dumps({"_tag": "Exit", "requestId": request["id"],
                                     "exit": {"_tag": "Success", "value": document}}).encode()
                send(1, result[:30], False)
                send(9, b'ping')
                owner.pongs.append(receive())
                send(0, result[30:])

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.tmp = tempfile.TemporaryDirectory()
        self.state = Path(self.tmp.name)
        self.config = {"id": "t3", "name": "Remote", "url": f"http://127.0.0.1:{self.server.server_port}/base",
                       "tokenFile": "", "enabled": True}

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.tmp.cleanup()

    def collect(self, **changes):
        return t3.collect({**self.config, **changes}, QUERY, 30, self.state, 2)

    def test_real_websocket_rpc_fragmentation_and_ping(self):
        result, status, error = self.collect()
        self.assertEqual((status, error), ("fresh", ""))
        self.assertEqual(result["buckets"][0]["records"], 5)
        self.assertEqual(self.rpc_request, {"_tag": "Request", "id": "0", "tag": "server.getUsageSummary", "payload": QUERY, "headers": []})
        self.assertEqual(self.requests, [("/base/ws", None)])
        self.assertEqual(self.pongs, [(10, b'ping')])
        snapshot = next(self.state.glob("t3-usage-*.json"))
        self.assertEqual(snapshot.stat().st_mode & 0o777, 0o600)
        for private in ("private-host", "/private/home", "3:42"):
            self.assertNotIn(private, snapshot.read_text())

    def test_token_exchange_cached_access_and_offline_snapshot(self):
        self.mode = "auth"
        token = self.state / "connection.key"
        token.write_text("synthetic-bootstrap")
        token.chmod(0o600)
        result, state, _ = self.collect(tokenFile=str(token))
        self.assertEqual(state, "fresh")
        self.assertEqual(self.exchanges[0][0], "/base/oauth/token")
        self.assertEqual(self.exchanges[0][1]["subject_token"], ["synthetic-bootstrap"])
        self.assertEqual(self.exchanges[0][1]["scope"], ["orchestration:read"])
        self.collect(tokenFile=str(token))
        self.assertEqual(len(self.exchanges), 1)
        self.mode = "unavailable"
        cached, status, error = self.collect(tokenFile=str(token))
        self.assertEqual(status, "stale")
        self.assertEqual(cached, result)
        self.assertTrue(error)
        # Different credential, URL or period must not reuse another source's snapshot.
        self.assertEqual(self.collect()[1], "unavailable")
        self.assertEqual(self.collect(url=self.config["url"] + "/other", tokenFile=str(token))[1], "unavailable")
        self.assertEqual(t3.collect({**self.config, "tokenFile": str(token)}, QUERY, 7, self.state, 2)[1], "unavailable")

    def test_bad_frames_and_redirects_produce_safe_unavailable_status(self):
        for mode in ("redirect", "invalid", "oversized", "bad-upgrade"):
            self.mode = mode
            with self.subTest(mode=mode):
                value, status, error = self.collect()
                self.assertIsNone(value)
                self.assertEqual(status, "unavailable")
                self.assertTrue(error)
                self.assertNotIn(self.config["url"], error)


class ValidationTests(unittest.TestCase):
    def test_invalid_contract_counter_zone_and_duplicate_bucket(self):
        valid = summary()
        self.assertTrue(t3.normalize_summary(valid, QUERY))
        variants = []
        for version in (3, 6, True, 5.0):
            variants.append({**valid, "contractVersion": version})
        variants.append({**valid, "timeZone": "Europe/Amsterdam"})
        variants.append({**valid, "buckets": valid["buckets"] * 2})
        for key, value in (("cachedInputTokens", -1), ("outputTokens", True), ("reasoningTokens", 40)):
            changed = copy.deepcopy(valid)
            changed["buckets"][0]["totals"][key] = value
            variants.append(changed)
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(t3.T3Error):
                t3.normalize_summary(variant, QUERY)

    def test_private_token_and_invalid_server_configuration(self):
        for url in ("https://u:secret@example.com", "https://example.com?token=x", "file:///tmp", "https://example.com/%2e%2e/foo"):
            with self.assertRaises(t3.T3Error):
                t3.normalize_url(url)
        with self.assertRaises(t3.T3Error):
            t3.parse_servers('[{"id":"x","name":"X","url":"https://example.com","token":"secret"}]')
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            path.write_text("synthetic")
            path.chmod(0o600)
            self.assertEqual(t3.read_token(str(path)), "synthetic")
            link = Path(directory) / "link"
            link.symlink_to(path)
            with self.assertRaises(t3.T3Error):
                t3.read_token(str(link))
            path.chmod(0o644)
            with self.assertRaises(t3.T3Error):
                t3.read_token(str(path))

    def test_hourly_boundaries_and_unsupported_provider(self):
        query = {**QUERY, "resolution": "hour", "sinceTime": costs.iso_timestamp((STAMP - 3600000) / 1000), "untilTime": costs.iso_timestamp(STAMP / 1000)}
        doc = summary(query)
        doc["buckets"][0]["hourStart"] = query["sinceTime"]
        self.assertTrue(t3.normalize_summary(doc, query))
        doc["buckets"][0]["hourStart"] = query["untilTime"]
        with self.assertRaises(t3.T3Error):
            t3.normalize_summary(doc, query)
        doc = summary()
        doc["sources"][0]["fingerprint"]["provider"] = "grok"
        doc["buckets"][0]["provider"] = "grok"
        self.assertEqual(t3.normalize_summary(doc, QUERY)["sources"], [])


class CombinedTests(unittest.TestCase):
    def setUp(self):
        self.contexts = contextlib.ExitStack()
        self.addCleanup(self.contexts.close)

    def build(self, local_status="ok", duplicate=False, state="fresh", missing_first=False):
        directory = self.contexts.enter_context(tempfile.TemporaryDirectory())
        root = Path(directory)
        info = root.stat()
        fp = t3.fingerprint(socket.gethostname(), "codex", str(root.resolve()), f"{info.st_dev}:{info.st_ino}")
        remote = t3.normalize_summary(summary(), QUERY)
        if duplicate:
            remote["sources"][0]["fingerprint"] = fp
        record = costs.UsageRecord(provider="codex", timestamp_ms=STAMP - 1000, model="test-model",
            session_id="local-session", uncached_input=1, cached_input=2, cache_creation=0,
            output=3, reasoning=1, reported_cost_usd=999, dedupe_key="local-record")
        self.contexts.enter_context(mock.patch.object(costs, "scan_transcripts", return_value=([record] if local_status == "ok" else [],
            [{"id": "codex", "status": local_status, "message": ""}])))
        self.contexts.enter_context(mock.patch.object(costs, "transcript_root", return_value=root))
        if missing_first:
            missing = copy.deepcopy(remote)
            missing["sources"][0]["status"] = "missing"
            missing["buckets"] = []
            self.contexts.enter_context(mock.patch.object(t3, "collect", side_effect=[(missing, "fresh", ""), (remote, state, "offline")]))
        else:
            self.contexts.enter_context(mock.patch.object(t3, "collect", return_value=(remote, state, "offline")))
        servers = [{"id": "remote", "name": "Remote", "url": "https://example.com"}]
        if missing_first:
            servers.append({"id": "second", "name": "Second", "url": "https://second.example.com"})
        return costs.build_payload(["codex"], 30, 2, root, now_ms=STAMP, zone_name="UTC",
            rates_override=({"test-model": (1e-6, 2e-6, .5e-6, 1e-6)}, {"status": "fresh"}), t3_servers=json.dumps(servers))

    def test_weighted_remote_records_tokens_prices_and_sessions(self):
        result = self.build()
        totals = result["totals"]
        self.assertEqual(totals["records"], 6)
        self.assertEqual(totals["remoteRecords"], 5)
        self.assertEqual(totals["totalTokens"], 346)
        self.assertEqual(totals["sessions"], 3)
        self.assertAlmostEqual(totals["costUsd"], .000278)
        self.assertIsNone(result["models"][0]["sessions"])

    def test_local_remote_overlap_is_counted_once(self):
        result = self.build(duplicate=True)
        self.assertEqual(result["totals"]["records"], 1)
        self.assertEqual([s["status"] for s in result["sources"]], ["ok", "duplicate"])

    def test_failed_local_does_not_suppress_remote(self):
        result = self.build(local_status="failed", duplicate=True)
        self.assertEqual(result["totals"]["records"], 5)
        self.assertEqual(result["totals"]["sessions"], 2)

    def test_missing_remote_does_not_suppress_healthy_duplicate(self):
        result = self.build(local_status="missing", missing_first=True)
        self.assertEqual(result["totals"]["records"], 5)
        self.assertTrue(any(s["included"] and s["id"].startswith("second") for s in result["sources"]))

    def test_stale_history_is_included_with_unknown_session_count(self):
        result = self.build(state="stale")
        self.assertEqual(result["totals"]["records"], 6)
        self.assertIsNone(result["totals"]["sessions"])
        self.assertTrue(any(s["status"] == "stale" and s["updatedAt"] == STAMP for s in result["sources"]))
