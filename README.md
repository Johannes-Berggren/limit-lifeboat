# Limit Lifeboat

[Limit Lifeboat](https://limitlifeboat.com) is the safe Claude Code and Codex
account switcher for Mac, with usage for every work and personal account. The
native menu-bar app shows each account's remaining usage and can switch Claude
Code or the Codex CLI to another saved account without replacing unrelated CLI
or MCP settings.

Switching is manual by default; optional switching from a depleted account is
off until you explicitly enable it. Both paths change only the selected CLI
login, verify the restored identity, and roll back if verification fails.
Browser and desktop-app sessions remain separate, and Limit Lifeboat does not
merge accounts or bypass provider limits.

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
  a fallback. Codex usage is fetched through the locally installed Codex app
  server for every saved account, with recent local session data as an
  active-account fallback. Failed accounts retain their last reading and show
  its age.
- **Expired logins stay actionable.** Recoverable Claude credentials refresh
  silently. Rejected logins retain their last reading and show a **Log In**
  action without opening a background dialog; Retry and Switch can offer to
  authenticate again.
- **Switching is transactional and user-controlled.** Manual switching is the
  default, and switching from a depleted account is off until you enable it.
  Every switch captures the current login, stages private rollback material,
  restores and validates the selected identity, then removes the temporary
  material. If another process changes a credential during the operation, that
  external change wins. A recovery path is retained and shown only when a safe
  rollback cannot be completed.
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
Background refreshes do not display a Keychain authorization prompt or switch
the live CLI account. If Codex rotates the active account's token during an
isolated usage check, the app merges it back only when the live credential
fingerprint is unchanged. If macOS requires authorization, the app keeps the
last reading and waits for an explicit retry, capture, removal, or account
switch.

Network access is limited to the services needed for the selected features:

- Anthropic endpoints for Claude account identity, token refresh, and usage
- OpenAI endpoints through the locally installed Codex app server for isolated
  account verification, token refresh, and current usage readings
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
signing. It defaults to the visibly named **Limit Lifeboat Dev** variant, whose
bundle ID, preferences, Application Support folder, and app-owned Keychain
items are isolated from the installed release; updates and launch at login are
disabled. Quit the copy in `apps/macos/dist` before rebuilding it.

The Security.framework integration suite is opt-in. It creates a disposable
temporary Keychain, scopes every query to it, and never adds it to the user's
search list or touches the login Keychain:

```bash
RUN_DISPOSABLE_KEYCHAIN_TESTS=1 swift test --package-path apps/macos \
  --filter testDisposableCustomKeychainDiscoveryAndPinnedAccessIntegration
```

### Troubleshooting keychain prompts

**Limit Lifeboat needs access to Claude's credential.** Open the menu bar
popover, choose **More → Authorize Keychain Access…**, read the explanation,
then enter your macOS password once and choose **Always Allow** in the native
Keychain dialog. Choosing only **Allow** grants access for that read but does
not make it durable, so the app keeps the authorization action available and
does not retry automatically.

Background refreshes, login watchers, popover opens, and `/usage` probes are
noninteractive. The `/usage` fallback launches Claude only when a valid OAuth
token has already been read and injects it as `CLAUDE_CODE_OAUTH_TOKEN`; it
never launches Claude to make the CLI read Keychain itself.

If the app reports duplicate or malformed Claude items, it deliberately does
not choose, rewrite, or delete one. Quit workspace builds and relaunch the
stable app in `/Applications`, or explicitly recreate the Claude login.

**Dev builds re-prompt after every rebuild.** Ad-hoc signed bundles get a
per-build `cdhash` grant that dies with the next build. `package-app.sh`
auto-picks an Apple Development identity (or honors `SIGN_IDENTITY`), which
keeps the code requirement stable across rebuilds. The app labels ad-hoc
authorization as nondurable; relaunch an Apple Development-signed workspace
bundle or the installed Developer ID-signed release before authorizing if the
grant needs to survive a rebuild.

**Never replace a running bundle.** `manage-workspace-app.sh check` refuses
to overwrite a live app; quit it first. Swapping the binary under a running
process breaks keychain code-signature verification (`errSecCS*` errors and
"Quit and relaunch" messaging).

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
