# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.1.1 and later on the 1.1.x line | Yes |
| 1.1.0, 1.0.x, and earlier | No; update for hardened private-state writes |

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
Usage caches contain no prompts, responses, tool calls, tool results, or credentials.
T3 access tokens are stored separately in private authentication state files.
Incremental scan positions retain bounded numeric file identity/offset metadata, a SHA-256 tail guard, and sanitized parser state; they never retain the raw guard bytes. Custom prices are non-secret, validated settings bounded to 64 KiB and 128 models.

Private-state writes and management-key staging traverse every directory component
from the filesystem root using `O_DIRECTORY | O_NOFOLLOW`. Ancestors must be owned
by root or the current user and not writable by other users/groups; root-owned
sticky ancestors such as `/tmp` are allowed. The final directory must belong to
the current user and be `0700`. For JSON state only, an owned directory with full
owner access and no group/other write access can be tightened to `0700` through
its validated descriptor. Ancestors, symlink targets, foreign directories, and
writable-by-others directories are never chmodded. Key staging requires an already
private leaf or creates a new one. Symlinked XDG directory paths and `..` traversal
are rejected rather than resolved.

JSON temporary files use unpredictable names, exclusive no-follow creation, and
mode `0600`. Creation, replacement, and failure cleanup are relative to the same
open directory descriptor; file data and the containing directory are synced.
Replacing an existing symlink or hard-link entry does not open or modify its
referent. A renamed directory stays pinned, so replacing a pathname with a symlink
cannot redirect the write, permission change, or cleanup. This does not isolate
the plugin from another process already running as the same user or as root.

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
