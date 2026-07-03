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

For the active terminal Claude login, the app briefly launches Claude Code in screen-reader mode, sends `/usage`, parses the session/week/usage-credit panel, then terminates that helper process. Claude Code labels this as an approximate local-machine view; it does not include other devices or claude.ai. For the active terminal Codex login, the app reads recent local Codex session logs for rate-limit usage and reset timing, and maps the current CLI identity to the matching Codex profile.

Workspace/team Codex analytics use OpenAI's Codex Analytics API, which requires a workspace API key scoped to `codex.enterprise.analytics.read`; the normal local CLI token is not documented as an analytics API credential.

Google sign-in can reject embedded app browser windows. If that happens, use `Open in Browser` from the dashboard window, sign in there, press Command-A then Command-C on the dashboard page, then click `Import Browser Text`.

CLI switching is optional and hidden under `Advanced CLI switching` in the account setup rows. Browser, Claude Desktop, ChatGPT Desktop, and CLI sessions are separate; Claude Code/Codex terminal state is read locally when available, while dashboard login remains the fallback for accounts the terminal cannot identify.

The menu bar shows compact provider usage without opening the popover: `C` is Claude and `G` is ChatGPT/Codex. Usage turns orange near 80% used and red when depleted; local notifications are sent on those threshold changes.
