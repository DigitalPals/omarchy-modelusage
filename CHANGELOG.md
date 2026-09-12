# Changelog

All notable changes to this project will be documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases use
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/DigitalPals/omarchy-modelusage/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/DigitalPals/omarchy-modelusage/releases/tag/v1.1.0
[1.0.0]: https://github.com/DigitalPals/omarchy-modelusage/commit/1ac7f411a75fd84bf63d8005fdefbb8867d642f4
