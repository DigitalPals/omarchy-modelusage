# Changelog

## Unreleased

- Make Costs follow Limits: when Limits reads a Fusebox server, Costs show its usage history (everything sent through that Fusebox, from any computer) without a separate switch. Until the server is detected, one without usage history is skipped quietly; a detected CLIProxyAPI is not asked. **Changes totals on upgrade:** “Include Fusebox usage” was off by default, so its saved “off” cannot be told apart from never touched, and every installation now follows Limits. To keep only this computer's history, choose **This computer** under **Cost history from** in the Costs tab.
- Merge the two settings pages into one with **Limits** and **Costs** tabs, opened at the current view's tab by the gear or `s`. Edits survive switching tabs, a dot marks a tab with unsaved edits, and one Save writes both tabs and all their credentials in a single transaction; if the other tab needs attention, Save opens it and focuses the field. The IPC `configure` and `configureCosts` open the Limits and Costs tabs.
- Replace “Include Fusebox usage”, “Use the Limits connection” and “Use Fusebox instead of transcripts” with **Cost history from** (Fusebox or This computer), an **Add providers only Fusebox records** switch for This computer, and a collapsed **Different Fusebox server**. The setting `costHistorySource` (`auto`, `local`, `mixed`) replaces `costFuseboxEnabled` and `costFuseboxOverlap`, which the next Save removes. While Fusebox supplies costs, this computer's switches and T3 servers are dimmed as not used. Rename **Quota source** to **Read limits from** and **Connection details** to **Connection**, now summarized with the server's host.
- Name the source under the Costs total (“From Fusebox · host”, “From this computer”); clicking it opens the Costs tab. When Fusebox cannot be read, Costs say so with the reason and that this computer's history is shown instead, rather than only “Unavailable: Fusebox”. **Last scan** shows why each source is not included as text, not only in a tooltip, and the empty state no longer says “transcript”.
- On Fusebox, **Test connection** also checks the usage history Costs read and reports it on a second line (available, turned off, stopped, or an older Fusebox). For a different Costs server, missing usage history fails the test.
- Report which family supplied the totals in the cost payload's `source` (`fusebox`, `transcripts` or `mixed`) instead of always `transcripts`.
- Show the Muse logo on Meta cards and menu-bar chips instead of a plain “M”.
- Show every provider at once in Limits instead of choosing one from a provider menu: one card per provider, in menu-bar order. A percentage chip opens Limits scrolled to its provider's card, and middle click, `h`/`l` and Left/Right jump between cards; `p` is gone.
- Fit each account on one line: name, meter, percentage left and reset countdown, in a name column shared by every card so meters line up. A plan every account shares heads the card once, and differing plans are tagged on each line. Hover a line for the plan, every limit with its reset time, renewal, credits, banked resets and sessions; **Details** (`a`, formerly **Additional limits**) shows the same inline. A tighter shorter limit gets an indented line, and cooldowns and errors stay visible under the account.
- Show banked resets as a flat button in the last column of the account line (the bar font's restore glyph and the count), only when there are resets to apply; every line keeps the column so percentages stay aligned, and the tooltip still names the count, including zero. Session counts use the same glyph-and-number style at the edge of the name column, and a disconnected live stream is one line above the cards instead of “Sessions unknown” on every account. Account names (emails) stay on one line and shorten in the middle.
- Show local CLI limits as one line per window, credits as a line with their balance or cap meter, and each provider's quota history behind a **Quota history** toggle. Long model limit names wrap to a second line rather than losing the ending that tells them apart.
- Replace `AccountCard.qml`, `LimitCard.qml` and `CreditsCard.qml` with `ProviderCard.qml`, `AccountRow.qml` and `UsageRow.qml`; card titles, plan tags, tooltip and Details text live in the node-tested `UsageLogic.js`. Re-render the README Limits screenshots from the test fixtures.
- Refresh the reading when a reset time passes even while the panel is closed, so the menu bar does not keep a spent limit until the next scheduled refresh.
- Treat one last-known account as a stale reading: the pool chip shows `?`, the icon turns urgent, and the tooltip uses the provider's own explanation (a failed refresh or an old Fusebox quota cache). The footer adds “some readings are last known” instead of looking fresh during an outage.
- Mark a cost source partial when complete transcript lines with usage are malformed, and say how many were skipped; a growing file's unfinished last line is still read again later. Note a partial estimate neutrally whenever some responses are unpriced.
- Redact camelCase credential names (`clientSecret`, `refreshToken`) and bare tokens with well-known shapes (`sk-…`, `ghp_…`, `xoxb-…`, JWTs) from displayed errors.
- Show the actual default key path, including `XDG_CONFIG_HOME` and `CLIPROXY_API_KEY_FILE`, in Costs settings; keep a number with its unit and a `·` with the preceding word when limit names wrap; keep `a` working while additional limits are expanded.
- Refresh the README panel screenshots, rendered from the test fixtures.
- Show a warning-level or spent shorter window, such as a used-up 5-hour limit, first on compact account cards when it is tighter than the weekly allowance. **Additional limits** sits above the cards, toggles with `a`, and appears only when it reveals more.
- Wrap long limit names instead of cutting off the part that tells similar limits apart.
- Keep failed providers in the menu bar as a `!` chip with the error in the tooltip, and mark last-known readings kept through a proxy outage as `90%?`. Both count as urgent in icon mode, so an expired sign-in or offline proxy is visible without opening the panel.
- Fill extra-usage and credit meters with what is left, like every quota meter (“Monthly limit · 75% left”). Show a prepaid Kimi wallet's balance separately from its monthly charge cap, give money two decimals everywhere, and label currency-less amounts as credits. Codex reset credits read as banked resets, as on account cards.
- Name partial, offline-snapshot, and unavailable cost sources under the Costs total; show the chart peak; put the empty state above the chart and hide empty sections.
- Render secondary text as the theme foreground at reduced opacity, so light themes keep the same hierarchy as dark ones.
- Refresh once when a reset time passes, instead of showing “Resets in now”, and say “awaiting a new reading” rather than “updating” when no refresh is running; show “Next refresh in 10m” instead of a countdown that read like a clock time; read full footer errors in a tooltip; show each loading message once.
- Make `s` open the settings for the current tab, add `[`/`]` for the Costs period and Limits history range, and add a `?` legend that lists only the keys that work in the current view. Label quota history as per-hour/per-day peaks and write Costs chart dates like Limits (“Nov 12”). Use the same underline tabs for every range control and the card-corner setting for Costs surfaces too.
- Show an unavailable banked reset as plain text rather than a disabled-looking button; fix “1 connected accounts” and “Use 1 of 1 available resets”.
- Allow Fusebox costs through the Limits connection when Limits uses the default key file.
- Warn in settings when a key or token would be sent over plain `http://` to another computer (numeric loopback and `localhost` only are exempt), and redact generic secret names (`password`, `token`, `client_secret`, URL credentials) from displayed errors.
- Qualify Omarchy's `Color` singleton as `Commons.Color`, matching current Omarchy: Qt 6.12's QtQuick adds its own `Color` singleton, which otherwise hides Omarchy's palette.
- Move the account, limit and credit cards out of `Panel.qml` into their own components, and move formatting, severity and window selection into the node-tested `UsageLogic.js`.
- Run qmllint, every QML contract and the headless Wayland runtime contract in CI on the pinned Qt/Quickshell/Omarchy stack (`tests/ci-qml`); `MODEL_USAGE_REQUIRE_QML=1` turns skipped QML checks into failures. Fix the live runtime test for the read-only activity providers and make private-state tests independent of the umask.

- Reuse the Limits connection for Fusebox costs by default: enabling **Include Fusebox usage** no longer needs the URL and key a second time. Costs settings saved with their own URL keep it, and **Use the Limits connection** can be turned off for a different server.
- Add **Test connection** to Limits and Costs settings. It names the detected implementation and counts accounts and providers, or explains a rejected key, an unreachable server, or a URL without a management API, all before saving. Unsaved keys are passed privately, never as process arguments.
- Probe Fusebox's account API first and pass the detected implementation to later refreshes, activity, live and reset processes, so Fusebox refreshes no longer start with a failed CLIProxyAPI request. A server replaced behind the same URL is still detected.
- Show only the settings the detected server uses: Fusebox hides the CPA Usage Keeper fields; CLIProxyAPI hides the live activity switch.
- Share one connection module across all backends, so URL handling, private key files and redirect rejection behave identically. Keys with spaces saved in settings now also work for Fusebox costs.
- Rename settings to `usageSource: proxy`, `proxyUrl`, `proxyKeyFile`, `keeperUrl` and `keeperPasswordFile`, and backend flags to `--source proxy`, `--proxy-url` and `--proxy-key-file`. Earlier names are still read, and the next Save migrates them.
- Fix the reset QML contract check, which required a retry request to match the original exactly, including its retry flag.

## 1.4.0

- Read Fusebox's full account snapshot: Meta and Antigravity quotas, model-scoped and spending limits, Claude extra usage, Codex credits, Claude Pro/Max/Ultra and ChatGPT Pro tier names. Feature allowances such as Code review and Cowork are informational and never drive the menu bar or warnings.
- Show Fusebox account facts on each card: renewal date, no 5-hour limit, cooldown countdowns, paused usage checks, inactive subscriptions, session priority, resets awaiting review and the last error (emails masked). A rejected sign-in now reads as sign-in expired.
- Apply Claude and Codex banked resets through Fusebox's reset journal, with Fusebox's recommended grant first, its refusal reasons shown, and retries that never spend twice.
- Add an opt-in Fusebox Costs source using Fusebox's own API-price estimates, with an explicit choice between Fusebox and transcript history so the same CLI requests are never counted twice. Show Meta, Antigravity, Grok and other Fusebox providers as their own cost buckets.

## 1.3.2

- Name the Rust integration Fusebox in settings, quota diagnostics and account notices. Add a keyboard-accessible link to the Fusebox repository in Limits settings.
- Keep saved connection keys and Go CLIProxyAPI support compatible.

## 1.3.1

- Restore quota-only menubar chips. Show Fusebox's session count in the upper-right of account cards, aligned with the subscription title.
- Keep session details accessible by click, hover and keyboard; unknown counts remain explicit during disconnects. Remove obsolete menubar and separate recent-session settings. No server changes required.

## 1.3.0

- Add shared Fusebox live account activity, static bar counts, serving request badges and optional recent sessions. Preserve quota and last-used selection through disconnects; clear live counts to unknown.
- Bound stream parsing, heartbeat expiry and reconnect backoff; keep Go/Keeper polling compatible.

All notable changes to this project will be documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-10-03

### Added

- Detect CLIProxyAPI-Rust automatically with the existing management key. Read
  cached Claude/Codex quota windows and native last-used account timestamps.
  Keeper is optional only for Go proxy activity; Rust activity works without it.
- Preserve OAuth filename account hashes and quota observation timestamps.
  Show missing/stale quota data explicitly, avoid recording unchanged cached
  observations as fresh history, and disable unavailable Rust banked resets.


## [Unreleased]

## [1.1.1] - 2026-09-13

### Security

- Traverse every state/config directory component with no-follow descriptors,
  validate ownership and permissions, and create missing directories relative to
  the validated parent. Reject symlinks, foreign owners, parent traversal, and
  directories writable by other users or groups.
- Create, flush, replace, and clean up JSON state through a pinned directory
  descriptor. Existing owned read-only-to-others state directories are tightened
  through `fchmod`, never a pathname. Link targets are never opened or chmodded.
- Apply the same directory traversal to management-key staging. Add regression
  coverage for ancestor/leaf symlinks, directory-swap races, hostile permissions
  and ownership, temporary-file collisions, failed writes, and concurrent writers.

### Fixed

- Use Python 3.10-compatible context cleanup in the T3 cost tests so the portable
  CI matrix also runs on the oldest supported Python version.

## [1.1.0] - 2026-09-12

### Changed

- Simplified Limits/Costs navigation with tabs and a provider menu, expandable
  token/model details, and separate quota and cost settings with fixed Save/Cancel
  controls. Usage cards default to square corners with a theme-corner option.
- Refreshed the README and screenshots, documented exactly which activity and
  token categories count, and moved detailed setup/development reference into docs.
- Expanded the marketplace description and replaced its preview with a composition
  of the menu bar, three Codex subscriptions, and combined local/T3 Costs.

### Added

- Accept transcript lines up to 16 MiB so large tool outputs do not discard otherwise readable session usage. File and scan limits remain bounded.

- Dedicated Costs settings for local Codex/Claude history and up to four remote
  T3 Code servers, included automatically with private connection tokens.
- Combined source pricing, folder deduplication, visible source status, and
  private offline T3 snapshots. Removed proxy cost history and app filters;
  Keeper remains available for last-used quota account tracking.
- Last-used CLIProxyAPI account quotas in the percentage menubar, with account
  details in tooltips and independent 15-second Keeper polling. Missing activity
  falls back to the known pool quota.

- Custom model prices in settings with exact-ID matching, optional cache rates,
  explicit zero prices, Save/Cancel, and visible cost provenance.
- Manual Costs refresh can update the public price table before its daily TTL,
  with a one-minute minimum between successful downloads.
- Incremental transcript scanning with guarded resume positions, persisted Codex
  state, provisional EOF handling, and existing privacy and resource limits.
- Clickable Codex banked resets in CLIProxyAPI mode, with account-specific
  confirmation, expiry-ordered credit selection, and idempotent retry handling.

- Proxy Limits now shows all connected accounts together with separate quota
  cards, automatic provider discovery, weekly limits by default, and Codex Pro
  20×/5× plan labels.
- Hide account emails setting, enabled by default, with numbered account labels.
- Antigravity model-group quotas, Codex code-review windows, explicit paused and
  unsupported states, and last-known readings with stale refresh notices.
- Gear-accessible settings menu with Save/Cancel, CLIProxyAPI configuration,
  monitoring and menu-bar visibility controls for each provider, display mode,
  refresh interval, and quota warning thresholds.
- Masked Management API key input with automatic private storage, key replacement,
  and preservation of the existing key when the field is left blank.
- CLIProxyAPI quota source for managed Claude, Codex, and Kimi accounts, with
  server/key-file settings, multi-account capacity selection, partial-check
  notices, and separate per-server history. Local transcript costs remain independent.

### Fixed

- Keep quota and account-activity refreshes serialized during process startup,
  and discard responses from the previous connection when settings change.
- Avoid a redundant transcript scan when opening Costs triggers multiple view
  notifications.
- Honor explicit custom prices for otherwise ambiguous model IDs such as
  `sonnet`, `opus`, and `haiku`.
- Count distinct Codex responses with identical token usage when cumulative
  counters advance. Rebuild older transcript caches with the corrected logic.
- Isolate malformed numeric transcript records and damaged scan caches, and
  keep successful Claude quota readings when optional account metadata is
  oversized or unreadable.

- Preserve canonical and provider-qualified prices instead of allowing reseller
  entries to overwrite rates. Ambiguous aliases remain unpriced; bracketed model
  variants use clearly identified base-rate estimates.
- Rebuild obsolete flattened price caches and preserve exact nanosecond mtimes
  so unchanged transcripts reliably reuse their scan cache.
- Preserve refresh requests during process startup and coalesce queued settings
  and forced-price changes into one follow-up scan.

### Security

- Reject redirects on direct provider requests so sign-in tokens cannot be
  forwarded, and avoid displaying raw unexpected collector exception details.

- Bound provider HTTP and local JSON inputs, and replaced Codex RPC `readline`
  handling with a deadline-aware incremental reader capped per message.
- Stream and cap recurring QML backend output while discarding stderr instead
  of retaining complete process streams in the long-lived shell.
- Bound transcript line/file/scan sizes, per-file and total usage records,
  persisted scan caches, model names, and output model groups; limit breaches
  now produce explicit partial/failed coverage instead of unbounded growth.

## [1.0.0] - 2026-08-23

### Added

- Omarchy-native quota monitoring for Claude Code, OpenAI Codex, and Kimi Code.
- Persistent 24-hour and seven-day quota history.
- On-demand local transcript scanning with 24-hour, seven-day, and 30-day
  token activity and API-equivalent cost estimates.
- Failure-isolated provider collection, private XDG state, offline price-cache
  fallback, and explicit partial/unavailable pricing states.
- Keyboard navigation, namespaced IPC, compact percentage chips, and support
  for horizontal and vertical bars.
- Fixture, contract, QML lint, and live Quickshell runtime tests.

[Unreleased]: https://github.com/DigitalPals/omarchy-modelusage/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/DigitalPals/omarchy-modelusage/releases/tag/v1.1.1
[1.1.0]: https://github.com/DigitalPals/omarchy-modelusage/releases/tag/v1.1.0
[1.0.0]: https://github.com/DigitalPals/omarchy-modelusage/commit/1ac7f411a75fd84bf63d8005fdefbb8867d642f4
