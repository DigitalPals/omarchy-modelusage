# Compatibility target

- Omarchy branch: `quattro`
- Omarchy commit: `2c247e390e357ae0fee3f8565b0c816adb705e6a`
- Development date: 2026-08-23
- Latest release review validation: 2026-09-13
- Plugin release: `1.1.1`
- Plugin manifest schema: 1
- Limit backend schema: 1
- Estimated-cost backend schema: 1

## Tested local runtime

The QML CI job reproduces this runtime from the Arch Linux Archive snapshot of
2026-09-13 (Qt 6.11.2, Quickshell 0.3.1) and the Omarchy commit above.

Qt 6.12 adds a `Color` singleton to QtQuick that hides an unqualified `Color`
from `qs.Commons`. The plugin therefore uses `Commons.Color`, as current
Omarchy `quattro` does. Under Qt 6.12 with the older Omarchy commit above,
Omarchy's own components still read the wrong singleton, so update Omarchy
together with Qt.

- Omarchy package: `4.0.3-1`
- Qt Declarative / `qmllint`: `6.11.2`
- Quickshell: `0.3.1-1` (Arch Linux package)
- Python: `3.14.7` locally; CI covers `3.10` through `3.14`
- Node.js test runner: `26.7.0` locally; CI uses Node.js 22

The 2026-09-12 release review passed 128 Python tests, JavaScript checks,
QML lint, quota/activity/cost/reset runtime checks, and the isolated live UI
contract. A clean package passed `omarchy plugin validate`. After a supported
desktop shell restart, live Claude/Codex Limits and refreshed Costs were
visually checked; the new shell log contained no plugin load or QML errors.

The 1.1.0 marketplace preparation repeated all 128 Python tests, JavaScript
checks, QML lint, and the quota/activity/cost/reset and isolated live UI contracts.
A clean package passed Omarchy validation. The marketplace's own manifest
validator and preview optimizer accepted the 496-character description and
1920×1080 preview. Following a desktop shell restart, live three-account Codex
Limits and refreshed Costs were visually checked without plugin load/runtime
errors. Direct CLI sign-ins were unavailable during this later check; the README's
local CLI screenshot is explicitly labeled as fixture data. Public screenshots
use numbered account labels and contain no account identities.

The 1.1.1 private-state security update passed 144 Python tests, including 16 new
security regressions, JavaScript checks, QML lint, and the quota/activity/cost/reset
and isolated live UI contracts. A clean package passed Omarchy validation. After
a supported desktop shell restart, live Claude and three-account Codex Limits and
refreshed Costs were visually checked with account names hidden. Quota history and
cost caches were freshly written with mode `0600` under the private state directory;
the new shell log contained no plugin load or QML errors.

## Provider compatibility

- T3 Code usage contracts 4/5 at `b1e223e2b0d87124883b1410ab52dd6a1338e40d`:
  native WebSocket RPC, token exchange, offline caching, common pricing and
  folder deduplication tested with synthetic HTTP/WebSocket servers. On
  2026-09-12, authenticated live contract-v5 collection was verified for
  24H/7D/30D in Europe/Amsterdam: every imported token category and response
  count reconciled with the server summary plus local usage. The desktop
  Costs view showed both remote Codex and Claude sources included.
- CPA Usage Keeper `v1.15.4`: optional quota account activity only. Costs no
  longer imports its request history.
- Claude Code CLI available during validation: `2.1.239`
- OpenAI Codex CLI available during validation: `0.149.0`
- Kimi Code quota normalization validated against fixtures from
  the pinned `MoonshotAI/kimi-cli` revisions below; a live Kimi sign-in was not
  available on the validation machine.
- CLIProxyAPI management contract checked against commit
  `5b2785617d1e7de84a9f4dee599d275a4ccd8999`; validated with synthetic HTTP
  integration tests and a live authenticated proxy with three Codex Pro accounts
  and two Claude accounts. Supports managed Claude, Codex, Kimi, and Antigravity
  quota endpoints; Kimi and Antigravity coverage is fixture-based.

Quota APIs and local transcript formats are provider-owned interfaces. The
fixture suite pins representative payloads so format drift produces a focused
compatibility update instead of silent fabricated data.

Reference implementations inspected during development:

- DigitalPals/fedora-config: `6aa074432f36548381ead91ed39d57c34529e327`
- DigitalPals/fedora-config CLIProxyAPI widget reference: `431def720d4b905c1563d600be33ca50eed621bb`
- router-for-me/CLIProxyAPI management API: `5b2785617d1e7de84a9f4dee599d275a4ccd8999`
- MoonshotAI/kimi-cli quota APIs: `d723cc47ee43e5ca3c3c4ec2473f205d44acede2`
- MoonshotAI/kimi-cli wire usage: `cbc15c076d17f70fec9f89c90c0502e68657f505`
- pingdotgg/t3code: `b1e223e2b0d87124883b1410ab52dd6a1338e40d`
- BerriAI/LiteLLM public model-price schema, fetched at runtime

## Fusebox

Fusebox v0.14.0 at `6f0e45fabfdee0e77aac3e6500db85dd2bbf5552` (formerly
CLIProxyAPI-Rust; v0.3.2 at `3f937ce690d7507065a42be9ce11b26fc16eee06` remains
compatible). The adapter detects authenticated `GET /api/accounts` with the
same management key used for Go. Cached quota windows and typed limits are read
for Claude, Codex and Meta OAuth accounts and Antigravity quota groups; other
account types remain visible with quota unavailable. Claude extra usage, Codex
credits, plan names, renewals, cooldowns and banked reset counts are read from
the same snapshot; older servers that omit them leave those values unknown.
Claude's Fable week needs Fusebox `main` at
`45b0f66090c6fdf12bd8a4220e0727097311adb1` or later (after v0.15.0). Older
servers report an inactive Fable entry as just renewed, so its window is
omitted as past its reset.
Banked resets use `GET`/`POST /api/accounts/{id}/banked-resets` and need
`banked-resets: true` on the server. Native `/reset` only clears cooldowns and
is never a banked reset.

Fusebox Costs needs `/api/usage/dashboard` (with `stack` and `provider`
filters) and `/api/usage/observations?view=combined`; HTTP 503 means analytics
is disabled or busy.

Fusebox quota observation times are retained and marked stale after ten minutes.
Expired windows are omitted, and duplicate observations do not extend quota
history. Activity records the latest completed request, including failures,
resets when the proxy restarts, and requires no Keeper. Costs still uses only
local/T3 transcripts. Synthetic HTTP tests cover detection, invalid keys,
malformed data, identity continuity, activity, typed limits, account facts,
and banked-reset reads, redemption, refusals and retries.
