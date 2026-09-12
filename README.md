# Model Usage for Omarchy

[![CI](https://github.com/DigitalPals/omarchy-modelusage/actions/workflows/ci.yml/badge.svg)](https://github.com/DigitalPals/omarchy-modelusage/actions/workflows/ci.yml)

Native Omarchy Quattro quota and activity monitoring for Claude Code, OpenAI Codex, and Kimi Code, with direct CLI and CLIProxyAPI quota sources. A compact bar widget opens a keyboard-friendly panel with provider limits, reset times, credits, persistent quota history, and on-demand API-equivalent cost estimates from local CLI transcripts or archived CLIProxyAPI traffic.

<p align="center">
  <img src="docs/model-usage-panel.png" alt="Model Usage panel showing Claude Code quota windows, extra usage, and history" width="560">
</p>

The screenshot reflects the shipped Quattro UI with representative usage data.

The panel follows Quattro's `Panel`, `KeyboardPanel`, hero, section, button, border, typography, spacing, focus, tooltip, and popup-coordination conventions. Quota and history visuals deliberately retain DigitalPals' fixed-block meter language.

## Compatibility

Developed and validated against Omarchy's `quattro` branch at commit [`2c247e390e357ae0fee3f8565b0c816adb705e6a`](https://github.com/basecamp/omarchy/commit/2c247e390e357ae0fee3f8565b0c816adb705e6a) (2026-08-22).

This plugin uses schema-v1 third-party bar-widget APIs from that revision. It does not patch Omarchy, install system files, or extend Omarchy's built-in agent collector directory.

See [COMPATIBILITY.md](COMPATIBILITY.md) for the tested runtime and provider CLI versions.

## Requirements

- Omarchy Quattro with schema-v1 third-party shell plugins.
- Python 3.10 or newer available as `python3`; the backends use only the standard library.
- At least one enabled provider CLI signed in with its normal login command, or a CLIProxyAPI server with managed provider sign-ins.
- Network access to the selected providers for quota checks. Opening Costs may also fetch the public LiteLLM pricing table from GitHub once per day.

## Install

Review third-party plugin code before installing it; Omarchy plugins execute as your user inside the long-lived shell process.

```bash
omarchy plugin add https://github.com/DigitalPals/omarchy-modelusage.git --enable
```

Manage it later with:

```bash
omarchy plugin disable digitalpals.model-usage
omarchy plugin enable digitalpals.model-usage
omarchy plugin update digitalpals.model-usage
omarchy plugin remove digitalpals.model-usage
```

The built-in `omarchy.agents` plugin is neither changed nor disabled. Both can coexist. If you prefer this plugin as the only AI usage widget, disable the built-in yourself:

```bash
omarchy plugin disable omarchy.agents
```

## Providers and authentication

Model Usage is a monitor, not an authentication manager. Its backend code reads credentials already owned by each official CLI, performs read-only calls, and does not write authentication state. A provider CLI may continue managing its own credentials when it is started normally—for example, Codex owns the app-server process used for its account RPC.

| Provider | Usage source | Sign-in command |
|---|---|---|
| Claude Code | Claude OAuth usage endpoint, including structured/scoped limits and extra usage | `claude auth login` |
| OpenAI Codex | `codex app-server` account/rate-limit RPC in a read-only sandbox | `codex login` |
| Kimi Code | Kimi's current `/usages` and optional `/me` endpoints | `kimi login` |

Environment overrides owned by the CLIs are honored: `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `KIMI_CODE_HOME`, `KIMI_CODE_BASE_URL`, and `KIMI_SHARE_DIR`.

### CLIProxyAPI

Open the Model Usage popup and click the **gear icon** in its upper-right corner. Select **CLIProxyAPI** under **Quota source** to discover all providers and accounts managed by [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI). Local CLI sign-ins are not needed for this source. The default `direct` source retains the existing behavior. Click **Save** to apply your configuration.

Set **CLIProxyAPI server URL** to your server address (default `http://127.0.0.1:8317`). Dashboard URLs ending in `/management.html`, management API URLs ending in `/v0/management` or `/v0/management/auth-files`, and reverse-proxy path prefixes are accepted. HTTPS certificates are verified; redirects are rejected.

Enter the server's **Management API key** in the masked settings field and click **Save**. Use the plaintext key accepted by the management panel, not a client API key or a bcrypt hash from the server configuration. The widget stores it automatically in a private file with permissions `0600`; you do not need to create or choose a file. Leave the field blank to keep your existing key. The saved key is never loaded back into the form, and Cancel discards an entered key.

For terminal-only configuration, you can still supply a key file with `cliproxyKeyFile`. The default file is `${XDG_CONFIG_HOME:-~/.config}/omarchy/model-usage/cliproxy.key`. To create it without putting the key in shell history:

```bash
install -d -m 700 "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/model-usage"
(umask 077; read -r -s -p 'CLIProxyAPI management key: ' proxy_key; printf '\n';
 printf '%s\n' "$proxy_key" > "${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/model-usage/cliproxy.key")
```

Enable the source:

```bash
omarchy bar set digitalpals.model-usage usageSource cliproxy
omarchy bar set digitalpals.model-usage cliproxyUrl https://proxy.example.com
```

The collector lists managed accounts and asks CLIProxyAPI to make read-only upstream quota calls using `$TOKEN$` substitution. Provider tokens stay on the server. All managed providers are discovered automatically, independently of the local CLI provider selection. Claude, Codex, Kimi, and Antigravity have quota lookups; other providers stay visible with an explicit unsupported-quota notice. Antigravity requires the account’s project ID. Paused accounts remain browsable without being queried. Remote servers must permit remote management access.

**Limits** shows every connected account for the selected provider as a separate card, with its own account label, plan, remaining quota, and reset time. Codex defaults to the overall weekly limit, with **Codex Pro · 20×** and **Codex Pro · 5×** labels taken from the reported plan tier. A badge beside each Codex plan shows its banked manual resets, including zero; the badge is hidden when the count is unavailable. For example, three connected Codex subscriptions produce three account cards. **Show additional limits** reveals session, model-specific, and other windows. Monthly-only plans show their monthly allowance; accounts without a weekly/monthly allowance show their first reported window. Paused and failed accounts stay visible with their own status. Percentages are never added across accounts.

In CLIProxyAPI mode, click a nonzero **banked resets** badge to review that account's current reset credits. The confirmation shows each reset's effect and expiry, selects the earliest expiry first (non-expiring credits last), and lets you choose another credit before clicking **Apply reset**. Account labels respect **Hide account emails**. The action spends one selected credit only on that account, then refreshes usage. Confirmations expire after two minutes and are dismissed when the configured connection changes. If the outcome is uncertain, **Retry same reset** reuses the original request identifier; closing the popup preserves that retry while the widget remains loaded. The upstream reset endpoints are internal ChatGPT APIs and may change.

Provider buttons wrap to fit the panel. Failed refreshes preserve the last known reading in memory with a stale-data notice; switching servers clears those readings. At most 32 accounts per provider are checked, with four concurrent checks per provider and a shared deadline. In **Percentages** menubar mode, each provider shows only its icon and remaining quota; account names appear in the tooltip. When the last-used account is known, the percentage belongs to that account. Account activity refreshes every 15 seconds through the configured CPA Usage Keeper, independently of quota refreshes and the Costs source. Configure the Keeper URL and password in settings for the same proxy. Hover for the last recorded request time. Round-robin and concurrent requests can use different accounts, so this identifies the most recently recorded request, not a guaranteed account for the next request. Without matching activity, or when account timestamps are tied, the bar still shows the best-capacity account’s quota. The tooltip identifies this pool summary and explains that the last-used account is unknown. Failed activity refreshes retain the last-known account with a tooltip notice. Icon mode includes last-used details in its tooltip.

**Hide account emails** is enabled by default in widget settings. Account cards and menubar tooltips use numbered labels (Account 1, Account 2, …), and account identities are omitted from the settings details. Turn it off and Save to show usernames/email addresses. This is a display preference; quota collection continues normally.

Proxy quota history continues to record the best-capacity pool summary and is stored separately for each server under `cliproxy-<server-hash>/history.json` in the normal state directory. It never mixes with direct-CLI history. The separate **Costs source** setting selects local transcripts or archived proxy requests.

### CLIProxyAPI cost history

Select **CLIProxyAPI history** under **Costs source**, enter the **CPA Usage Keeper URL** and its separate **Keeper login password**, then Save. The password is stored in a private file; leaving the field blank preserves the saved password. Quota configuration remains independent. The default Costs source is **Local transcripts**.

[CPA Usage Keeper](https://github.com/Willxup/cpa-usage-keeper) must run continuously alongside the proxy. It saves events in SQLite while the desktop is offline. See [collector deployment](docs/keeper-deployment.md) for the pinned version, systemd service, TLS, backups, and validation. The widget reads Keeper's history export; it never consumes CLIProxyAPI's usage queue.

Costs shows the earliest saved request in the scanned history. Outlined chart
gaps mean **history unavailable**, not zero usage. Collector health and the
percentage of records priced do not establish complete historical coverage.
App filters distinguish T3 Code, Codex CLI, Codex Exec, Digital Brain, and
other/unknown clients. They group the same app across all proxy devices; using
the same account does not make another computer's local transcripts available.

Enable **Recover earlier local usage** in settings to add recognized Codex
proxy sessions from this device before the archive boundary. Recovery is off
by default because old logs identify the proxy provider but not its server;
they may include another proxy you used. Direct OpenAI sessions are excluded.
Saved requests and recovered local turns have separate counts. Recovery removes
overlap and duplicate local copies, respects the app filter, and never fills
gaps inside the archive or retrieves another device's logs. It reads 30 days of
archive history even in shorter views to keep the cutoff consistent; disable
recovery to use a shorter export if the archive exceeds the download limit.

Costs displays 24H, 7D, and 30D recorded activity using the same LiteLLM rates and custom model prices as local Costs. Keeper's own calculated dollar amounts are ignored. Providers and actual model IDs come from the archive; model-attributed Kimi traffic can be priced. Cache reads/writes and reasoning are normalized without double counting. Request counts replace session counts because Keeper's export has no session IDs.

By default, only archived proxy requests are included. Optional local recovery adds earlier recognized proxy sessions with overlap removed. Missing traffic cannot be reconstructed unless usable local logs exist. Collection errors and skipped invalid records appear as incomplete coverage. An unavailable archive preserves the last successful view for that connection; changing source, URL, password file, app filter, or recovery setting clears old totals.

For standalone quota backend use, `--source cliproxy`, `--cliproxy-url`, and `--cliproxy-key-file` are available. `CLIPROXY_API_URL` supplies the URL when the CLI flag is omitted, and `CLIPROXY_API_KEY_FILE` supplies the key path when neither the widget nor the CLI sets one. Keys are never passed as command-line arguments or saved in widget settings.

No access or refresh token is printed, copied into plugin state, or included in display errors. State is XDG-aware: the plugin directory uses mode `0700` and its files use `0600`.

```text
${XDG_STATE_HOME:-~/.local/state}/omarchy/model-usage/history.json
${XDG_STATE_HOME:-~/.local/state}/omarchy/model-usage/cost-scan-cache.json
${XDG_STATE_HOME:-~/.local/state}/omarchy/model-usage/cost-model-rates.json
```

`history.json` contains bounded quota percentages. The cost scan cache contains only timestamps, model names, token counters, reported cost values, SHA-256 identifiers for transcript paths, sessions, and deduplication keys, and bounded resume metadata (byte position, device/inode, hashed tail guard, and sanitized Codex parser state). It never contains prompts, responses, or tool output. The model-rate cache is a compact copy of public LiteLLM prices.

## What it shows

- An Omarchy-native provider hero with the subscription plan visible and account/source details in the settings menu.
- Any number of normalized session, weekly, model-scoped, additional, and spend-control windows.
- Fixed blocks with a real partially filled boundary block, using Omarchy colors and scaling.
- Reset countdowns and useful absolute reset times.
- Claude/Kimi extra usage, Codex credit balances, and Codex reset-credit counts when exposed.
- Compact 24H and 7D history based on the binding active quota window (the highest used percentage); samples survive shell restarts.
- A separate Costs tab with 24H, 7D, and 30D API-equivalent estimates, token totals, cached-input savings, time charts, and provider/model breakdowns.
- Honest pricing coverage: unknown or offline pricing renders as unavailable, never as a fabricated `$0.00`.
- Clean missing, expired, HTTP, provider-rate-limit, timeout, malformed-data, and CLI-unavailable states.

A failure in one provider is isolated; healthy providers remain selectable and render normally.

### What “estimated cost” means

Costs are the approximate API value of recorded tokens, not money charged to a Claude, ChatGPT, or Kimi subscription. Exact-model custom prices take precedence when configured; otherwise Claude-reported transcript costs take precedence over LiteLLM's public input, output, cache-read, and cache-creation rates. Archived proxy requests use custom or public prices. The Costs view identifies custom prices, provider-reported costs, and public base-rate estimates.

Public prices refresh automatically after 24 hours and are cached for offline use. **Refresh in Costs** also refreshes prices before that deadline, with a one-minute minimum between successful downloads. Provider-qualified model IDs keep their own rates; conflicting reseller prices cannot overwrite a canonical model. Bracketed variants such as `[1m]` use the base model's current rates and are identified as base-rate estimates. Historical prices, long-context premiums, and priority/flex/batch tiers are not inferred.

Claude and Codex transcripts contain enough historical model information for estimation. Kimi's `wire.jsonl` contains reliable token counters but not reliable historical model attribution, so Kimi is shown as token-only and unpriced instead of being guessed. Transcript scanning starts only when the Costs tab is opened with missing/stale data or explicitly refreshed.

## Interactions

- Left click: toggle the panel.
- Middle click: select the next enabled provider.
- Right click: intentionally unused; the plugin does not invent an unrelated action.
- `h` / `l` or Left / Right: select provider in Limits.
- `j` / `k` or Down / Up: scroll.
- `r` or Enter: refresh.
- `c`: open the Costs tab.
- `u`: return to the Limits tab.
- Gear icon or `s`: open settings. Tab / Shift+Tab moves between form controls; Escape cancels the draft.
- Tab / Shift+Tab: move to the neighboring bar panel through Omarchy's panel coordinator.
- Escape: close.

Namespaced IPC is available through the normal shell command:

```bash
omarchy-shell digitalpals.model-usage open
omarchy-shell digitalpals.model-usage close
omarchy-shell digitalpals.model-usage toggle
omarchy-shell digitalpals.model-usage refresh
omarchy-shell digitalpals.model-usage next
omarchy-shell digitalpals.model-usage limits
omarchy-shell digitalpals.model-usage costs
omarchy-shell digitalpals.model-usage configure
```

## Settings

Open the popup and click the **gear icon** beside Refresh to configure Model Usage. The gear is available in Limits and Costs, including when no providers are enabled. **Save** writes your changes to the widget's entry in `~/.config/omarchy/shell.json` and applies them immediately; **Cancel** or Escape discards the draft.

In local CLI mode, each provider has two controls: **Monitor** enables quota checks and includes it in the popup; **Menu bar** allows its percentage chip in the bar. Choose **Provider percentages** under **Menu bar display** to show those chips. Hiding a provider from the bar keeps it available in the popup. The widget icon remains accessible when all chips are hidden, on vertical bars, or when no selected provider has quota data.

In CLIProxyAPI mode, all discovered providers are monitored automatically; the provider list controls their menu-bar visibility.

The form also includes quota source, CLIProxyAPI URL and a masked Management API key field, refresh interval, and warning/critical thresholds. Key storage is handled automatically. Non-secret settings are also declared in `manifest.json` and can be changed using `omarchy bar set`.

Under **Custom model prices**, add the exact model ID and its input/output prices in **USD per million tokens**. Model IDs in the Costs breakdown are selectable for copying. Matching preserves case, provider prefixes, and bracketed variants. Cache-read and cache-write prices are optional; blank fields use the input price, while `0` explicitly means free. Save applies the prices immediately to recorded activity, including offline or otherwise unknown models. Remove a price row and Save to restore automatic pricing. Cancel discards edits. Local Kimi transcripts remain token-only because their historical model is unknown; model-attributed proxy events can be priced.

| Key | Default | Meaning |
|---|---:|---|
| `refreshIntervalSec` | `900` | Automatic refresh interval; clamped to 60–3600 seconds |
| `enabledProviders` | all three | Local CLI providers queried and displayed; proxy discovery is automatic |
| `usageSource` | `direct` | `direct` CLI sign-ins or `cliproxy` managed accounts for quotas |
| `cliproxyUrl` | `http://127.0.0.1:8317` | CLIProxyAPI server or management URL |
| `cliproxyKeyFile` | empty | Set automatically when saving a key in the GUI; can also point to an existing private key file |
| `hideAccountEmails` | `true` | Replace account identities with numbered labels and hide them in settings |
| `barDisplayMode` | `Icon` | `Icon` or compact `Percentages` |
| `barProviders` | all three | Enabled providers allowed to show percentage chips; independent of popup visibility |
| `warningThreshold` | `25` | Mark urgent at or below this percentage remaining |
| `criticalThreshold` | `10` | Critical threshold in percentage remaining |
| `costPriceOverrides` | `"{}"` | JSON string managed by Custom model prices; exact IDs mapped to USD-per-million rates |
| `costSource` | `direct` | Local transcripts (`direct`) or CLIProxyAPI history (`keeper`); independent of quota source |
| `costKeeperUrl` | empty | CPA Usage Keeper URL, including a deployment path such as `/keeper` |
| `costLocalBackfill` | `false` | Recover this device's earlier Codex proxy sessions, with overlap removed and separate attribution |
| `costKeeperPasswordFile` | empty | Private Keeper login password file, managed by the settings form |

Examples:

```bash
omarchy bar set digitalpals.model-usage refreshIntervalSec 300 --json
omarchy bar set digitalpals.model-usage enabledProviders '["claude", "codex"]' --json
omarchy bar set digitalpals.model-usage barDisplayMode Percentages
omarchy bar set digitalpals.model-usage warningThreshold 20 --json
omarchy bar set digitalpals.model-usage criticalThreshold 5 --json
```

`Percentages` renders one compact provider-logo chip per provider with meaningful limits, followed by its binding window's remaining percentage. Clicking a chip opens that provider directly. Left and right bars automatically fall back to the icon presentation so the widget does not become excessively tall.

## Architecture

- `Panel.qml` owns the injected bar widget, native popup, keyboard behavior, provider selection, error/credit/limit presentation, and namespaced IPC.
- `UsageBackend.qml` owns one bounded asynchronous Python process, coalesces duplicate refresh requests, applies the configured interval, and rejects malformed contract output.
- `scripts/usage-fetch.py` performs parallel, failure-isolated provider collection and emits the versioned provider-neutral contract documented in [docs/backend-contract.md](docs/backend-contract.md).
- `CostBackend.qml` owns an independent, on-demand transcript scan, keeps the last known-good result across malformed responses, and never changes quota polling.
- `scripts/cost-fetch.py` streams CLI JSONL, applies provider-specific deduplication, resumes growing files from a guarded byte position, caches sanitized usage records, prices attributable models, and emits [the estimated-cost contract](docs/cost-contract.md).
- `CostPriceEditor.qml` provides validated custom-price fields inside settings, with exact model matching and Save/Cancel behavior.
- `UsageCosts.qml` renders the metric/period controls, time chart, token mix, pricing coverage percentages, and provider/model breakdowns without parsing raw history in QML.
- `BlockMeter.qml` renders one track item per fixed block plus only the partial boundary fragment—there is no duplicate full-width fill layer.
- `UsageHistory.qml` receives small pre-bucketed arrays; large history files are never parsed in QML.

The packaged script and assets are found with `Qt.resolvedUrl`, so cloned plugins, symlinked development checkouts, and Omarchy's hot reload all use the plugin's actual source directory.

Polling never overlaps: a refresh requested while a collector is running is collapsed into one follow-up run. Provider requests, transcript scans, price downloads, and both QML processes have timeouts. Provider/local JSON, Codex RPC messages, QML process streams, transcript lines/files/scan volume, cached scan records, and aggregate records all have explicit memory ceilings; limit breaches fail locally or produce honest partial coverage. The one-second countdown timer runs only while the panel is open, quota history is capped to seven days, and transcript cache retention is capped to 32 days for the longest 30-day view plus boundary slack.

## Development and testing

Run the routine checks without opening test windows:

```bash
OMARCHY_QUATTRO_PATH=/path/to/omarchy-quattro ./tests/run
```

The suite performs:

- Python syntax checks and fixture/contract tests on Python 3.10 through 3.14 in CI.
- Claude, Codex, and Kimi normalization tests, including multiple/scoped windows and credits.
- CLIProxyAPI HTTP integration, account-pool selection, disabled accounts, management/upstream errors, private key handling, redirect rejection, and source-isolated history.
- Claude/Codex/Kimi transcript parsing, repeat/fork deduplication, token accounting, pricing, partial/unavailable costs, private cache tests, and adversarial input-ceiling tests.
- Canonical/provider price collisions, ambiguous aliases, context variants, custom-price precedence, forced-refresh throttling, and incremental/cold scan equivalence across partial lines, replacements, and rewrites.
- When Quickshell is available, an invisible QML test exercises custom-price editing, validation, persistence payloads, queued refreshes, and preservation of the last good result.
- missing/expired credentials, HTTP errors, timeouts, rate limiting, malformed data, and provider-failure isolation.
- bounded XDG history persistence and corrupt-history recovery.
- JavaScript threshold and compact-percentage tests.
- `omarchy plugin validate` when available.
- `qmllint` against the supplied Quattro source tree.
- Reset selection and account targeting, proxy HTTP requests, response outcomes, and idempotent retries. When Quickshell is available, a QML test checks confirmation state, duplicate clicks, cancellation, expiry, and connection changes using a synthetic backend; it opens no desktop popups. With Wayland it also loads the full panel and tests badge activation; otherwise it runs the reset components offscreen.

Live UI checks are opt-in. They launch a separate Quickshell test instance and
show popups on the current desktop; they do not restart the running shell:

```bash
MODEL_USAGE_LIVE_TESTS=1 ./tests/run
```

This checks QML loading, dark/light palettes, unusual accents, changed
font/spacing scales, partial block fill, and opening/closing the usage and
settings panels at one fixed edge (top). It also scans the runtime log for
binding loops, assignment failures, JavaScript exceptions, and component load
failures. The live checks require Wayland, Quickshell, and the Quattro source
tree; set `OMARCHY_QUATTRO_PATH` as above if needed.

For changes to popup positioning or bar layout, explicitly enable the full
four-edge cycle:

```bash
MODEL_USAGE_LIVE_TESTS=1 MODEL_USAGE_TEST_ALL_EDGES=1 ./tests/run
```

`qmllint` cannot resolve child properties of Omarchy's dynamic `QtObject` theme tokens, the injected `bar` object, or Quickshell's native `QProcess::ExitStatus` signal type from the supplied import tree. The harness disables those two warning categories, treats every other warning as a failure, and uses the live Quickshell contract as the authoritative compile/runtime check for the dynamic bindings.

When developing from a symlink below `~/.config/omarchy/plugins/`, do not assume saving a file or rescanning plugins updates the running QML components. On this machine, the watcher does not watch the checkout behind that symlink, and a rescan did not reliably apply a nested component change. After validation, use `omarchy restart shell`, confirm a new shell PID, reopen the affected view, and inspect the actual result. See [AGENTS.md](AGENTS.md) for the verified live-application procedure.

Maintainers should follow the [release checklist](docs/releasing.md) before tagging a version.

## Troubleshooting

**The panel asks me to sign in.** Run the exact command displayed for that provider, then press `r`. This plugin will not repair credentials itself.

**Codex reports unavailable.** Confirm `codex` is on `PATH` and `codex login` succeeds. The collector uses current app-server RPC with `-s read-only -a never`; it does not call the older private web endpoint.

**Kimi does not appear.** Confirm `kimi login` has created `~/.kimi-code/credentials/kimi-code.json`, or set `KIMI_CODE_HOME` to the CLI's actual data directory.

**CLIProxyAPI reports configuration required.** Check the server URL, enter the Management API key in settings, and check the server's remote-management policy. If using a manually configured key file, check its path and permissions. HTTP 404 can mean the management API is disabled. For an expired managed provider sign-in, sign in again through CLIProxyAPI and refresh the widget.

**History is empty.** History begins after the first successful limit fetch. Errors are not recorded as zero usage.

**Costs are unavailable but tokens appear.** The transcript was readable but its historical model could not be matched to a price, or the LiteLLM table has never been downloaded successfully. Connect and refresh Costs, configure an exact-model custom price, or use the Tokens metric; unknown prices are intentionally not displayed as zero. Invalid custom-price settings produce an error and preserve the last good result rather than silently falling back to different prices.

**The first Costs scan is slower.** A cold scan streams recent transcript files. Later scans reuse unchanged files and read only the appended bytes of growing sessions. Replaced, shortened, or detected rewritten files restart from the beginning. The first scan after this upgrade rebuilds old scan and price caches; stale flattened prices are never reused.

**Kimi has no dollar estimate.** Current Kimi Code wire records expose token usage without reliable historical model identity. The plugin reports those tokens but will not invent a price.

**The backend cannot start.** Python 3.10 or newer must be available as `python3`. The backend uses only the Python standard library.

**I see two AI widgets.** `digitalpals.model-usage` and `omarchy.agents` are intentionally independent. Disable whichever one you do not want.

## License and attribution

The plugin is MIT licensed. See [LICENSE](LICENSE), [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md), [CHANGELOG.md](CHANGELOG.md), and [SECURITY.md](SECURITY.md). Provider names and marks remain the property of their respective owners and do not imply endorsement.
