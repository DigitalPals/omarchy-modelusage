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

- Claude Code CLI available during validation: `2.1.239`
- OpenAI Codex CLI available during validation: `0.149.0`
- Kimi Code normalization and transcript support validated against fixtures from
  the pinned `MoonshotAI/kimi-cli` revisions below; a live Kimi sign-in was not
  available on the validation machine.

Quota APIs and local transcript formats are provider-owned interfaces. The
fixture suite pins representative payloads so format drift produces a focused
compatibility update instead of silent fabricated data.

Reference implementations inspected during development:

- DigitalPals/fedora-config: `6aa074432f36548381ead91ed39d57c34529e327`
- MoonshotAI/kimi-cli quota APIs: `d723cc47ee43e5ca3c3c4ec2473f205d44acede2`
- MoonshotAI/kimi-cli wire usage: `cbc15c076d17f70fec9f89c90c0502e68657f505`
- pingdotgg/t3code: `afa83098064e7dca524a1e42dea3de03a883a0b6`
- BerriAI/LiteLLM public model-price schema, fetched at runtime
