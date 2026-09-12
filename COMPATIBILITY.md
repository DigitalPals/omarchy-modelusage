# Compatibility target

- Omarchy branch: `quattro`
- Omarchy commit: `2c247e390e357ae0fee3f8565b0c816adb705e6a`
- Development date: 2026-08-23
- Plugin manifest schema: 1
- Limit backend schema: 1
- Estimated-cost backend schema: 1

## Tested local runtime

- Omarchy package: `4.0.0-1`
- Qt Declarative / `qmllint`: `6.11.2`
- Quickshell: `0.3.0` (`28771c7c74b42e20afca0b1b63980cb46515537c`)
- Python: `3.14.7` locally; CI covers `3.10` through `3.14`
- Node.js test runner: `26.7.0` locally; CI uses Node.js 22

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
