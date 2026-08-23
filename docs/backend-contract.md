# Backend contract

`scripts/usage-fetch.py` writes a single JSON document to standard output. The UI accepts schema version 1 and treats anything else as an unreadable backend response.

This contract covers live subscription limits only. The on-demand transcript/cost view uses a separate process and [estimated-cost contract](cost-contract.md), so a scan or pricing failure cannot replace healthy quota data.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2030-01-01T00:00:00+00:00",
  "providers": [
    {
      "id": "codex",
      "name": "OpenAI Codex",
      "status": "ok",
      "errorKind": "",
      "message": "",
      "authCommand": "codex login",
      "plan": "ChatGPT Pro",
      "account": "user@example.invalid",
      "source": "Codex app-server RPC",
      "windows": [
        {
          "id": "codex-primary",
          "label": "5 hour limit",
          "used": 42.0,
          "remaining": 58.0,
          "resetsAt": 1893474000,
          "windowSeconds": 18000,
          "detail": ""
        }
      ],
      "credits": null,
      "notice": "",
      "fetchedAt": "2030-01-01T00:00:00+00:00",
      "history": {
        "h24": [0, 0, 42],
        "d7": [0, 42]
      }
    }
  ]
}
```

All provider records have the same keys, including error records. `status` is `ok` or `error`. Current `errorKind` values include `no_credentials`, `expired`, `cli_unavailable`, `rate_limited`, `timeout`, `network`, `http`, `rpc`, `malformed`, and `internal`.

Percentages are numbers in the inclusive range 0–100. `resetsAt` is a Unix timestamp in seconds or `null`. `windowSeconds` is the known window duration or `null`. Additional windows require no UI schema change.

History records the binding active quota window: the highest `used` percentage among the provider's current windows. This matches the compact remaining-percentage summary and prevents an idle model-specific window from hiding usage in another active window.

`credits`, when present, has this stable shape:

```json
{
  "label": "Extra usage",
  "currency": "USD",
  "used": 12.5,
  "limit": 50.0,
  "remaining": 37.5,
  "total": null,
  "unlimited": false,
  "resetCreditsAvailable": null
}
```

Unsupported or unavailable fields are `null`; they are not overloaded with sentinel strings. History arrays are pre-bucketed percentages so QML never has to parse or aggregate the bounded on-disk sample set.

## Resource ceilings

Provider HTTP bodies and local JSON inputs are read with a 2 MiB ceiling before parsing. An oversized HTTP response becomes a provider-local `malformed` error and cannot suppress healthy providers. Codex app-server output is read incrementally in bounded chunks with a 2 MiB ceiling per JSON-RPC line; the same request deadline remains active even when a line is incomplete.

`UsageBackend.qml` streams stdout into a buffer capped at 2 MiB and terminates the backend if that ceiling is crossed. Stderr is drained without retention. This keeps the recurring collector from growing the long-lived Quickshell process even if a backend or provider CLI misbehaves.
