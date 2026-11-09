from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from test_backend import ROOT
import fusebox_costs
import keeper_client
import proxy_connection as connection
from model_usage_common import ProviderFailure
from test_cliproxy import proxy_server as go_server
from test_cliproxy_rust import proxy_server as fusebox_server

PROBE = ROOT / "scripts" / "proxy-test.py"


def probe(request: dict) -> tuple[dict, str]:
    process = subprocess.run([sys.executable, "-B", str(PROBE)], input=json.dumps(request) + "\n",
                             capture_output=True, text=True, timeout=20, check=True)
    return json.loads(process.stdout), process.stdout + process.stderr


def private_file(directory: str, text: str) -> Path:
    path = Path(directory) / "secret.key"
    path.write_text(text)
    path.chmod(0o600)
    return path


class SharedConnectionTests(unittest.TestCase):
    def test_every_backend_normalizes_urls_alike(self):
        for address in ("https://Proxy.test/prefix/management.html", "https://Proxy.test/prefix/v0/management/"):
            self.assertEqual(connection.server_url(address), "https://Proxy.test/prefix")
            self.assertEqual(fusebox_costs.normalize_url(address), "https://proxy.test/prefix")
        self.assertEqual(keeper_client.normalize_url("https://keeper.test/k/api/v1/"), "https://keeper.test/k")
        for address in ("ftp://proxy.test", "https://user:pass@proxy.test", "https://proxy.test/?q=1",
                        "https://proxy.test/a/../b", "https://proxy.test\n", 42):
            with self.subTest(address=address):
                with self.assertRaises(ProviderFailure):
                    connection.server_url(address)
                with self.assertRaises(fusebox_costs.FuseboxError):
                    fusebox_costs.normalize_url(address)

    def test_saved_keys_with_spaces_work_for_limits_and_costs(self):
        # management-key.py saves any printable ASCII; every reader must accept it.
        with tempfile.TemporaryDirectory() as directory:
            path = private_file(directory, "key with spaces\n")
            self.assertEqual(connection.read_key(path), "key with spaces")
            self.assertEqual(fusebox_costs.read_key(str(path)), "key with spaces")
            path.write_text("café\n")
            with self.assertRaises(ProviderFailure):
                connection.read_key(path)
            with self.assertRaises(fusebox_costs.FuseboxError):
                fusebox_costs.read_key(str(path))
            self.assertEqual(keeper_client.read_password(path), "café")

    def test_empty_key_paths_use_the_shared_default(self):
        with tempfile.TemporaryDirectory() as directory:
            path = private_file(directory, "default-key")
            with mock.patch.dict(os.environ, {"CLIPROXY_API_KEY_FILE": str(path)}):
                self.assertEqual(connection.key_path(""), path)
                self.assertEqual(connection.read_key(""), "default-key")
                self.assertEqual(fusebox_costs.read_key(""), "default-key")
            with mock.patch.dict(os.environ, {"CLIPROXY_API_KEY_FILE": str(Path(directory) / "missing")}):
                with self.assertRaises(fusebox_costs.FuseboxError) as error:
                    fusebox_costs.read_key("")
                self.assertIn("Enter it in Limits or Costs settings", str(error.exception))

    def test_legacy_flag_names_remain_accepted(self):
        import argparse
        for flags in (["--proxy-url", "https://a.test", "--proxy-key-file", "/k"],
                      ["--cliproxy-url", "https://a.test", "--cliproxy-key-file", "/k"]):
            parser = argparse.ArgumentParser()
            connection.add_arguments(parser)
            args = parser.parse_args([*flags, "--implementation", "rust"])
            self.assertEqual((args.proxy_url, args.proxy_key_file, args.implementation), ("https://a.test", "/k", "rust"))


class ConnectionProbeTests(unittest.TestCase):
    def test_fusebox_draft_key_is_tested_without_being_printed(self):
        with fusebox_server() as (url, requests):
            result, output = probe({"url": url + "/management.html", "key": "test-management-key"})
        self.assertTrue(result["ok"])
        self.assertEqual(result["implementation"], "rust")
        self.assertEqual(result["accounts"], 4)
        self.assertRegex(result["message"], r"^Connected to Fusebox · 4 accounts across \d+ providers\.$")
        self.assertEqual(requests, [("GET", "/api/accounts")])
        self.assertNotIn("test-management-key", output)

    def test_saved_key_file_and_go_detection(self):
        with tempfile.TemporaryDirectory() as directory, go_server() as (url, calls):
            path = private_file(directory, "private-management-key")
            result, output = probe({"url": url, "keyFile": str(path)})
            self.assertTrue(result["ok"])
            self.assertEqual(result["implementation"], "go")
            self.assertIn("Connected to CLIProxyAPI", result["message"])
            costs, _ = probe({"url": url, "keyFile": str(path), "requireFusebox": True})
            self.assertFalse(costs["ok"])
            self.assertEqual(costs["implementation"], "go")
            self.assertIn("Costs needs Fusebox", costs["message"])
            self.assertNotIn("private-management-key", output)

    def test_failures_are_explained_safely(self):
        with fusebox_server() as (url, requests):
            wrong, output = probe({"url": url, "key": "wrong-secret-key"})
        self.assertFalse(wrong["ok"])
        self.assertIn("rejected the management key", wrong["message"])
        self.assertNotIn("wrong-secret-key", output)
        for request, text in (({}, "Enter the server URL"),
                              ({"url": "https://user:secret@proxy.test", "key": "k"}, "Proxy URL must be"),
                              ({"url": "https://proxy.test", "key": "badé"}, "ASCII"),
                              ({"url": "http://127.0.0.1:9", "key": "k"}, "Could not reach")):
            with self.subTest(request=request):
                result, output = probe(request)
                self.assertFalse(result["ok"])
                self.assertIn(text, result["message"])
                self.assertNotIn("secret", output)


if __name__ == "__main__":
    unittest.main()
