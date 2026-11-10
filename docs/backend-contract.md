# Backend contract

`scripts/usage-fetch.py` writes a single JSON document to standard output. The UI accepts schema version 1 and treats anything else as an unreadable backend response.

This contract covers live subscription limits only. The on-demand transcript/cost view uses a separate process and [estimated-cost contract](cost-contract.md), so a scan or pricing failure cannot replace healthy quota data.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2030-01-01T00:00:00+00:00",
  "providers": [
    {
      "id": "codex",
      "name": "OpenAI Codex",
      "status": "ok",
      "errorKind": "",
      "message": "",
      "authCommand": "codex login",
      "plan": "ChatGPT Pro",
      "account": "user@example.invalid",
      "source": "Codex app-server RPC",
      "windows": [
        {
          "id": "codex-primary",
          "label": "5 hour limit",
          "used": 42.0,
          "remaining": 58.0,
          "resetsAt": 1893474000,
          "windowSeconds": 18000,
          "detail": ""
        }
      ],
      "credits": null,
      "notice": "",
      "fetchedAt": "2030-01-01T00:00:00+00:00",
      "history": {
        "h24": [0, 0, 42],
        "d7": [0, 42]
      }
    }
  ]
}
```

All provider records have the same core keys, including error records. `status` is `ok` or `error`. Current `errorKind` values include `config`, `no_credentials`, `expired`, `cli_unavailable`, `rate_limited`, `timeout`, `network`, `http`, `rpc`, `malformed`, and `internal`.

`--source cliproxy` discovers provider IDs from managed accounts, independently of `--providers` (which selects local CLI providers). Proxy records use `source: "CLIProxyAPI management API"` and an empty `authCommand`. `accounts` contains each bounded account reading with an opaque `accountId`, display label, plan, windows, credits, and status. Paused accounts have `status: "disabled"`; providers without a quota adapter have `status: "unsupported"`. Neither is queried for quotas or represented as zero usage.

The provider-level fields describe the successful account with the lowest binding `used` percentage. `accountCount` includes paused accounts; `availableCount` counts successful quota lookups, not guaranteed remaining capacity. The proxy Limits view renders all `accounts` as separate cards, defaulting to the overall weekly window (monthly/first reported window when weekly is absent). An additional-limits toggle exposes other windows. Codex `planType` preserves the wire tier so `pro` and `prolite` display as Pro 20× and Pro 5×. Provider-level fields remain the pool/history summary; the proxy menubar selects an account using the separate activity contract below; account percentages are never summed. Errors preserve the previous reading in QML memory with `stale: true` and a notice. Only fresh backend readings enter history. Changing the connection clears in-memory data.

The top-level `source` identifies the selected source. The collector lists accounts and reads their quotas; it does not request the model catalog or client API keys. `hideAccountEmails` is a QML display setting, enabled by default: it substitutes numbered account labels and omits account identity from settings without changing the backend contract.

Quota requests use `GET /v0/management/auth-files` and `POST /v0/management/api-call`, with `$TOKEN$` substitution. Fixed Claude, Codex, and Kimi usage URLs use upstream GET; Antigravity’s `retrieveUserQuotaSummary` uses a read-only upstream POST containing the managed account’s project ID. Antigravity model-group buckets and Codex code-review/additional windows use the existing window contract. Missing Antigravity quota fractions produce `used: null` and `remaining: null`, with no meter.

History uses a separate `cliproxy-<SHA-256 server prefix>/history.json` directory for each normalized server URL; it contains no server address, account identifier, management key, or provider token. It stores provider pool summaries, including dynamically discovered providers.

Percentages are numbers in the inclusive range 0–100. `resetsAt` is a Unix timestamp in seconds or `null`. `windowSeconds` is the known window duration or `null`. Additional windows require no UI schema change.

A window limited to one model family adds `model`, its lowercase family name (`fable`, `opus`, `sonnet`); other windows omit it. Claude sets it for `seven_day_opus`/`seven_day_sonnet` and for `limits` entries whose `scope.model` names a known family, and Fusebox for its `model` windows. Claude's Fable week comes from the `weekly_scoped` `limits` entry scoped to Fable (labeled “Fable weekly”, also when `is_active` is false, which only marks the binding limit); without it, `seven_day_overage_included` supplies the same window. The proxy Limits view always gives the models in `UsageLogic.PINNED_MODELS` (Fable) their own line under each account, named by the model, and the tooltip adds a note on what happens once the allowance is spent.

History records the binding active quota window: the highest `used` percentage among the provider's current windows. For proxy pools this is independent of the last-used menubar account and prevents an idle model-specific window from hiding usage in another active window.

`credits`, when present, has this stable shape:

```json
{
  "label": "Extra usage",
  "currency": "USD",
  "used": 12.5,
  "limit": 50.0,
  "remaining": 37.5,
  "total": null,
  "unlimited": false,
  "resetCreditsAvailable": null
}
```

For Codex, `resetCreditsAvailable` is the nonnegative integer banked manual-reset balance. The proxy adapter maps `rate_limit_reset_credits.available_count` to it, independently of paid credits; `applicable_available_count` is not substituted for the banked total. Account cards show this balance beside the plan, including zero, and hide the badge when unknown. Failed refreshes retain it with the existing stale-reading notice.

### Explicit reset actions

`ResetBackend.qml` invokes `scripts/reset-credit.py` separately from usage polling. `--action prepare` resolves the selected opaque `--account-id` against the current managed Codex accounts and fetches `GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits` through management `api-call`. Its version-1 JSON response includes `ok`, `availableCount`, optional/unknown `applicableAvailableCount`, a `credits` array (`id`, `title`, `description`, `grantedAt`, nullable `expiresAt`), a target fingerprint, and a UUID `requestId`. Only available, unexpired `codex_rate_limits` credits are offered, sorted by expiry, grant time, then ID; no-expiry credits sort last. The applicable count is preserved without imposing undocumented eligibility semantics.

After confirmation, `--action consume` re-resolves the account and verifies the target fingerprint (opaque account ID, auth index, and ChatGPT account ID). Missing, ambiguous, paused, or replaced targets fail before submitting. The fixed upstream `/consume` endpoint receives `credit_id` and `redeem_request_id`. Both actions use the selected `auth_index`, `$TOKEN$` substitution, and `ChatGPT-Account-Id`; provider credentials never enter QML. Requests share a 12-second deadline, with a 30-second QML process bound, inherited 2 MiB HTTP ceiling, and 256 KiB QML output ceiling.

Successful action responses expose `outcome`: `reset`, `nothing_to_reset`, `no_credit`, or `already_redeemed`. HTTP success alone is insufficient. Failures expose a safe `message` and `uncertain` flag. Ambiguous submissions retain the same account, selected credit, and UUID for retries; they are never automatically resubmitted. Closing the panel preserves this in-memory state while the widget remains loaded. Changing connections invalidates confirmations and suppresses old process results. Confirmation freshness is capped at two minutes, and known expired credits cannot be submitted. Polling never calls the consume endpoint. The client contract is based on OpenAI Codex commit `c4017a87aacc7558002b7cb510025e967c1d765e`; these are internal ChatGPT endpoints.

Unsupported or unavailable fields are `null`; they are not overloaded with sentinel strings. History arrays are pre-bucketed percentages so QML never has to parse or aggregate the bounded on-disk sample set.

## Resource ceilings

Provider HTTP bodies and local JSON inputs are read with a 2 MiB ceiling before parsing. An oversized HTTP response becomes a provider-local `malformed` error and cannot suppress healthy providers. Codex app-server output is read incrementally in bounded chunks with a 2 MiB ceiling per JSON-RPC line; the same request deadline remains active even when a line is incomplete.

Fusebox and CLIProxyAPI connections are handled by `scripts/proxy_connection.py` for every backend: URL normalization, private key files, redirect rejection, and implementation detection. In `auto` mode Fusebox's `GET /api/accounts` is read first and CLIProxyAPI's `GET /v0/management/auth-files` second, only when the first answers 401, 403, 404, 405, or with an inventory that is not Fusebox's. Outages, timeouts, and rate limits are never reinterpreted as the other implementation. `--implementation rust|go` (passed by the widget after detection) reverses the order without removing the fallback. When both fail, an authenticated or server-side answer is reported before a missing route; two missing routes or two rejected keys get one combined message. `scripts/proxy-test.py` reads `{url, key, keyFile, requireFusebox}` as one stdin line and returns `{schemaVersion, ok, implementation, providers, accounts, message}` from the account list alone.

CLIProxyAPI management responses have the same 2 MiB ceiling. The management key file is capped at 8 KiB, checked for ownership and private permissions, and opened without following symlinks or blocking on FIFOs. After listing accounts, discovery covers at most 32 providers and 32 accounts per provider, with at most four provider groups running, four account workers per group, and a shared timeout budget; queued checks do not receive fresh timeout budgets. The QML process timeout remains the final wall-clock bound. TLS verification stays enabled and management redirects are rejected.

`UsageBackend.qml` streams stdout into a buffer capped at 2 MiB and terminates the backend if that ceiling is crossed. Stderr is drained without retention. This keeps the recurring collector from growing the long-lived Quickshell process even if a backend or provider CLI misbehaves.

## Last-used proxy account activity

`UsageActivityBackend.qml` uses the shared live collector for Rust by default.
With live disabled, or for Go/Keeper, it runs `scripts/proxy-activity.py` every 15 seconds in
CLIProxyAPI mode when a Keeper URL is configured. It uses `keeperUrl` and
`keeperPasswordFile` independently of Costs source configuration. The process reads proxy
`auth-files`, logs in to Keeper, reads `status` and `usage/identities`, and logs
out. No quota calls, request contents, consuming queues, or history exports are
used. Keeper must collect from the selected proxy.

The version-1 response contains `providers` and a safe `error` string. Each
provider activity record has `id`, `status` (`ok` or `ambiguous`), `accountId`
(the same opaque hash used by quota cards, or empty on a tie), and `lastUsedAt`
(Unix seconds). Keeper OAuth identities match by provider and auth index; only
current proxy accounts and nondeleted Keeper identities participate. The newest
`last_used_at` wins, including recorded failed requests. Equal timestamps from
different accounts produce an ambiguous result. No exact account is inferred
from priorities, quota remaining, token refresh timestamps, or activity buckets.

The menubar resolves this hash against quota `accounts`, using the matching
account's binding remaining percentage. Account labels appear only in tooltips,
respecting the privacy setting. Missing, ambiguous, or unmatched activity falls
back to the provider pool quota, explicitly identified in the tooltip. A known
last-used account with paused or unavailable quotas still shows no percentage. Quotas retain their normal refresh
cadence. Icon mode exposes account activity in the tooltip. Account activity
errors retain the previous reading with an explicit tooltip notice; connection
changes clear it and reject results from the previous process. Successful empty
responses clear old activity. The worker has a 10-second request budget (plus
bounded logout), a 15-second QML watchdog, a 2 MiB identity response ceiling, a
4096-identity limit, and a 64 KiB QML output ceiling. Only opaque account hashes
and timestamps cross the activity process boundary; no activity is persisted.

## Fusebox account snapshots

The proxy collector first tries the Go auth-file inventory. Legacy HTTP
401/403/404/405 allows a bounded authenticated native inventory probe; a valid
`/api/accounts` array is required to identify Rust. An outage is not treated as
an implementation change. The payload adds `proxyImplementation: go|rust`;
account rows add the same marker and `supportsBankedReset`. Quota polling is
read-only: no `api-call`, mutation, token refresh, or model generation is
invoked. Only an explicitly confirmed banked reset posts to Fusebox.

Rust quota rows retain `quotaUpdatedAt` and use it for `fetchedAt` and history
sampling. Native amounts are percentages, reset timestamps require timezones,
missing quota remains unknown, and observations older than ten minutes are
`stale`. Cached windows and limits past reset are omitted. Switching
implementations cannot restore old credits from a prior successful reading.

Claude, Codex and Meta OAuth `quota.windows` become windows. Their names are
`<duration>[ <scope>]` (`5h`, `week`, `3d`, `week opus`, `week oauth apps`);
the optional `model` names the scope and becomes the window's `model`; a model
week is labeled `<Model> weekly`. Claude's `week overage`
(`seven_day_overage_included`) is the Fable week and is dropped when `week
fable` is also present. `quota.limits` (tagged `scope.kind`)
map as follows: `account`, `model`, `models` and `model_families` become
windows, and a `:gate` limit only while it is at 100%. `feature` limits, and
limits with `enabled: false`, become windows with `informational: true`.
Python history and `UsageLogic.minRemaining` skip those, and they never get
warning colors. `overage` (Claude extra usage, USD cents) and `credits` (Codex
balance) become the account's `credits`. Antigravity has only limits. Plans
use `quota.plan_name`, Claude's `max_5x`/`max_20x` tiers, and ChatGPT's
`subscription_plan` SKU (`chatgptprolite`, `chatgptpro`, `chatgptpromax`).

Account rows add `statusItems`: `{kind, text, at}` with `kind` one of
`cooldown`, `renewal` (`estimated` optional), `warning`, `info` and `error`.
`at` is Unix seconds or null. QML formats renewals as a date and other times as
a countdown, refreshed once a minute. Expired items are dropped. A `last_error`
that indicates a rejected sign-in makes the row `status: error`,
`errorKind: expired`; other errors become an `error` item with emails masked.

`banked_resets.inventory.available` supplies `credits.resetCreditsAvailable`
for Claude and Codex OAuth accounts when the snapshot has no error or
unresolved (`pending`/`unknown`) operation. Zero and absent counts set
`supportsBankedReset: false`, so the badge stays hidden.

`reset-credit.py` resolves the same account hash among native accounts and
uses Fusebox's percent-encoded native ID. `prepare` reads
`GET /api/accounts/{id}/banked-resets`. It requires `inventory.eligible` and a
UUID `quote`, and lists usable unexpired grants, Fusebox's `selected_grant`
first. Codex with no listed grants gets one empty-ID choice, letting Fusebox
choose. `consume` posts `{action: redeem, request_id: quote, grant_id,
confirmed: true}`. `applied` maps to outcome `reset`; `already_used` and
`reconciled_used` map to `already_redeemed`; `refused` and `reconciled_unused`
map to `refused` with Fusebox's message. `pending`, `unknown`, network
failures and 5xx are uncertain. 4xx answers are refusals before dispatch and
carry Fusebox's `error` text. `--retry` repeats `redeem` with the same ID,
which Fusebox answers from its journal without spending. Only a still-unsettled,
retryable Claude request then sends `action: retry`.

Native account activity uses `last_used` and the same hashed filename account
identity as quota rows. It denotes completed requests including failures;
timestamp ties are ambiguous, and empty post-restart activity clears selection.

## Fusebox live activity

`UsageLogic.js` owns a reference-counted registry of parentless
`UsageLiveConnection.qml` objects keyed by proxy URL, key-file path and collector
path. Multiple bars/panels share a single `scripts/proxy-live.py` process. The
last consumer stops and destroys it; a connection change clears counts before
starting the new observer. It never reparents the observer to a panel.

The helper authenticates `/api/live` with a Bearer upgrade header, verifies TLS,
limits frames to 512 KiB and queues to four frames. Load snapshots report real
`in_flight` attempts and recent `sessions`. Only hashed account IDs, provider IDs,
counts and last-used timestamps cross the process boundary. Raw IDs and request
metadata are discarded. Native IDs are kept privately for mapping file/API-key
accounts to the existing stable hashes. Omitted inventory accounts have zero
load after the initial complete snapshot; unmatched quota cards remain unknown.

A 15-second heartbeat/snapshot deadline clears live counts on stale or broken
connections. Reconnect backoff grows from 2 to 60 seconds and resets only after
30 seconds of stability. Unsupported endpoints and a missing dependency retry
at 60 seconds, keeping cached last-used inventory available. QML additionally
limits stdout to 1 MiB and stops a stalled helper after 20 seconds. A crashed
helper restarts at most once per minute. Disconnect never replaces quota with
zero or invents idle. Last-used selection retains its existing semantics.

Inventory reads only `/api/accounts`, at most once per 15 seconds on request,
account or unknown-ID events, otherwise once per 60 seconds. These read the
server cache and do not trigger upstream quota refreshes. Heartbeat frames do
not change visible QML properties. `liveAccountActivity` defaults on,
Session counts appear at the right edge of each account name in Limits.
The menu bar remains quota-only. Counts retain Fusebox's recent-affinity meaning:
sessions may remain assigned after requests finish. The account line's tooltip
explains this; while disconnected, one line above the cards says so and the
counts are hidden. No model discovery,
per-session queries, extra polling or Fusebox server changes are needed.
The collector requires optional Python websockets 15+; Go/Keeper retains its
existing dependency and polling behavior.

Limits settings call the native Rust integration **Fusebox** and expose a
keyboard-accessible repository link to `https://github.com/DigitalPals/Fusebox`.
The Go implementation retains its CLIProxyAPI name. Before discovery, the
source is labelled “Fusebox / CLIProxyAPI”. Settings are `usageSource: proxy`,
`proxyUrl` and `proxyKeyFile`; the earlier `cliproxy`, `cliproxyUrl` and
`cliproxyKeyFile` are read until the next save migrates them. The contract keeps
`source: "cliproxy"` and `proxyImplementation: rust`/`go`; branding adds no network
calls or background processes.
