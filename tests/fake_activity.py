import argparse
import json
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--cliproxy-url")
parser.add_argument("--cliproxy-key-file")
parser.add_argument("--keeper-url")
parser.add_argument("--keeper-password-file")
parser.add_argument("--timeout")
args = parser.parse_args()
if args.keeper_url.endswith("/old"):
    time.sleep(0.3)
if args.keeper_url.endswith("/oversized"):
    print("x" * 70000)
else:
    marker = Path(args.keeper_password_file) if args.keeper_password_file else None
    failed = bool(marker and marker.exists())
    if marker:
        marker.touch()
    print(json.dumps({"schemaVersion": 1, "error": "Synthetic outage" if failed else "", "providers": [] if failed else [
        {"id": "codex", "status": "ok", "accountId": "old" if args.keeper_url.endswith("/old") else "new", "lastUsedAt": 123}
    ]}))
