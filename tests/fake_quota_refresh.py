"""Synthetic quota process for startup/connection-change runtime checks."""
import argparse
import datetime
import json
import os
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--providers")
parser.add_argument("--source")
parser.add_argument("--timeout")
parser.add_argument("--cliproxy-url")
parser.add_argument("--cliproxy-key-file")
args = parser.parse_args()
with Path(os.environ["MODEL_USAGE_QUOTA_REQUESTS"]).open("a") as stream:
    stream.write(json.dumps(vars(args)) + "\n")
time.sleep(0.15)
print(json.dumps({"schemaVersion": 1, "source": args.source,
    "generatedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "providers": [{"id": "codex", "status": "ok", "windows": []}],
    "testRequest": vars(args)}))
