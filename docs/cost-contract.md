# Estimated-cost contract

`scripts/cost-fetch.py` writes an independent schema-v1 JSON document to standard output. `CostBackend.qml` requests it only after the Costs tab is opened and keeps the last known-good document when a later process, timeout, or schema error occurs.

`--source direct` (default) reads local transcripts. `--source keeper` uses
`--keeper-url` and an optional `--keeper-password-file` to read CPA Usage
Keeper's persisted proxy history. It discovers providers from those events,
independently of the local `--providers` filter. `--local-backfill` optionally
adds earlier local Codex proxy turns, with separate provenance and overlap
removal; it is disabled by default.
The top-level `source` is `direct` or `keeper`; older documents without it
render as direct. `history` is null for direct mode and an archive coverage
object for Keeper. Changing source, archive URL, or password file clears
in-memory results, and responses started for an old connection are discarded.
App-filter and local-recovery changes have the same isolation behavior.

## Keeper archive boundary

`scripts/keeper_costs.py` supports Keeper v1.15.4. It authenticates with
`POST /api/v1/auth/login`, reads `/status` and
`/usage/events/export?format=json&range=custom&unit=day`, then logs out its
ephemeral cookie session. All routes are relative to the configured base URL
and `/api/v1`. HTTPS certificates are verified; redirects are rejected.
The optional password file is read without following symlinks, must be a
regular file owned by the user with no group/other access, and is bounded to
8 KiB. Passwords and cookies never enter stdout, arguments, or widget settings.
Authentication-disabled, externally isolated Keeper deployments can omit the
password file. The GUI stores ASCII passwords using the same private,
transactional helper as the proxy management key; both can be saved together
and both staged files are removed if settings persistence fails.

The requested export covers the selected period in Keeper's reported IANA
timezone; exact rolling-24-hour or local-calendar bounds are applied after
download. This avoids Keeper's restricted custom-hour endpoint and preserves
the widget's own timezone and DST behavior. With local recovery enabled the
export always covers 30 calendar days, independently of the display period.
The export must be complete JSON
with `total_count` matching its event array. Bounds are 32 MiB per export,
50,000 events, 64 providers, 256 characters per model/event ID, and a shared
network deadline. Limit breaches and incomplete exports fail atomically,
preserving the existing same-connection view. Select a shorter period if a
complete export exceeds these limits. Status/login/logout responses have
separate 64 KiB limits; the QML process timeout remains the outer deadline.

Keeper's input/output counters are canonical totals. Cache reads and creation
are subtracted from input to get uncached input; reasoning is already included
in output. Negative, missing, non-integer, overflowing, or contradictory
counters are rejected. Invalid rows make coverage partial; an entirely invalid
nonempty export fails. Valid records retain measured token counts even for
unknown prices. Failed requests with measured usage are included; failure
alone does not prove zero billable tokens. Keeper's `cost_usd` is ignored.
Actual model IDs are used for pricing, not display aliases.

Event IDs are SHA-256 hashed together with the normalized archive URL for
deduplication. Account labels, client API keys, IP addresses, raw user agents,
error bodies, and request logs are discarded. Only a fixed app-family ID is
retained from the user agent. The export does not contain session IDs, so
archived session counts are zero and the UI labels proxy activity in requests. The
widget does not persist exports locally; durable history belongs to Keeper's
SQLite database. Widget refreshes never read CPA's consuming `/usage-queue`.

`history` contains `status` (`partial`), a display-safe `message`,
`skippedRecords`, `collectorHealthy`, and nullable `firstRecordAt` (Unix
milliseconds for the earliest valid record in the export), plus `lastRecordAt`
and `exportSince`. These are observed request dates, not a proven collector
start time. A healthy
collector and complete export do not prove that earlier traffic was captured:
the displayed notice explicitly excludes activity before collection and during
collection gaps. Keeper collection errors are summarized without forwarding
upstream error text or credentials. See [deployment](keeper-deployment.md).

### App filtering and local recovery

`--client` accepts `all` (default), `t3`, `codex-cli`, `codex-exec`,
`digital-brain`, or `other`. Unknown/missing client identities stay in `other`;
they are not attributed to a known app. `clients` lists these fixed IDs, names,
and record counts before filtering for the selected period. Filters group app
families across machines, not individual users or devices. `history.clientFilter`
and `clientName` identify the selected scope. Filtering happens after determining
the archive boundary, and applies to recovered local activity as well.

`--local-backfill` scans local Codex transcripts using the existing bounded,
cached parser. It accepts only sessions with a recognized proxy `model_provider`
(`cli_proxy_api`, `cliproxyapi`, `cli-proxy-api`, `cliproxy`) and a session ID.
Old logs cannot prove which proxy server handled the traffic, so recovery is
explicitly optional. Direct OpenAI, missing-provenance, and other-provider logs
are excluded. Local app identity comes from the sanitized session `originator`.

Only local turns completed strictly before the earliest archived request in
the 30-day export are eligible. No boundary or invalid exported rows disables
recovery; a short display period never creates a new cutoff inside a collection
gap. Session/time/token identity removes duplicate local copies. One-to-one
matching on model and all token fields within five minutes of an archived
timestamp conservatively removes boundary overlap/clock skew. Distinct local
requests with identical amounts remain separate. Combined records cannot exceed
50,000; limit errors preserve the last good result. Recovery does not modify
Keeper's database or persist proxy exports locally.

`history.backfill` reports `status` (`disabled`, `notNeeded`, `unavailable`,
`ok`, `partial`), cutoff `before`, `recoveredRecords` before filtering,
`includedRecords` after filtering, `overlapRecords`, and a display-safe message.
Unreadable local files make recovery partial. Each totals/provider/model/period
cell adds `archiveRecords` and `backfillRecords`; direct-mode cells have zero for
both. Recovered session counts remain local, and the UI distinguishes saved
requests from recovered turns.

Keeper period cells add `historyStatus`: `recorded`, `localOnly`, `mixed`, or
`unavailable`. Empty buckets with no archive observations are unavailable;
buckets containing other apps' archive observations can correctly have zero
matching records after filtering. Numeric counters retain their additive schema;
the UI renders unavailable totals as a dash and chart buckets as outlined gaps.
Recorded and local-only buckets still do not promise complete coverage.

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

Pricing statuses are `fresh`, `cached`, `unavailable`, or `notNeeded`. Coverage statuses are `ok`, `partial`, `missing`, or `failed`; unreadable files make coverage `partial` or `failed` rather than silently producing a complete-looking total. `scannedFiles` counts readable recent transcript files, including files with no usage-bearing rows, while `skippedFiles` counts files or directories that could not be inspected. `costSource` is `none`, `providerReported`, `modelPriced`, `customPriced`, `mixed`, or `unpriced`. Token totals always include unpriced records from readable files. `reasoningTokens` is informational and is already included in `outputTokens`; it must not be summed again.

## Pricing and custom rates

Pricing precedence is an exact custom model rate, then a provider-reported cost, then the public model rate. `pricing.basis` is `currentBaseRates`; `pricing.customModels` counts configured overrides. Every totals/provider/model/period cell includes `customPricedRecords`, `providerReportedRecords`, `basePricedRecords`, and `variantPricedRecords`. The first three sum to `pricedRecords`; `variantPricedRecords` is a subset of `basePricedRecords` whose bracketed suffix was removed for lookup. Mixed sources or unpriced records yield `costSource: "mixed"`. These fields are additive to schema v1; older payloads without them remain readable.

Public lookup keeps full lowercase provider-qualified IDs and canonical bare names. A bare alias is added only when no canonical entry exists and all qualified entries agree on all four rates. Unknown provider prefixes do not fall back to another provider's price. Bracketed model variants use the base model's rates; current base prices do not account for historical rates, context thresholds, or priority/flex/batch tiers. The UI labels this limitation. Negative, non-finite, or incomplete input/output rates are rejected; missing cache rates use the input rate.

The `costPriceOverrides` widget setting is a JSON string edited through ordinary settings fields. The collector accepts that string as `--price-overrides`:

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

Custom IDs are trimmed but retain case, provider prefixes, and variant suffixes. Input and output are required; omitted cache prices use the input price. Explicit zeros are preserved. Configuration is bounded to 64 KiB, 128 models, 256 characters per model, and finite prices from 0 to 1,000,000,000 USD per million tokens. Invalid configuration produces `backendError` and the QML backend retains its last good result. Unattributed local Kimi and synthetic activity cannot be priced through overrides. Model-attributed Kimi proxy events can use custom or public prices. Custom prices apply to the selected historical activity; removing one restores automatic pricing.

`--refresh-prices` bypasses the daily rate TTL, except for a successful download less than 60 seconds old. Explicit Costs refreshes set this flag; ordinary loading, period selection, and settings changes do not. A force request queued behind a running or starting process is preserved for the follow-up scan. Fetch failures fall back to valid cached prices. Rate-cache version 2 invalidates the old flattened lookup keys, which cannot be reconstructed reliably offline.

## Local sources and privacy

- Claude: `${CLAUDE_CONFIG_DIR:-~/.claude}/projects/**/*.jsonl`
- Codex: `${CODEX_HOME:-~/.codex}/sessions/**/*.jsonl`
- Kimi: `${KIMI_SHARE_DIR:-~/.kimi}/sessions/**/wire.jsonl`

Files are streamed line by line. Scan-cache version 3 adds a fixed Codex app-family ID and proxy-session flag to records and resumable state; older caches rebuild safely. It retains a byte offset, SHA-256 hash of up to 64 bytes immediately before that offset, device/inode identity, and sanitized Codex reducer state. A strictly grown file resumes only after its identity and guard match. Shrinkage, replacement, changed same-size files, or a failed guard cause a full reparse. The guard checks the previous tail, not the entire prefix: it is a lightweight check for normal append-only CLI transcripts, not a guarantee against arbitrary earlier in-place edits. Concurrently changed snapshots are skipped with incomplete coverage and retried on the next scan.

Records from a trailing segment without its final newline are provisional: they can appear in the current result but are replaced on the next append, never counted twice. Codex state at the last completed line preserves model attribution, duplicate signatures, and fork suppression across resumes. Each merge enforces per-file and global record limits, and scan byte limits include guard reads. Nanosecond mtimes remain exact integers. Old or corrupt positions cause a safe rebuild. Only usage-bearing records are parsed. The durable size/mtime cache stores token metadata and hashes every transcript path, session identifier, message identifier, and deduplication key with SHA-256. Prompts, responses, tool calls, tool results, and credentials are neither cached nor returned.

Resource use is bounded at every untrusted input boundary: 1 MiB per transcript line, 128 MiB per transcript file, 512 MiB of changed transcript input per scan, 20,000 usage records per file, and 50,000 records across a scan. Discovery is limited to 10,000 transcript files and 2,000 directories per provider without following symlinks. Scan-cache input is capped at 32 MiB, model names at 256 characters, and model output groups at 512 before remaining models are combined. Files that cross a ceiling are skipped atomically and make coverage `partial` or `failed`; their partial records are never reported as complete data.

`CostBackend.qml` streams backend stdout into a 4 MiB capped buffer and drains stderr without retaining it. Crossing the output ceiling terminates the process and preserves the last known-good cost document.

The state directory uses mode `0700` and cache files use `0600`. Corrupt or foreign cache versions cause a cold rebuild, never a broken view. Rate refresh failures fall back to the last cached LiteLLM table; with no usable table, token totals remain available and model-priced costs stay `null`.
