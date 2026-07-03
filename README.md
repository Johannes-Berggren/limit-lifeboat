# LLM Usage Monitor

Native macOS menu-bar app for watching Claude and ChatGPT/Codex subscription usage across two accounts each, and switching same-provider CLI credentials from saved Keychain snapshots.

## Build

```bash
swift test
./scripts/package-app.sh
open dist/LLMUsageMonitor.app
```

## First Run

1. Open each account dashboard from the menu bar and sign in. Each profile uses its own persistent WebKit data store.
2. For each CLI account, run the official login command in Terminal (`claude login` or `codex login`), then click the key button for the matching account to capture its CLI snapshot.
3. Use the switch button to restore a saved snapshot for the selected provider. Active sessions are not killed; new credential reads use the restored account state.
