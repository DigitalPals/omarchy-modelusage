# Optional CLIProxyAPI account activity

The widget supports CPA Usage Keeper **v1.15.4**, tested with CLIProxyAPI
**7.2.158**. Keeper runs on the proxy host and stores events in SQLite; the
desktop reads its authenticated last-request summary. No proxy binary changes are needed.
Keeper is an external dependency, not vendored into this plugin.

## Install on the proxy host

1. Download the appropriate asset from the [v1.15.4 release](https://github.com/Willxup/cpa-usage-keeper/releases/tag/v1.15.4)
   and verify its SHA-256 before running it. The Linux amd64 archive is
   `cpa-usage-keeper_v1.15.4_linux_amd64.tar.gz`, SHA-256
   `f0170a40dacc63ef05a60479eca3b1898dacfb81ab44ba884a727b3ab95ec565`.
   Install the executable as `/opt/cpa-usage-keeper/releases/v1.15.4/cpa-usage-keeper`
   and point `/opt/cpa-usage-keeper/current` at `releases/v1.15.4`.
2. Create the system account `cpa-usage-keeper` with home
   `/var/lib/cpa-usage-keeper` and no login shell. Install
   [the service unit](../deploy/keeper/cpa-usage-keeper.service) under
   `/etc/systemd/system/`.
3. Adapt [keeper.env.example](../deploy/keeper/keeper.env.example) into
   `/etc/cpa-usage-keeper/keeper.env`, owned by root with mode `0600`.
   Set the existing proxy management key and a separate random Keeper login
   password. Keep authentication enabled. Keeper handles both secrets; they
   must not be stored in this repository. `usage-statistics-enabled` must be
   true in the proxy configuration.
4. Set `CPA_BASE_URL` and the TLS-enabled `REDIS_QUEUE_ADDR` to the internal
   proxy listener. Use a certificate-valid name and trusted CA. If needed,
   `SSL_CERT_FILE=/etc/cpa-usage-keeper/ca.crt` supplies the internal CA while
   the OS certificate directories continue to supply public roots.
   Keep `TLS_SKIP_VERIFY=false`.
5. Enable the service with `systemctl daemon-reload` and
   `systemctl enable --now cpa-usage-keeper`. Its state directory and files are
   private, writable only by its service account.
6. Expose the loopback HTTP listener through an authenticated, HTTPS reverse
   proxy. For the provided `/keeper` base path, Tailscale Serve can use:

   ```bash
   tailscale serve --bg --set-path=/keeper http://127.0.0.1:8320/keeper
   ```

   Save the existing Serve configuration first. This adds a path to the
   existing HTTPS endpoint. The widget URL is then
   `https://<proxy-tailnet-name>/keeper`.

Use root or `sudo -n` for the host installation commands as appropriate.

## Collection and retained history

Keeper subscribes to CPA's usage stream and backfills the remaining queue on
startup. Multiple collectors must use subscription mode; mixing subscriptions
and destructive queue polling can lose data. The widget only calls Keeper's
account-activity API. Do not add a second desktop poller for `/usage-queue`.

Long-lived subscriptions should bypass connection admission gates that wait
for clients to disconnect before updating the proxy. On John's installation,
the gate listens on 8317 and the internal TLS proxy listens on loopback 8318.
The certificate's DNS name `cli-proxy.home.arpa` resolves to loopback on that
host for Keeper; the provided internal CA is verified. Proxy updates may
disconnect the subscription; Keeper reconnects automatically.

The database is `/var/lib/cpa-usage-keeper/data/app.db`. Scheduled SQLite
backups are enabled; Keeper's defaults retain seven days of backups. Its own
retention policy governs archived events; the widget queries the latest request by identity. Use Keeper's
SQLite backup mechanism or stop Keeper before a filesystem copy; do not copy
only a live main database file while its WAL is active. Back up Keeper's
configuration and state privately. Keeper's database also contains its own
credential and management metadata; the desktop imports only matched account identifiers and timestamps.

An enabled collector cannot reconstruct already-expired history. On initial
deployment, 30 pending requests were recovered from the one-hour proxy queue;
all subsequent observed requests were persisted. A Keeper service restart was
verified to retain the existing 64 events and resume collection.

## Configure and verify the widget

In **Limits → gear**, configure CLIProxyAPI and the optional Keeper URL and
login password for that same proxy. Save, choose percentage menubar mode, and
hover a provider to inspect its last-used account and request timestamp. This
integration is independent of Costs; Costs uses local/remote transcript sources.

Check `systemctl is-active cpa-usage-keeper` and its journal. A healthy
subscription reports `subscribe_receiving`/`subscribing`; the archive's
`/api/v1/status` reports the running collector. Verify increasing database
event counts during real proxy traffic and preserved counts after a service
restart. Check the configured timezone matches the intended deployment.

## Rollback and maintenance

Clear the optional Keeper URL to stop account-activity polling. To stop
collecting, disable the Keeper service with
`systemctl disable --now cpa-usage-keeper`; retain its database for history.
Remove only the added `/keeper` reverse-proxy route, preserving the proxy's
existing root route. On John's host, pre-install Serve and hosts snapshots
are stored under `/etc/cpa-usage-keeper/`; restore only this deployment's
changes if those shared configurations have subsequently changed.

Upgrade Keeper independently of the proxy, with a database backup and the
contract tests first. The integration depends on its last-request summary,
cookie login/logout, and collector status APIs.
