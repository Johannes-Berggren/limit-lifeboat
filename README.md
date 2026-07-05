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
  credential snapshot in your macOS Keychain. No manual setup steps.
- **Usage is read locally.** For the active account per provider, the app
  briefly launches Claude Code in screen-reader mode and parses `/usage`,
  and reads recent local Codex session logs for rate-limit status. Claude
  Code labels this an approximate local-machine view; it does not include
  other devices or claude.ai.
- **Inactive accounts keep their last reading**, annotated with how old it
  is — and highlighted when the limit window has already reset, meaning
  that account likely has its full quota back (your best switch target).
- **Switching is one click.** Every non-active account row has a
  "Switch CLI to this account" button. The app captures the current login
  first (nothing is lost), backs up the files it touches, restores the
  target account's credentials, and verifies the CLI now reports the right
  account. Backups live in
  `~/Library/Application Support/LLMUsageMonitor/Backups/`.
- The menu bar shows the active accounts at a glance
  (`Claude 42%  Codex 87%`), turning orange near 80% used and red when
  depleted, with local notifications on those threshold changes.

Add, rename, or remove accounts from the popover (the `+` button per
provider and the `…` menu per account). Browser, Claude Desktop, ChatGPT
Desktop, and CLI sessions are separate: switching affects the CLI only.

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

Do not use `swift run` — the app must run from a bundle for notifications
to work. See [RELEASING.md](RELEASING.md) for signed/notarized releases.
