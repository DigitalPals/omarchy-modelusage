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
quota requests, apply explicitly confirmed banked resets, and scan local usage metadata. They do not need root
access and should never be run with `sudo`.

Direct provider requests reject HTTP redirects and verify HTTPS certificates.
Unexpected collector errors use fixed display messages rather than raw exception
details, which can contain credential or account data.

Private state is stored below
`${XDG_STATE_HOME:-~/.local/state}/omarchy/model-usage/`. The directory uses mode
`0700`; files use mode `0600`. Transcript paths, session identifiers, message
identifiers, and de-duplication keys are hashed before they enter durable state.
Prompts, responses, tool calls, tool results, and credentials are not cached. Incremental scan positions retain bounded numeric file identity/offset metadata, a SHA-256 tail guard, and sanitized parser state; they never retain the raw guard bytes. Custom prices are non-secret, validated settings bounded to 64 KiB and 128 models.

In CLIProxyAPI mode, the plugin reads a user-owned management key file with
private permissions (default: `$XDG_CONFIG_HOME/omarchy/model-usage/cliproxy.key`,
where `XDG_CONFIG_HOME` defaults to `~/.config`). This user-provided credential
is separate from generated state. The key is sent only to the configured
management server; redirects are rejected and HTTPS certificates are verified.
Upstream provider tokens stay on CLIProxyAPI, which substitutes `$TOKEN$` for
quota calls and explicitly confirmed Codex banked-reset actions. Management responses and account checks are bounded.
The backend never downloads auth files or stores their raw metadata. The backend does not request client API keys or the model catalog.

Banked resets use fixed upstream URLs and explicit managed account selection.
The account identity is checked again before consumption. Each logical reset
attempt has a UUID reused for retries; automatic polling cannot consume a reset.
Reset credit IDs and pending retry state are held in memory, not quota history.

Account usernames and emails are hidden by default in the UI via `hideAccountEmails`.
The setting affects display only; account labels remain in the in-memory backend
payload so they can be shown when the user disables the setting.

The GUI accepts the management key in a masked field and passes it to the
storage helper over stdin, never argv, environment variables, logs, or
`shell.json`. The helper creates a `0600` file inside the private `0700`
`$XDG_CONFIG_HOME/omarchy/model-usage/management-keys/` directory. Only its path
is saved in widget settings. A failed settings update discards the staged file;
successful replacement removes the previous GUI-managed key file while leaving
manually configured files intact. Blank input preserves the existing key.
The form clears entered keys on Save, Cancel, or leaving settings, and never
reads stored keys back into the UI.
