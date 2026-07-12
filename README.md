# LLM Usage Monitor

Native macOS menu-bar app for people with multiple Claude and ChatGPT/Codex
subscription accounts. It watches how much of each account's included usage
is left and switches the Claude Code / Codex CLI to another account in one
click — so you hop to an account with quota remaining instead of paying
usage-based overage.

## How it works

- **Accounts register themselves.** Log into Claude Code (`claude`) or
  Codex (`codex login`) in your terminal; on the next refresh the app
  detects the login, creates (or links) the account, and saves an encrypted
  credential snapshot in your macOS Keychain. Changes made by Conductor,
  Claude, Codex, or another terminal are reconciled automatically; opening
  the popover always triggers an immediate check. No manual setup steps.
- **Usage is read locally.** For the active account per provider, the app
  briefly launches Claude Code in screen-reader mode and parses `/usage`,
  and reads recent local Codex session logs for rate-limit status. Claude
  Code labels this an approximate local-machine view; it does not include
  other devices or claude.ai.
- **Inactive accounts keep their last reading**, annotated with how old it
  is — and highlighted when the limit window has already reset, meaning
  that account likely has its full quota back (your best switch target).
  When that happens to an account that was near or past its limit, the app
  sends a notification so you know it is worth switching back.
- **Stale numbers are marked.** Readings older than 30 minutes get a `*`
  in the menu bar and a "Last checked …" note in the popover, and the app
  re-reads usage after your Mac wakes from sleep and when you open the
  popover with outdated data.
- **Switching is one click.** Every non-active account row has a
  "Switch CLI to this account" button. The app captures the current login
  first (nothing is lost), backs up the files it touches, restores the
  target account's credentials, and verifies the CLI now reports the right
  account. If another app changes the credentials during the switch, its
  change wins and this app asks you to retry. Unrelated Claude/Codex and MCP
  settings are preserved. Backups live in
  `~/Library/Application Support/LLMUsageMonitor/Backups/`.
- The menu bar shows the active accounts at a glance
  (`Claude 42%  Codex 87%`), turning orange near 80% used and red when
  depleted, with local notifications on those threshold changes. When an
  account appears to be past its included usage and burning credits or
  pay-as-you-go, it shows `PAYG` instead — the exact thing this app helps
  you avoid, and each account row explains the billing mode it detected.

Add, rename, or remove accounts from the popover (the `+` button per
provider and the `…` menu per account). Browser, Claude Desktop, ChatGPT
Desktop, and CLI sessions are separate: switching affects the CLI only.

Settings (the gear in the popover footer, or ⌘,) cover the refresh
interval, launch at login, and both notification types. The app checks
GitHub once a day for a newer release and links to the download when one
exists — it never updates itself.

### Dashboard fallback

Per-account web dashboards (claude.ai / chatgpt.com) can still be opened
from an account's `…` menu for cross-device numbers, each in an isolated
browser context. Google sign-in sometimes rejects embedded browser windows;
if that happens, use `Open in Browser`, sign in there, press Command-A then
Command-C on the dashboard page, then click `Import Browser Text`.

## Install

Download the DMG from the latest release, drag the app to Applications,
and launch it. The app lives in the menu bar (no Dock icon).

## Build from source

```bash
swift test
./scripts/package-app.sh
open dist/LLMUsageMonitor.app
```

Local packaging automatically uses the first available Apple Development
certificate so macOS Keychain approvals remain valid across rebuilds. Set
`SIGN_IDENTITY` to select a different identity. When no development identity is
available the script falls back to ad-hoc signing and warns that a rebuilt app
may require fresh Keychain approval. The first stably signed build can still ask
once for each item created by an older ad-hoc build; choose `Always Allow` to
migrate that item's trust to the stable identity.

Quit the copy in `dist` before rebuilding it. The packaging script refuses to
delete a running bundle because doing so prevents macOS from verifying that
process for Keychain access. Conductor also stops a workspace-launched copy
before archiving that workspace once the shared repository settings are present
on the default branch.

Do not use `swift run` — the app must run from a bundle for notifications
to work. See [RELEASING.md](RELEASING.md) for signed/notarized releases.
