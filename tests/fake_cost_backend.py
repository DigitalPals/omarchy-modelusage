from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--providers", default="claude,codex,kimi")
parser.add_argument("--days")
parser.add_argument("--timeout")
parser.add_argument("--state-dir")
parser.add_argument("--price-overrides", default="{}")
parser.add_argument("--refresh-prices", action="store_true")
parser.add_argument("--t3-servers", default="[]")
args = parser.parse_args()

if args.providers == "" and args.t3_servers == "[]":
    print('["malformed cost response"]')
    raise SystemExit(0)

payload = json.loads(Path(os.environ["MODEL_USAGE_COST_FIXTURE"]).read_text())
payload["source"] = "transcripts"
payload["testRequest"] = {"force": args.refresh_prices, "prices": args.price_overrides,
                          "servers": args.t3_servers, "providers": args.providers}
if args.t3_servers != "[]":
    time.sleep(0.15)
if (args.providers == "codex" and args.t3_servers == "[]") or args.price_overrides == "synthetic-failure":
    payload["backendError"] = "Synthetic estimated-cost failure"
    payload["providers"] = []
    payload["models"] = []
    payload["periods"] = []
    print(json.dumps(payload, separators=(",", ":")))
    raise SystemExit(0)

selected = {value for value in args.providers.split(",") if value}
payload["providers"] = [row for row in payload["providers"] if row["id"] in selected]
payload["coverage"] = [row for row in payload["coverage"] if row["id"] in selected]
for period in payload["periods"]:
    period["providers"] = [row for row in period["providers"] if row["id"] in selected]
print(json.dumps(payload, separators=(",", ":")))
