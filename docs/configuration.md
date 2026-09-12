# Configuration reference

[Back to README](../README.md)

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

Proxy quota history continues to record the best-capacity pool summary and is stored separately for each server under `cliproxy-<server-hash>/history.json` in the normal state directory. It never mixes with direct-CLI history. Costs sources are configured separately using the gear on Costs.

### Local and remote cost history

Open **Costs → gear** to configure sources and prices. Local **Codex CLI** and
**Claude Code CLI** history are enabled by default, independently of the quota
providers. Enable or disable either source in Costs settings.

Choose **Add T3 server**, enter a name, its HTTP(S) base URL, and its connection
token, then **Save**. Up to four enabled servers are included automatically in
24H, 7D, and 30D totals. Use a compatible [T3 Code](https://github.com/pingdotgg/t3code)
server with usage contract version 4 or 5. Tokens are stored in private files;
blank token fields preserve saved credentials. T3 may exchange a connection
token for an access token; rejected or expired credentials produce a reconnect
notice. Use a fresh connection token when prompted by the source status.

T3 scans Codex and Claude transcripts readable on its server, **including
sessions started outside T3**. Another computer contributes only when its
history is available through a configured server. Identical transcript folders
reported by local and remote sources, or multiple T3 servers, are counted once.
Copies on different machines cannot reliably be identified as the same history.

The **Last scan** section in Costs settings shows included, partial, missing, duplicate, or unavailable history.
When a T3 server is offline, its last usable snapshot for that period and timezone
is retained with a timestamp. Stale snapshots can miss new activity and boundary
hours; empty unknown chart periods are marked as unavailable. Session counts are
omitted when stale summaries cannot provide an accurate count. No app or provider
filter is needed: all enabled cost sources contribute together.

Costs does not read CLIProxyAPI or Keeper. Keeper remains optional for the quota
menubar’s last-used account feature; see [deployment](keeper-deployment.md).

For standalone quota backend use, `--source cliproxy`, `--cliproxy-url`, and `--cliproxy-key-file` are available. `CLIPROXY_API_URL` supplies the URL when the CLI flag is omitted, and `CLIPROXY_API_KEY_FILE` supplies the key path when neither the widget nor the CLI sets one. Keys are never passed as command-line arguments or saved in widget settings.

No credential is printed or included in display errors. T3 access tokens are cached in separate private authentication files; usage snapshots contain only accounting metadata and hashed folder identities. State is XDG-aware: the plugin directory uses mode `0700` and its files use `0600`.

```text
${XDG_STATE_HOME:-~/.local/state}/omarchy/model-usage/history.json
${XDG_STATE_HOME:-~/.local/state}/omarchy/model-usage/cost-scan-cache.json
${XDG_STATE_HOME:-~/.local/state}/omarchy/model-usage/cost-model-rates.json
```

`history.json` contains bounded quota percentages. The cost scan cache contains only timestamps, model names, token counters, reported cost values, SHA-256 identifiers for transcript paths, sessions, and deduplication keys, and bounded resume metadata (byte position, device/inode, hashed tail guard, and sanitized Codex parser state). It never contains prompts, responses, or tool output. The model-rate cache is a compact copy of public LiteLLM prices.

## Settings

Open the popup and click the **gear icon** beside Refresh to configure Model Usage. The Limits gear configures quotas and appearance; the Costs gear configures history sources and model prices. Both remain available when no providers are enabled. The fixed footer keeps **Cancel** and **Save changes** visible while scrolling. Saving writes your changes to the widget's entry in `~/.config/omarchy/shell.json` and applies them immediately; **Cancel** or Escape discards the draft.

Under **Limits → gear → Display**, **Square usage cards** is enabled by default for account, limit, credit, and error cards. Turn it off to follow the theme's corners. Click **Save changes** to apply it.

In local CLI mode, each provider has two controls: **Monitor** enables quota checks and includes it in the popup; **Menu bar** allows its percentage chip in the bar. Choose **Provider percentages** under **Menu bar display** to show those chips. Hiding a provider from the bar keeps it available in the popup. The widget icon remains accessible when all chips are hidden, on vertical bars, or when no selected provider has quota data.

In CLIProxyAPI mode, all discovered providers are monitored automatically; the provider list controls their menu-bar visibility. The Monitor column is hidden in this mode. Choosing **Widget icon** hides the menu-bar provider controls while preserving your selections.

Quota source and menu-bar display use compact dropdowns. Configured connections, optional last-used account tracking, refresh and alerts, and diagnostics sit in expandable sections. Refresh intervals are entered in minutes (1–60). Saved credentials show a **Change** action; blank replacements retain the existing secret, which is never loaded into the form. Non-secret settings are also declared in `manifest.json` and can be changed using `omarchy bar set`.

Costs settings keeps local history switches visible and collapses **Remote T3 servers**, **Custom prices**, and **Last scan**. Adding a server or price opens and focuses its editor; validation opens the relevant section and focuses the field needing attention.

In **Costs → gear → Custom prices**, add the exact model ID and its input/output prices in **USD per million tokens**. Model IDs in the Costs breakdown are selectable for copying. Matching preserves case, provider prefixes, and bracketed variants. Cache-read and cache-write prices are optional; blank fields use the input price, while `0` explicitly means free. Save applies the prices immediately to recorded activity, including offline or otherwise unknown models. Remove a price row and Save to restore automatic pricing. Cancel discards edits.

| Key | Default | Meaning |
|---|---:|---|
| `refreshIntervalSec` | `900` | Automatic refresh interval; clamped to 60–3600 seconds |
| `enabledProviders` | all three | Local CLI providers queried and displayed; proxy discovery is automatic |
| `usageSource` | `direct` | `direct` CLI sign-ins or `cliproxy` managed accounts for quotas |
| `cliproxyUrl` | `http://127.0.0.1:8317` | CLIProxyAPI server or management URL |
| `cliproxyKeyFile` | empty | Set automatically when saving a key in the GUI; can also point to an existing private key file |
| `hideAccountEmails` | `true` | Replace account identities with numbered labels and hide them in settings |
| `squareUsageCards` | `true` | Use square corners for cards in Limits; otherwise follow the theme |
| `barDisplayMode` | `Percentages` | `Icon` or compact `Percentages` |
| `barProviders` | all three | Enabled providers allowed to show percentage chips; independent of popup visibility |
| `warningThreshold` | `25` | Mark urgent at or below this percentage remaining |
| `criticalThreshold` | `10` | Critical threshold in percentage remaining |
| `costPriceOverrides` | `"{}"` | JSON string managed by Custom model prices; exact IDs mapped to USD-per-million rates |
| `costLocalProviders` | `["claude", "codex"]` | Local cost sources, independent of quota providers |
| `costKeeperUrl` | empty | Optional Keeper URL for last-used quota account activity |
| `costT3Servers` | `"[]"` | T3 server configurations managed in Costs settings; credentials are private file references |
| `costKeeperPasswordFile` | empty | Private Keeper password for quota account activity (legacy setting name) |

Examples:

```bash
omarchy bar set digitalpals.model-usage refreshIntervalSec 300 --json
omarchy bar set digitalpals.model-usage enabledProviders '["claude", "codex"]' --json
omarchy bar set digitalpals.model-usage barDisplayMode Percentages
omarchy bar set digitalpals.model-usage warningThreshold 20 --json
omarchy bar set digitalpals.model-usage criticalThreshold 5 --json
```

New installations use `Percentages`: one compact provider-logo chip per provider with meaningful limits, followed by its binding window's remaining percentage. Clicking a chip opens that provider directly. Left and right bars automatically fall back to the icon presentation so the widget does not become excessively tall.

## Troubleshooting

**The panel asks me to sign in.** Run the exact command displayed for that provider, then press `r`. This plugin will not repair credentials itself.

**Codex reports unavailable.** Confirm `codex` is on `PATH` and `codex login` succeeds. The collector uses current app-server RPC with `-s read-only -a never`; it does not call the older private web endpoint.

**Kimi does not appear.** Confirm `kimi login` has created `~/.kimi-code/credentials/kimi-code.json`, or set `KIMI_CODE_HOME` to the CLI's actual data directory.

**CLIProxyAPI reports configuration required.** Check the server URL, enter the Management API key in settings, and check the server's remote-management policy. If using a manually configured key file, check its path and permissions. HTTP 404 can mean the management API is disabled. For an expired managed provider sign-in, sign in again through CLIProxyAPI and refresh the widget.

**History is empty.** History begins after the first successful limit fetch. Errors are not recorded as zero usage.

**Costs are unavailable but tokens appear.** The transcript was readable but its historical model could not be matched to a price, or the LiteLLM table has never been downloaded successfully. Connect and refresh Costs, configure an exact-model custom price, or use the Tokens metric; unknown prices are intentionally not displayed as zero. Invalid custom-price settings produce an error and preserve the last good result rather than silently falling back to different prices.

**The first Costs scan is slower.** A cold scan streams recent transcript files. Later scans reuse unchanged files and read only the appended bytes of growing sessions. Replaced, shortened, or detected rewritten files restart from the beginning. The first scan after this upgrade rebuilds old scan and price caches; stale flattened prices are never reused.

**T3 is unavailable.** Open **Costs → gear → Last scan** and hover the source status for details. Check its base URL, connection token, and usage contract version. A saved snapshot is labeled with its last update time; no snapshot means unavailable history, not zero usage.

**The backend cannot start.** Python 3.10 or newer must be available as `python3`. The backend uses only the Python standard library.

**I see two AI widgets.** `digitalpals.model-usage` and `omarchy.agents` are intentionally independent. Disable whichever one you do not want.
