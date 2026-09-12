#!/usr/bin/env python3
"""Synthetic reset process for offscreen QML tests; never makes network calls."""
import argparse
import json
import os
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--action")
parser.add_argument("--account-id")
parser.add_argument("--cliproxy-url")
parser.add_argument("--cliproxy-key-file")
parser.add_argument("--target")
parser.add_argument("--credit-id")
parser.add_argument("--request-id")
args = parser.parse_args()
time.sleep(0.05)
log = Path(os.environ["MODEL_USAGE_RESET_LOG"])
if args.action == "prepare":
    result = {"ok": True, "availableCount": 2, "target": "target", "requestId": "fixed-request",
              "credits": [{"id": "first", "title": "Full reset", "description": "Current usage limits",
                           "expiresAt": 2208988800},
                          {"id": "second", "title": "Another reset", "description": "Current usage limits",
                           "expiresAt": None}]}
else:
    lines = log.read_text().splitlines() if log.exists() else []
    with log.open("a") as output:
        output.write(json.dumps(vars(args)) + "\n")
    result = {"ok": False, "uncertain": True} if not lines else {"ok": True, "outcome": "already_redeemed"}
print(json.dumps(dict(result, schemaVersion=1)))
