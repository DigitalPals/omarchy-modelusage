# Estimated-cost contract

`scripts/cost-fetch.py` writes an independent schema-v1 JSON document to standard output. `CostBackend.qml` requests it only after the Costs tab is opened and keeps the last known-good document when a later process, timeout, or schema error occurs.

The dollar fields are API-equivalent estimates, not subscription charges. Nullable `costUsd` and `cacheSavingsUsd` distinguish unknown pricing from a real zero. Empty periods use `0`; periods containing only unpriced activity use `null`.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2030-01-15T12:00:00Z",
  "pricing": {
    "status": "fresh",
    "source": "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json",
    "fetchedAt": "2030-01-15T12:00:00Z",
    "knownModels": 900,
    "message": ""
  },
  "coverage": [
    {
      "id": "kimi",
      "name": "Kimi Code",
      "status": "partial",
      "message": "Kimi records tokens but not reliable historical model names; cost is unavailable.",
      "scannedFiles": 2,
      "skippedFiles": 0,
      "sessions": 1
    }
  ],
  "scanDurationMs": 37,
  "period": {
    "days": 7,
    "resolution": "day",
    "since": "2030-01-09",
    "until": "2030-01-15",
    "label": "Past 7 days"
  },
  "totals": {
    "costUsd": 12.34,
    "cacheSavingsUsd": 21.5,
    "uncachedInputTokens": 850000,
    "cachedInputTokens": 4200000,
    "cacheCreationTokens": 120000,
    "outputTokens": 330000,
    "reasoningTokens": 70000,
    "totalTokens": 5500000,
    "records": 42,
    "pricedRecords": 38,
    "unpricedRecords": 4,
    "sessions": 6,
    "costSource": "mixed"
  },
  "providers": [],
  "models": [],
  "periods": []
}
```

`providers` contains the same metrics as `totals`, identity fields, and the matching coverage `status`/`message`. `models` contains the metrics plus provider/model identity. `periods` contains one filled bucket for each hour in the rolling 24-hour view or each calendar day in the 7/30-day views. Every period also has a `providers` array for the stacked chart.

Pricing statuses are `fresh`, `cached`, `unavailable`, or `notNeeded`. Coverage statuses are `ok`, `partial`, `missing`, or `failed`; unreadable files make coverage `partial` or `failed` rather than silently producing a complete-looking total. `scannedFiles` counts readable recent transcript files, including files with no usage-bearing rows, while `skippedFiles` counts files or directories that could not be inspected. `costSource` is `none`, `providerReported`, `modelPriced`, `mixed`, or `unpriced`. Token totals always include unpriced records from readable files. `reasoningTokens` is informational and is already included in `outputTokens`; it must not be summed again.

## Local sources and privacy

- Claude: `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/**/*.jsonl`
- Codex: `${CODEX_HOME:-~/.codex}/sessions/**/*.jsonl`
- Kimi: `${KIMI_SHARE_DIR:-~/.kimi}/sessions/**/wire.jsonl`

Files are streamed line by line. Only usage-bearing records are parsed. The durable size/mtime cache stores token metadata and hashes every transcript path, session identifier, message identifier, and deduplication key with SHA-256. Prompts, responses, tool calls, tool results, and credentials are neither cached nor returned.

The state directory uses mode `0700` and cache files use `0600`. Corrupt or foreign cache versions cause a cold rebuild, never a broken view. Rate refresh failures fall back to the last cached LiteLLM table; with no usable table, token totals remain available and model-priced costs stay `null`.
