# `limit-lifeboat` command line and JSON schema

`limit-lifeboat` ships inside the app (`Contents/Helpers`). Settings →
Command Line & Status Line links it into `~/.local/bin`.

| Command | Reads | Needs the app running |
| --- | --- | --- |
| `status`, `list`, `active` | the app's store | no |
| `history [--days N]` | the app's store | no |
| `sessions` | the process table and Claude Code transcripts | no |
| `statusline` | the store, plus Claude Code's stdin | no |
| `preflight` | the process table and system memory | no |
| `refresh [account-id]` | asks the app | **yes** |
| `switch <account-id>` | asks the app | **yes** |

The read commands never contact Anthropic or OpenAI and never write anything.
`refresh` and `switch` ask the running app to do the work over its control
socket (see [Control socket](#control-socket)). The CLI itself never reads or
writes a credential. Capture, rename and remove are only available in the app.

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success |
| 1 | Usage error (unknown command or option, bad id, `--days` out of range) |
| 2 | The store could not be read |
| 3 | `preflight`: memory is critically low |
| 4 | `refresh`/`switch`: the app is not running (`app_not_running`) |
| 5 | `refresh`/`switch`: the app could not do it (see `error.code`) |

## Schema versions

Every `--json` document carries `schema`. The current version is **2**.

- **Schema 1** covered `status`, `list` and `active`.
- **Schema 2** only adds things. It adds `issues` and `app` to those three
  (with `--detail`), and the `history`, `sessions`, `refresh` and `switch`
  documents. No schema 1 field was renamed, removed or given a new meaning.

**Upgrading from 1.1.x:** since Limit Lifeboat 1.2.0 the default `--json`
output is `"schema": 2`. Without `--detail`, `status`, `list` and `active`
print exactly the schema 1 keys, so a consumer that ignores unknown keys keeps
working unchanged. A consumer that checks for `schema == 1` must pass
`--schema 1`, which prints the exact schema 1 document (no `issues`, no `app`,
`"schema": 1`).
`limit-lifeboat version --json` prints
`{"version": "…", "schema": 2, "supportedSchemas": [1, 2]}`.

Dates are ISO 8601 in UTC (`2026-10-18T13:38:41Z`). Fields marked *optional*
are omitted when there is no value. They are never `null`.

## `status`, `list`, `active`

`list` is `status` without readings. `active` is `status` filtered to
`isActive` accounts. `--detail` adds the fields marked *v2, --detail*.

```jsonc
{
  "schema": 2,
  "generatedAt": "2026-10-18T14:00:00Z",
  "app": {                          // v2, --detail
    "running": true,                // the control socket answered just now
    "issuesUpdatedAt": "…"          // optional; when the app last changed account-issues.json
  },
  "accounts": [
    {
      "id": "37B6ABE1-…",           // stable account id (UUID); use it for refresh/switch
      "provider": "claude",         // "claude" | "codex"
      "label": "Work",
      "email": "…",                 // optional
      "organization": "…",          // optional
      "plan": "Max 20x",            // optional
      "isActive": true,             // the provider CLI is logged into this account
      "priority": 0,                // rank within its provider, 0 = first choice
      "reading": {                  // optional; absent when never read (and always for `list`)
        "risk": "healthy",          // healthy | warning | depleted | stale | unknown
        "mostConstrainedPercent": 67,   // optional; max usedPercent across windows
        "windows": [
          {
            "id": "weekly-all",
            "kind": "weekly",       // session | weekly | weeklyScoped | …
            "label": "Weekly (all models)",
            "usedPercent": 67,
            "risk": "healthy",
            "resetsAt": "…"         // optional
          }
        ],
        "lastRefreshed": "…",
        "ageSeconds": 120,          // check before trusting the numbers
        "source": "Anthropic usage API",
        "extraUsage": "…"           // optional; formatted overage spend
      },
      "issues": [                   // v2, --detail; [] when nothing is wrong; most severe first
        {
          "code": "needs_login",
          "severity": "error",      // info | warning | error
          "message": "…",           // user-facing; never contains credentials
          "source": "app",          // app = the app's last refresh state; store = derived by the CLI
          "since": "…",             // optional; when the app first saw this code
          "retryAt": "…"            // optional; when the app retries on its own
        }
      ]
    }
  ]
}
```

### Issue codes

| Code | Severity | Source | Meaning |
| --- | --- | --- | --- |
| `read_failed` | warning | app | A usage read failed. The last reading is kept and retried. |
| `rate_limited` | info | app | The provider is throttling usage requests. Heals on its own. |
| `rotation_deferred` | warning | app | Renewing the login was postponed. A refresh may continue it. |
| `usage_paused` | info | app | The access token expired while idle. A refresh renews it. |
| `switch_required` | warning | app | Shares the active login's token chain. Switch to it to renew. |
| `credential_repair_required` | error | app | A refreshed login was not saved everywhere. A refresh repairs it. |
| `provider_access_forbidden` | error | app | The provider denied the usage endpoint for this login. |
| `authorization_required` | error | app | macOS Keychain access must be granted in the app. |
| `credential_access_blocked` | error | app | Credential access is blocked (for example, a replaced build). |
| `keychain_locked` | error | app | The Keychain is locked or access was denied. |
| `needs_login` | error | app | The saved login can't be recovered. Log in again. |
| `no_reading` | info | store | No usage has been recorded for this account yet. |
| `stale_reading` | warning | store | The last reading is over 30 minutes old. |

App-sourced issues come from `account-issues.json`, which the app rewrites
whenever an account's refresh state changes. While `app.running` is false,
they are as of `app.issuesUpdatedAt`.

## `history --json [--days N]`

Saved-account usage history. `N` is 1 to 30, default 7. The app keeps 30 days.
The app records a reading only when a window's numbers change, so gaps between
records are not missing data.

```jsonc
{
  "schema": 2,
  "generatedAt": "…",
  "days": 7,
  "since": "…",                     // generatedAt - days
  "accounts": [                     // every saved account, status order
    {
      "id": "…", "provider": "claude", "label": "Work",
      "records": [                  // oldest first; [] when none in the window
        {
          "timestamp": "…",
          "windows": [
            {
              "id": "session", "kind": "session", "label": "Session (5h)",
              "usedPercent": 36,
              "resetsAt": "…",      // optional
              "windowMinutes": 300  // optional
            }
          ]
        }
      ]
    }
  ]
}
```

## `sessions --json`

The running Claude Code and Codex sessions, found the same way the app's
Sessions view finds them.

```jsonc
{
  "schema": 2,
  "generatedAt": "…",
  "providers": [                    // always both, claude then codex
    {
      "provider": "claude",
      "count": 2,
      "memoryBytes": 812345678,     // every session, including the tools/servers each started
      "sessions": [                 // oldest first
        {
          "pid": 41583,
          "provider": "claude",
          "project": "my-app",      // working directory's last component
          "workingDirectory": "/Users/…/my-app",   // optional
          "startedAt": "…",
          "memoryBytes": 420000000,
          "processCount": 3,        // the session and its descendants
          "model": "claude-opus-5-5",   // optional, Claude only
          "contextTokens": 389000,      // optional, Claude only
          "lastActivityAt": "…",        // optional, Claude only
          "idleSeconds": 180,           // optional, Claude only
          "cacheTTLSeconds": 3600,      // optional, Claude only
          "parked": {                   // optional; while the app has it parked
            "reason": "shortfall",      // manual | shortfall
            "parkedAt": "…",
            "releaseAt": "…"            // optional
          }
        }
      ]
    }
  ]
}
```

Memory pressure and room for more sessions stay in `preflight --json`, which
exits 3 when memory is critically low. Its document is the app's Memory Guard
state: `level` (`ok` | `caution` | `critical`), `availableBytes`,
`sessionFootprintBytes`, `message` and related fields. It does not change
with schema 2.

## `refresh` and `switch`

```bash
limit-lifeboat refresh --json                 # every account
limit-lifeboat refresh <account-id> --json    # one account
limit-lifeboat switch <account-id> --json
```

`refresh` with no id runs the app's normal refresh pass, or waits for the one
already running (`coalesced: true`). With an id, an account in a retryable
state (`read_failed`, `rotation_deferred`, `usage_paused`,
`credential_repair_required`) goes through the same workflow as its Retry
button. A healthy account is refreshed by a normal pass. `switch` runs the
app's switch workflow (provider gate, target preflight, rollback) as a
notification click does: no confirmation dialogs.

```jsonc
// success
{
  "schema": 2,
  "ok": true,
  "result": {
    "command": "switch",            // refresh | switch
    "accounts": [                   // refresh: the account(s) refreshed; switch: the target
      {
        "id": "…", "provider": "claude", "label": "Spare",
        "isActive": true,
        "lastRefreshed": "…",       // optional
        "ageSeconds": 4,            // optional
        "issues": []                // issue objects, as above (source "app")
      }
    ],
    "previousAccountId": "…",       // optional, switch
    "alreadyActive": false,         // optional, switch
    "coalesced": false              // optional, refresh
  }
}

// failure (exit 4 for app_not_running, otherwise 5)
{
  "schema": 2,
  "ok": false,
  "error": { "code": "app_not_running", "message": "Limit Lifeboat isn't running. Open Lifeboat, then try again." }
}
```

| `error.code` | From | Meaning |
| --- | --- | --- |
| `app_not_running` | CLI | No app is listening on the control socket |
| `insecure_socket` | CLI | The socket isn't a `0600` socket owned by you, or another user serves it. The CLI refused to use it. |
| `timeout` | CLI | No answer within 180 s. The app may still finish. |
| `protocol_error` | CLI | The connection closed early, or the response wasn't understood |
| `bad_request`, `unsupported_version`, `unknown_command` | app | The request was malformed |
| `account_not_found` | app | No saved account has that id |
| `busy` | app | Too many control requests at once |
| `needs_login`, `authorization_required`, `deferred`, `refresh_failed` | app | The refresh did not complete. `message` says why. |
| `switch_failed` | app | The switch did not happen. The previous login is unchanged or was rolled back. |

## Control socket

`refresh` and `switch` use a Unix domain socket the app creates at
`~/Library/Application Support/LimitLifeboat/control.sock`
(`LimitLifeboat-Dev` for development builds). The security design is in
[SECURITY.md](../SECURITY.md#app-control-socket). In short:

- the folder is `0700` and the socket `0600`;
- the server checks every peer's uid with `getpeereid` before reading;
- the client checks the socket and the server's uid;
- only the `refresh` and `switch` intents exist;
- both go through the app's existing workflows.

Wire protocol, version 1. Over one connection the client sends one
newline-terminated JSON request, the app sends one newline-terminated JSON
response, and the app closes the connection. Requests are at most 16 KiB and
must arrive within 5 seconds.

```jsonc
// request
{ "v": 1, "id": "optional, echoed back", "command": "refresh" | "switch", "accountId": "UUID" }
// response
{ "v": 1, "id": "…", "ok": true, "result": { /* as above */ } }
{ "v": 1, "id": "…", "ok": false, "error": { "code": "…", "message": "…" } }
```

A peer the app does not accept is disconnected without a response.
