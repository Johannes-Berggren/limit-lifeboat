# Limit Lifeboat

[Limit Lifeboat](https://limitlifeboat.com) is a native macOS menu-bar app for
people who use multiple Claude and Codex subscription accounts. It
shows each account's remaining usage and can switch Claude Code or the Codex
CLI to another saved account without replacing unrelated CLI or MCP settings.

## Requirements

- An Apple Silicon Mac
- macOS 14 Sonoma or newer
- Claude Code and/or the Codex CLI for the providers you want to monitor and
  switch

Add, rename, or remove accounts from the popover (the `+` button per
provider and the `…` menu per account). Browser, Claude Desktop, ChatGPT
Desktop, and CLI sessions are separate: switching affects the CLI only.

Settings (the gear in the popover footer, or ⌘,) cover the refresh
interval, launch at login, organization-name visibility, and both notification
types. The app checks GitHub once a day for a newer release and links to the
download when one exists — it never updates itself.

### Dashboard fallback

Per-account web dashboards (claude.ai / chatgpt.com) can still be opened
from an account's `…` menu for cross-device numbers, each in an isolated
browser context. Google sign-in sometimes rejects embedded browser windows;
if that happens, use `Open in Browser`, sign in there, press Command-A then
Command-C on the dashboard page, then click `Import Browser Text`.

Intel Macs are not supported by the v1 release.

## Install

The v1.0.0 distribution is being prepared. The Homebrew command and signed-DMG
link below become available only after the first signed release is published;
until then, build from source as described below.

### Homebrew

```bash
brew install --cask Johannes-Berggren/tap/limit-lifeboat
```

### Signed DMG

Download the signed and notarized DMG from the
[latest GitHub release](https://github.com/Johannes-Berggren/limit-lifeboat/releases/latest),
open it, and drag **Limit Lifeboat** to Applications. Published releases also
include a SHA-256 checksum file for the DMG.

Limit Lifeboat runs in the menu bar and does not add a Dock icon. Release
artifacts are only published on the
[GitHub releases page](https://github.com/Johannes-Berggren/limit-lifeboat/releases).

## How it works

- **Accounts register themselves.** Log in with `claude` or `codex login` in
  Terminal. On refresh, Limit Lifeboat detects the active account, links or
  creates its local profile, and saves an encrypted credential snapshot in the
  macOS Keychain.
- **Usage stays current.** Claude usage is fetched from Anthropic with the
  account's saved OAuth credentials, with Claude Code's local `/usage` view as
  a fallback. Codex usage is read from recent local Codex session data.
  Inactive accounts retain their last reading and show its age.
- **Expired logins stay actionable.** Recoverable Claude credentials refresh
  silently. Rejected logins retain their last reading and show a **Log In**
  action without opening a background dialog; Retry and Switch can offer to
  authenticate again.
- **Switching is explicit.** Selecting **Switch CLI to this account** first
  captures the current login, backs up the files it will touch, restores the
  chosen snapshot, and verifies the result. A conflicting change from another
  process wins and the app asks you to retry. Codex snapshots are force-
  refreshed and identity-checked in isolation before the live login changes;
  automatic switching skips targets that cannot be verified.
- **Warnings are optional.** The app can notify you when an account is nearing
  a limit or when a previously depleted account is likely available again.
- **Updates are user-controlled.** Limit Lifeboat checks GitHub at most once a
  day and links to a new release. It does not update itself.

Browser, Claude Desktop, ChatGPT Desktop, and CLI sessions are separate.
Switching an account in Limit Lifeboat changes the corresponding CLI login,
not those other sessions.

## Privacy and security

Limit Lifeboat has no analytics, advertising, or telemetry. Account profiles,
usage history, and switching backups are stored locally under
`~/Library/Application Support/LimitLifeboat`; settings use the standard macOS
preferences domain `com.limitlifeboat.app`. App-managed credential snapshots
are encrypted by macOS Keychain under the service
`com.limitlifeboat.app.credentials`.

The app reads Claude Code's provider-owned `Claude Code-credentials` Keychain
item when necessary, but it does not create or take ownership of that item.
Background refreshes do not display a Keychain authorization prompt or modify
the live CLI login. If macOS requires authorization, the app keeps the last
reading and waits for an explicit retry, capture, removal, or account switch.

Network access is limited to the services needed for the selected features:

- Anthropic endpoints for Claude account identity, token refresh, and usage
- GitHub's API for the daily update check
- Claude or ChatGPT web dashboards when you explicitly open an embedded
  dashboard

Codex usage readings come from local session data. Opening a dashboard uses an
isolated web data store inside the app; those sessions are separate from your
normal browser. Terminal Automation, notifications, and launch at login are
optional macOS permissions or settings and can be changed in System Settings.

Switching necessarily writes selected authentication fields to the provider's
CLI configuration. Limit Lifeboat preserves unrelated provider and MCP fields
and creates a local backup before making the change.

Please report security issues through
[GitHub private vulnerability reporting](SECURITY.md), not a public issue.

## Migrating from LLM Usage Monitor

The first launch can detect data from the pre-release **LLM Usage Monitor**
identity (`com.johannesberggren.LLMUsageMonitor`). Migration only begins after
you approve it. The legacy Application Support directory and Keychain items
are retained as rollback material; migration does not delete or rewrite them.
You can instead choose **Start Fresh**, which also leaves the legacy data
untouched. For durable Keychain authorization, migration runs only from a
Developer ID-signed Limit Lifeboat release; development and ad-hoc builds leave
the old data untouched.

Quit LLM Usage Monitor before migrating. If Limit Lifeboat already has
non-empty data, automatic migration stops instead of merging or overwriting
either data set.

Some macOS state is tied to the old bundle identifier and cannot migrate:

- Notification permission must be granted again.
- Terminal Automation access may prompt again on the first switch.
- The new app's launch-at-login registration starts off. The legacy login item
  is separate; disable it in System Settings before enabling the new one.
- Embedded dashboard sessions require a new login.

After confirming that every profile, usage history entry, and saved switch
target works in Limit Lifeboat, you may remove the old app and its retained
data separately.

## Build from source

The package requires the Xcode 26 toolchain (including the macOS 26 SDK) to
compile the guarded Liquid Glass code paths. The resulting app still deploys
to macOS 14 or newer.

```bash
swift test
./scripts/package-app.sh
open "dist/Limit Lifeboat.app"
```

Do not use `swift run`: the app must run from an application bundle for macOS
notifications, Automation, and Keychain identity to work correctly.

Local packaging selects an available Apple Development signing identity. Set
`SIGN_IDENTITY` to choose one explicitly. If none is available, packaging
falls back to ad-hoc signing; macOS may then ask for Keychain and Automation
permission again after rebuilding. Quit the copy in `dist` before rebuilding.

The `/usr/bin/security` interoperability test is opt-in because macOS may show
a real authorization dialog for that subprocess:

```bash
RUN_KEYCHAIN_INTEROP_TESTS=1 swift test --filter testSecurityToolInteroperability
```

See [RELEASING.md](RELEASING.md) for the Developer ID signing, notarization,
DMG, checksum, and Homebrew release procedure.

## License

Limit Lifeboat is available under the [MIT License](LICENSE).
