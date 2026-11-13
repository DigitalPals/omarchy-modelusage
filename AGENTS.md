# Working on Model Usage

## How to answer

- Always answer concisely and in plain English: short sentences, everyday words, the answer first. Leave out filler,
  jargon and long lists unless someone asks for more detail.

## Apply changes to the live widget

This checkout is the installed Model Usage plugin on John's computer:

```text
~/.config/omarchy/plugins/digitalpals.model-usage
  -> /home/john/Code/omarchy-modelusage
```

The plugin consists of QML, JavaScript, and Python. There is no plugin binary
to compile. Updated files on disk do not prove that the running QML engine has
loaded them.

For changes intended for the installed widget, complete implementation,
appropriate validation, live application, and runtime verification before
reporting success. Batch edits before restarting. If the user explicitly asks
for code-only work or no restart, respect that and state that the running UI
has not been updated.

### Reliable procedure on this machine

1. Confirm that the installed plugin resolves to the checkout being edited:

   ```bash
   readlink -f ~/.config/omarchy/plugins/digitalpals.model-usage
   ```

   If it is a separate copy or points elsewhere, resolve the installation
   mismatch first; do not assume that editing this checkout changes that copy.

2. Finish the changes and run `fast-test` (see Testing below): Python and JS
   tests run here, QML lint and the QML contracts on The Beast. For a small
   presentation-only change, also inspect the live result. The optional `MODEL_USAGE_LIVE_TESTS=1 ./tests/run` opens an
   isolated test instance; passing it is not proof that the desktop's running
   plugin was updated.

3. Record the current desktop shell PID, then use the supported restart command:

   ```bash
   pgrep -a -u "$(id -u)" -f '(^|/)quickshell .*-p /usr/share/omarchy/shell$'
   omarchy restart shell
   ```

   Use the active shell's config path if this installation changes. The Omarchy
   restart command handles the session environment, shutdown, launch, and
   readiness. Do not use `pkill quickshell`, start an extra shell by hand, or
   delete caches speculatively. Do not use `omarchy refresh shell`: that resets
   configuration and is not a restart. No root access is needed.

4. Confirm a different desktop shell PID and responsive IPC:

   ```bash
   pgrep -a -u "$(id -u)" -f '(^|/)quickshell .*-p /usr/share/omarchy/shell$'
   omarchy-shell shell ping
   quickshell ipc -p /usr/share/omarchy/shell show
   ```

   `ping` must return `ok`, and the IPC listing must include
   `digitalpals.model-usage`. These checks establish readiness, not correctness
   of the displayed change.

5. Reopen the affected view and verify the requested behavior in the actual
   desktop widget. For Costs:

   ```bash
   omarchy-shell digitalpals.model-usage costs
   ```

   Allow the panel to render and any scan to settle. For collector/pricing
   changes, refresh while Costs is selected:

   ```bash
   omarchy-shell digitalpals.model-usage refresh
   ```

   Visually inspect the panel or take and inspect a screenshot. Keep temporary
   screenshots out of the repository; crop away unrelated desktop content.
   For a removed UI element, verify its absence, rather than just checking
   that the plugin's IPC target exists.

6. Check the new instance's log for relevant load/runtime errors:

   ```bash
   quickshell log -p /usr/share/omarchy/shell --no-color -t 80
   ```

   Report only the application and verification that actually completed. If
   verification fails, investigate instead of claiming that a successful IPC
   call applied the change. Further QML/JS edits require another restart and
   verification after the final edit.

### Why saving or rescanning is insufficient here

Verified on 2026-09-12:

- `/usr/share/omarchy/bin/omarchy-launch-shell` starts Quickshell with
  `QS_DISABLE_FILE_WATCHER=1`.
- Omarchy's separate `inotifywait` plugin watcher watches
  `~/.config/omarchy/plugins`, but its registered watches did not include this
  checkout's directory behind the symlink.
- `omarchy-shell shell rescanPlugins` returned without an error, but did not
  reliably apply the edited nested `UsageCosts.qml` component. The subsequent
  IPC target check also did not establish that the visible component changed.
- A full `omarchy restart shell`, followed by reopening Costs, loaded the
  updated component. A screenshot confirmed the informational box was absent.

Use a full restart as the default for applying this plugin's QML/JS changes on
this setup. Rescanning is useful for plugin discovery, but is not sufficient
evidence of live code replacement. Do not rely on generic hot-reload guidance
when it conflicts with these observed results.

## Privileged commands

John has passwordless sudo. For authorized work that needs root, use `sudo -n`.
Use `pkexec` only if sudo explicitly requires password authentication and no
interactive terminal is available. Leave commands that handle their own
privilege elevation unwrapped. The plugin's collectors and shell restart do
not need root.

## Testing (fast testing)
- After a change, run `fast-test` in the repository folder. It tests only what changed since `main` (commits,
  staged and unstaged edits, new files): quick tests here on The Dragon, heavy ones (VMs, Nix, databases, wide
  changes) on The Beast by itself. `fast-test --dry-run` shows what it would run and why.
- Exit 0 passed, 1 failed, 2 couldn't run (say so; don't run the full suite here instead). When it fails, its output
  ends with the failing step's last lines; the whole log is in `.git/fast-test/`.
- Don't run the full test suite and don't wait for GitHub CI. `fast-test --full` runs everything on The Beast, only
  when someone asks for it.
- A failing test runs once more before it counts as failing (fast-test does this itself). Never skip or weaken a test
  to make it pass.
- Every night The Beast runs the full suite of `main`; failures are reported in the morning.
