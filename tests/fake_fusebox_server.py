"""Local synthetic Fusebox management API for the settings QML contract.

Serves the Rust account fixture to one key and rejects every other request,
including the CLIProxyAPI path, as Fusebox does. Writes its base URL to the
file named on the command line, then serves until terminated.
"""
from __future__ import annotations

import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

KEY = "synthetic-fusebox-key"
ACCOUNTS = json.loads((Path(__file__).with_name("fixtures") / "cliproxy-rust-accounts.json").read_text())


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + KEY:
            status, payload = 401, {"error": "unauthorized"}
        elif self.path == "/api/accounts":
            status, payload = 200, ACCOUNTS
        else:
            status, payload = 404, {}
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    Path(sys.argv[1]).write_text(f"http://127.0.0.1:{server.server_port}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
