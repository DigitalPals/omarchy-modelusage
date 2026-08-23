from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import time
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("--providers", default="claude,codex,kimi")
parser.add_argument("--timeout")
parser.add_argument("--state-dir")
args = parser.parse_args()

# A singleton-backend instance in the QML contract deliberately gets bad
# output so the UI boundary is exercised independently from the rich panel.
if args.providers == "kimi":
    print('["malformed backend response"]')
    raise SystemExit(0)

payload = json.loads(Path(os.environ["MODEL_USAGE_NORMALIZED_FIXTURE"]).read_text())
now = int(time.time())
payload["generatedAt"] = dt.datetime.now(dt.timezone.utc).isoformat()
for provider in payload["providers"]:
    provider["fetchedAt"] = payload["generatedAt"]
    for index, window in enumerate(provider["windows"]):
        label = str(window.get("label", "")).lower()
        if "5 hour" in label or "five-hour" in label:
            reset_offset = 2 * 3600
        elif "weekly" in label:
            reset_offset = 3 * 86400 + 4 * 3600
        elif "1 day" in label:
            reset_offset = 18 * 3600
        else:
            reset_offset = (index + 2) * 86400
        window["resetsAt"] = now + reset_offset
selected = {value for value in args.providers.split(",") if value}
payload["providers"] = [row for row in payload["providers"] if row["id"] in selected]
print(json.dumps(payload, separators=(",", ":")))
