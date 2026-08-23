# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.0.x | Yes |
| Earlier versions | No |

## Reporting a vulnerability

Please use a private
[GitHub security advisory](https://github.com/DigitalPals/omarchy-modelusage/security/advisories/new).
Do not include access tokens, refresh tokens, transcript contents, or other
credentials in a public issue, screenshot, or log.

Include the plugin version, Omarchy revision, provider CLI versions, expected
behavior, and a minimal reproduction using redacted or synthetic data. You can
expect an acknowledgement as soon as practical. Confirmed vulnerabilities will
be fixed on the latest supported release line and disclosed after a patched
release is available.

## Data and trust boundary

This plugin runs as the signed-in desktop user inside Omarchy's long-lived
Quickshell process. Its Python helpers read provider-owned credentials for
read-only quota requests and scan local usage metadata. They do not need root
access and should never be run with `sudo`.

Private state is stored below
`${XDG_STATE_HOME:-~/.local/state}/omarchy/model-usage/`. The directory uses mode
`0700`; files use mode `0600`. Transcript paths, session identifiers, message
identifiers, and de-duplication keys are hashed before they enter durable state.
Prompts, responses, tool calls, tool results, and credentials are not cached.
