# Limit Lifeboat

[Limit Lifeboat](https://limitlifeboat.com) is a native macOS menu-bar app for
people who use multiple Claude and Codex subscription accounts. It
shows each account's remaining usage and can switch Claude Code or the Codex
CLI to another saved account without replacing unrelated CLI or MCP settings.

This monorepo contains the macOS app and its static Astro marketing site:

```text
apps/macos  Swift package, app packaging, and release tooling
apps/site   Astro website for limitlifeboat.com
```

## Requirements

- An Apple Silicon Mac running macOS 14 Sonoma or newer
- Claude Code and/or the Codex CLI for the providers you want to monitor
- Xcode 26, including the macOS 26 SDK, to build the native app
- Node.js 24 and npm to work on the website

Intel Macs are not supported.

## Install

Install the signed and notarized app with Homebrew:

```bash
brew install --cask Johannes-Berggren/tap/limit-lifeboat
```

Or download the DMG and its SHA-256 checksum from the
[latest GitHub release](https://github.com/Johannes-Berggren/limit-lifeboat/releases/latest),
open the DMG, and drag **Limit Lifeboat** to Applications. Limit Lifeboat runs
in the menu bar and does not add a Dock icon. GitHub Releases is the only
direct-download source for release artifacts.

## How it works

- **Accounts register themselves.** Log in with `claude` or `codex login` in
  Terminal. On refresh, Limit Lifeboat detects the active account, links or
  creates its local profile, and saves an encrypted credential snapshot in
  macOS Keychain.
- **Usage stays current.** Claude usage is fetched from Anthropic with the
  account's saved OAuth credentials, with Claude Code's local `/usage` view as
  a fallback. Codex usage is read from recent local Codex session data.
  Inactive accounts retain their last reading and show its age.
- **Expired logins stay actionable.** Recoverable Claude credentials refresh
  silently. Rejected logins retain their last reading and show a **Log In**
  action without opening a background dialog; Retry and Switch can offer to
  authenticate again.
- **Switching is explicit and transactional.** A switch captures the current
  login, stages private rollback material, restores and validates the selected
  identity, then removes the temporary material. If another process changes a
  credential during the operation, that external change wins. A recovery path
  is retained and shown only when a safe rollback cannot be completed.
- **Warnings are optional.** The app can notify you when an account is nearing
  a limit or when a previously depleted account is likely available again.
- **Updates are user-controlled.** Sparkle checks the signed GitHub release
  feed daily by default and shows a quiet menu-bar affordance when an update is
  available. Limit Lifeboat installs an update only after you explicitly choose
  **Install and Relaunch**; automatic installation is disabled.

Add, rename, or remove accounts from the popover. Settings cover refresh
frequency, launch at login, automatic update checks, organization-name
visibility, and notifications.
Browser, Claude Desktop, ChatGPT Desktop, and CLI sessions are separate:
switching affects only the corresponding CLI login.

Per-account web dashboards can be opened from the account menu in isolated web
contexts. If a provider rejects an embedded login, open the dashboard in your
normal browser and use the app's browser-text import flow instead.

## Privacy and security

Limit Lifeboat has no analytics, advertising, or product telemetry. Account
profiles and usage history are stored locally under
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
- OpenAI endpoints when isolated Codex identity verification needs account or
  token refresh; ordinary Codex usage readings come from local session data
- GitHub Releases for the signed update feed and update downloads
- Claude or ChatGPT web dashboards when you explicitly open one in the app

Embedded dashboards use isolated web data stores that are separate from your
normal browser. Terminal Automation, notifications, and launch at login are
optional macOS permissions or settings. The app deliberately does not use App
Sandbox because switching must read and update provider-owned CLI files; its
release entitlement is limited to Apple Events automation for opening
official login commands in Terminal.

The website uses no analytics, cookies, forms, or external fonts. Vercel may
retain ordinary infrastructure request logs as part of hosting the static
site; those logs are not Limit Lifeboat product analytics.

Please report security issues through
[GitHub private vulnerability reporting](SECURITY.md), not a public issue.

## Migrating from LLM Usage Monitor

First launch can detect data from the pre-release **LLM Usage Monitor**
identity (`com.johannesberggren.LLMUsageMonitor`). Migration begins only after
you approve it. The legacy Application Support directory and Keychain items
are retained as rollback material; migration does not delete or rewrite them.
You can choose **Start Fresh** to leave the legacy data untouched.

For durable Keychain authorization, migration runs only from a Developer
ID-signed Limit Lifeboat release. Quit LLM Usage Monitor before migrating. If
Limit Lifeboat already has non-empty data, automatic migration stops rather
than merging or overwriting either data set.

Notification permission, Terminal Automation access, launch-at-login
registration, and embedded dashboard sessions belong to the new app identity
and may need to be configured again.

## Development

Run the native tests and create a local app bundle from the repository root:

```bash
swift test --package-path apps/macos
apps/macos/scripts/package-app.sh
open "apps/macos/dist/Limit Lifeboat.app"
```

Do not use `swift run`: notifications, Automation, and Keychain identity rely
on running from an application bundle. Local packaging uses an Apple
Development identity when available and otherwise falls back to ad-hoc
signing. Quit the copy in `apps/macos/dist` before rebuilding it.

The `/usr/bin/security` interoperability test is opt-in because macOS may show
a real authorization dialog for that subprocess:

```bash
RUN_KEYCHAIN_INTEROP_TESTS=1 swift test --package-path apps/macos \
  --filter testSecurityToolInteroperability
```

Install website dependencies and run the static Astro site with:

```bash
npm ci
npm run site:dev
npm run site:check
npm run site:build
```

See [RELEASING.md](RELEASING.md) for Developer ID and Sparkle signing,
notarization, GitHub Release, Homebrew, and website rollout procedures.

## License

Limit Lifeboat is available under the [MIT License](LICENSE). Packaging copies
this license into the distributed application bundle.
