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
2. For each of the four accounts, open its dashboard, run the official CLI login command, then save the CLI snapshot.
3. Use `Switch CLI` to restore a saved snapshot for the selected provider. Active sessions are not killed; new credential reads use the restored account state.

The menu bar shows compact provider usage without opening the popover: `C` is Claude and `G` is ChatGPT/Codex. Usage turns orange near 80% used and red when depleted; local notifications are sent on those threshold changes.
