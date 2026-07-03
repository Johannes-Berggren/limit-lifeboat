# LLM Usage Monitor

Native macOS menu-bar app for watching Claude and ChatGPT/Codex subscription usage across two accounts each, and switching same-provider CLI credentials from saved Keychain snapshots.

## Build

```bash
swift test
./scripts/package-app.sh
open dist/LLMUsageMonitor.app
```

## First Run

1. Open the menu-bar item and choose `Accounts`.
2. Click `Connect Next` until the accounts you want to monitor are signed in.
3. Click `Refresh Usage` in the menu-bar popover.

For the active terminal Codex login, the app also reads recent local Codex session logs for rate-limit usage and reset timing. Claude Code stores local token activity and OAuth material, but not a stable subscription remaining-limit snapshot, so Claude usage still comes from the dashboard/manual import path.

Google sign-in can reject embedded app browser windows. If that happens, use `Open in Browser` from the dashboard window, sign in there, press Command-A then Command-C on the dashboard page, then click `Import Browser Text`.

CLI switching is optional and hidden under `Advanced CLI switching` in the account setup rows. Browser, Claude Desktop, ChatGPT Desktop, and CLI sessions are separate; dashboard login is what the usage monitor reads.

The menu bar shows compact provider usage without opening the popover: `C` is Claude and `G` is ChatGPT/Codex. Usage turns orange near 80% used and red when depleted; local notifications are sent on those threshold changes.
