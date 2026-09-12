# Estimated-cost contract

`scripts/cost-fetch.py` writes schema-v1 JSON. Costs combines local Codex/Claude
history selected by `--providers claude,codex` with enabled servers in
`--t3-servers`. The latter is a JSON array of at most four objects:
`{"id":"home","name":"Home T3","url":"https://t3.example","tokenFile":"/private/token","enabled":true}`.
`costLocalProviders` and `costT3Servers` are independent of quota settings.
Legacy `costSource` and `costLocalBackfill` settings are ignored. Keeper is used
only by quota account activity, through `scripts/keeper_client.py`.

`CostBackend.qml` scans on demand, retains same-source results on process failure,
and clears results when the selected folders or server configuration changes.
Responses from an earlier source configuration are discarded. `source` is always
`transcripts`. There are no provider/app filters in the view.

## T3 boundary and deduplication

The reference is [pingdotgg/t3code](https://github.com/pingdotgg/t3code), commit
`b1e223e2b0d87124883b1410ab52dd6a1338e40d`. Usage contracts 4 and 5 are accepted.
`scripts/t3_costs.py` sends the Effect JSON RPC request `server.getUsageSummary`
over a native WebSocket connection to `<base URL>/ws`. HTTPS verifies certificates;
redirects are refused. Authentication uses a Bearer token. On an authentication
rejection the saved connection token is exchanged through `<base URL>/oauth/token`
for an access token scoped to `orchestration:read`, cached separately in a private
file. No refresh-token contract is assumed. Rejected connection tokens require
reconfiguration. Credentials never appear in arguments, widget settings or errors.

The token reader requires an owned private regular file, does not follow symlinks,
and limits input to 8 KiB. The GUI uses transactional token staging: settings save
commits the staged files; failed save or cancellation removes them. Blank fields
preserve existing tokens. Removing a server stops its use; private orphaned tokens
and snapshots are not automatically deleted, avoiding interference with shared
references. Files stay private under XDG configuration/state directories.

Queries use the widget's IANA timezone, inclusive calendar days for 7D/30D, and
exact rolling 24-hour bounds for 24H. T3 hourly buckets are anchored at the query
start. Responses are limited to 16 MiB, 50,000 buckets, 4,096 frames, and a shared
per-server deadline. Servers are queried concurrently with the local scan. Wrong
versions, mismatched dates/timezones, duplicate buckets, missing counters,
negative/noninteger counters, and reasoning greater than output are rejected.
Only Codex and Claude sources are imported. Unknown source/model prices do not
turn measured tokens into zero-cost claims.

Tokens are repriced using the same custom/public model table as local records;
T3's aggregate dollar estimates are ignored. Bucket `records` are weights, not
multipliers for token totals. Reasoning is part of output and never added again.

Each source provides hostname, provider, resolved transcript folder and
`device:inode`. These are hashed immediately. Matching host/provider/filesystem
identities are counted once, including symlink aliases. When an inode is
unavailable, the resolved folder is used. Fresh complete sources take precedence
over fresh partial and stale ones, with local preferred on ties. Missing/failed
sources cannot suppress a healthy duplicate. This identifies shared folders, not
transcript copies on distinct computers; replicated histories can still overlap.

Top-level `sources` contains `id`, `name`, `kind` (`local`/`t3`), optional `provider`,
`status` (`ok`, `partial`, `missing`, `failed`, `stale`, `unavailable`, `duplicate`),
`included`, nullable `updatedAt` in Unix milliseconds, and safe `message`.
Raw source hostnames, paths and server error bodies never enter the output/cache.

Normalized remote snapshots are private, keyed by URL, credential identity,
period and timezone. On failure a snapshot up to 32 days old is reused, clipped
to whole buckets inside the current window and labeled stale. Boundary hours
cannot be apportioned accurately, and new activity is unavailable. No snapshot
means an explicit unavailable source. Cache write failure does not discard a
valid live result. Rotating credentials or changing URLs isolates old snapshots.

Totals/provider sessions sum source-level distinct sessions, never per-bucket
session counts. Stale source sessions, and model/period cells with remote data,
use `null` where accurate unique counts cannot be derived. `remoteRecords`
tracks included remote responses. `historyStatus` is `recorded` or `unavailable`;
missing totals render as a dash and unknown empty chart periods as outlined gaps.
Source diagnostics remain available under Last scan in Costs settings; the main page omits the per-source status list.

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
      "id": "codex",
      "name": "OpenAI Codex",
      "status": "partial",
      "message": "Some files could not be read; totals may be incomplete.",
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

Pricing statuses are `fresh`, `cached`, `unavailable`, or `notNeeded`. Coverage statuses are `ok`, `partial`, `missing`, or `failed`; unreadable files make coverage `partial` or `failed` rather than silently producing a complete-looking total. `scannedFiles` counts readable recent transcript files, including files with no usage-bearing rows, while `skippedFiles` counts files or directories that could not be inspected. `costSource` is `none`, `providerReported`, `modelPriced`, `customPriced`, `mixed`, or `unpriced`. Token totals always include unpriced records from readable files. `reasoningTokens` is informational and is already included in `outputTokens`; it must not be summed again.

## Pricing and custom rates

The combined collector uses exact custom model rates, then the public model rate for every source. Transcript-reported costs are retained only in the parser cache for compatibility and are cleared before aggregation. `pricing.basis` is `currentBaseRates`; `pricing.customModels` counts configured overrides. Every totals/provider/model/period cell includes `customPricedRecords`, `providerReportedRecords`, `basePricedRecords`, and `variantPricedRecords`. The first three sum to `pricedRecords`; `variantPricedRecords` is a subset of `basePricedRecords` whose bracketed suffix was removed for lookup. Mixed sources or unpriced records yield `costSource: "mixed"`. These fields are additive to schema v1; older payloads without them remain readable.

Public lookup keeps full lowercase provider-qualified IDs and canonical bare names. A bare alias is added only when no canonical entry exists and all qualified entries agree on all four rates. Unknown provider prefixes do not fall back to another provider's price. Bracketed model variants use the base model's rates; current base prices do not account for historical rates, context thresholds, or priority/flex/batch tiers. The UI labels this limitation. Negative, non-finite, or incomplete input/output rates are rejected; missing cache rates use the input rate.

The `costPriceOverrides` widget setting is a JSON string edited through Costs settings fields. The collector accepts that string as `--price-overrides`:

```json
{
  "vendor/Exact-Model[1m]": {
    "inputCostPerMillionTokens": 2,
    "outputCostPerMillionTokens": 8,
    "cacheReadCostPerMillionTokens": 0.5,
    "cacheWriteCostPerMillionTokens": 3
  }
}
```

Custom IDs are trimmed but retain case, provider prefixes, and variant suffixes. Input and output are required; omitted cache prices use the input price. Explicit zeros are preserved. Configuration is bounded to 64 KiB, 128 models, 256 characters per model, and finite prices from 0 to 1,000,000,000 USD per million tokens. Invalid configuration produces `backendError` and the QML backend retains its last good result. Unattributed and synthetic activity cannot be priced through overrides. Custom prices apply to the selected historical activity; removing one restores automatic pricing.

`--refresh-prices` bypasses the daily rate TTL, except for a successful download less than 60 seconds old. Explicit Costs refreshes set this flag; ordinary loading, period selection, and settings changes do not. A force request queued behind a running or starting process is preserved for the follow-up scan. Fetch failures fall back to valid cached prices. Rate-cache version 2 invalidates the old flattened lookup keys, which cannot be reconstructed reliably offline.

## Local sources and privacy

- Claude: `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/**/*.jsonl`
- Codex: `${CODEX_HOME:-~/.codex}/sessions/**/*.jsonl`

Files are streamed line by line. Scan-cache version 5 rebuilds Codex records with duplicate signatures that include cumulative usage counters, so distinct responses with equal token counts remain counted. It also excludes former proxy/app classification metadata; older caches rebuild safely. It retains a byte offset, SHA-256 hash of up to 64 bytes immediately before that offset, device/inode identity, and sanitized Codex reducer state. A strictly grown file resumes only after its identity and guard match. Shrinkage, replacement, changed same-size files, or a failed guard cause a full reparse. The guard checks the previous tail, not the entire prefix: it is a lightweight check for normal append-only CLI transcripts, not a guarantee against arbitrary earlier in-place edits. Concurrently changed snapshots are skipped with incomplete coverage and retried on the next scan.

Records from a trailing segment without its final newline are provisional: they can appear in the current result but are replaced on the next append, never counted twice. Codex state at the last completed line preserves model attribution, duplicate signatures, and fork suppression across resumes. Each merge enforces per-file and global record limits, and scan byte limits include guard reads. Nanosecond mtimes remain exact integers. Old or corrupt positions cause a safe rebuild. Only usage-bearing records are parsed. The durable size/mtime cache stores token metadata and hashes every transcript path, session identifier, message identifier, and deduplication key with SHA-256. Prompts, responses, tool calls, tool results, and credentials are neither cached nor returned.

Resource use is bounded at every untrusted input boundary: 16 MiB per transcript line, 128 MiB per transcript file, 512 MiB of changed transcript input per scan, 20,000 usage records per file, and 50,000 records across a scan. Discovery is limited to 10,000 transcript files and 2,000 directories per provider without following symlinks. Scan-cache input is capped at 32 MiB, model names at 256 characters, and model output groups at 512 before remaining models are combined. Files that cross a ceiling are skipped atomically and make coverage `partial` or `failed`; their partial records are never reported as complete data.

`CostBackend.qml` streams backend stdout into a 4 MiB capped buffer and drains stderr without retaining it. Crossing the output ceiling terminates the process and preserves the last known-good cost document.

The state directory uses mode `0700` and cache files use `0600`. Corrupt or foreign cache versions cause a cold rebuild, never a broken view. Rate refresh failures fall back to the last cached LiteLLM table; with no usable table, token totals remain available and model-priced costs stay `null`.
