# Releasing Limit Lifeboat

Limit Lifeboat releases are built locally on Apple Silicon, signed with a
Developer ID Application certificate, notarized by Apple, and published as
immutable GitHub release assets. The personal Homebrew tap installs the same
DMG. Releases are stable `major.minor.patch` versions, require macOS 14 or
later, and are arm64 only.

`apps/macos/VERSION` is the only product-version source. The native build
number is the repository commit count. Protected, linear `main` keeps that
number monotonic. npm package versions are unrelated tooling metadata.

Apple and Sparkle private credentials stay on the release Mac. Never commit a
certificate UUID or fingerprint, certificate/private-key material, Apple ID,
app-specific password, notary credentials, or a Sparkle private key, and never
add them to GitHub Actions.

## One-time release-machine setup

1. In Apple Developer, confirm that App ID `com.limitlifeboat.app` is
   registered under Team `3DQ7YC2YH2`.
2. Install that team's Developer ID Application certificate and private key in
   the release Mac's login Keychain. A Developer ID Installer certificate is
   not needed for a DMG. If more than one matching identity is installed, pass
   the full certificate name through `SIGN_IDENTITY` when releasing.

   ```bash
   security find-identity -v -p codesigning
   ```

3. Store notarization credentials in Keychain:

   ```bash
   xcrun notarytool store-credentials limit-lifeboat \
     --apple-id "<apple-id>" \
     --team-id "3DQ7YC2YH2" \
     --password "<app-specific-password>"
   xcrun notarytool history --keychain-profile limit-lifeboat
   ```

4. Resolve Swift dependencies, then create or inspect the Sparkle EdDSA key
   under Keychain account `limit-lifeboat`:

   ```bash
   swift package resolve --package-path apps/macos
   sparkle_tools="apps/macos/.build/artifacts/sparkle/Sparkle/bin"
   "$sparkle_tools/generate_keys" --account limit-lifeboat
   "$sparkle_tools/generate_keys" --account limit-lifeboat -p
   ```

   The committed public key is:

   ```text
   sByqwP3sYWWv46jT+x7vgv7tt+iujcezHs7WX+gyP7g=
   ```

   Export the private key once to an encrypted removable volume or encrypted
   secrets vault, then securely remove any temporary plaintext file. Keep this
   backup outside every Git checkout and cloud-synced unencrypted folder:

   ```bash
   umask 077
   "$sparkle_tools/generate_keys" --account limit-lifeboat \
     -x "/Volumes/<encrypted-volume>/limit-lifeboat-sparkle-private-key"
   ```

   Losing this key prevents existing installations from trusting new updates.
   Never rotate it as part of a routine release.

5. Confirm `gh auth status` is authenticated for
   `Johannes-Berggren/limit-lifeboat`. Keep GitHub release immutability and
   private vulnerability reporting enabled.

## Prepare the release commit

Change only `apps/macos/VERSION` when advancing the product version. Merge the
version and release changes through protected `main`, then fetch the target
commit. A Conductor workspace branch is valid: do not switch or rename it just
for a release. Both release scripts require a completely clean worktree whose
`HEAD` equals the fetched `origin/main` commit.

```bash
git fetch origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
test -z "$(git status --porcelain=v1 --untracked-files=all)"

version="$(tr -d '[:space:]' < apps/macos/VERSION)"
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
git tag -a "v${version}" -m "Limit Lifeboat ${version}"
git describe --tags --exact-match HEAD
```

Tags must be annotated and exactly match `VERSION`. Do not move or reuse a
pushed tag. If the candidate needs a change, delete only an unpushed local tag,
merge the fix through `main`, fetch the corrected `origin/main`, and tag that
commit.

## Build, sign, notarize, and create the appcast

Use an Apple Silicon Mac with the repository's supported Xcode toolchain:

```bash
TEAM_ID=3DQ7YC2YH2 \
  SIGN_IDENTITY="Developer ID Application: <legal team name> (3DQ7YC2YH2)" \
  NOTARY_PROFILE=limit-lifeboat \
  SPARKLE_ACCOUNT=limit-lifeboat \
  apps/macos/scripts/release.sh
```

`SIGN_IDENTITY` may be omitted only when exactly one Developer ID Application
identity is installed. The other values default where safe, but `TEAM_ID` is
mandatory and must match `DistributionIdentity.swift`.

The release script:

- checks stable SemVer, the exact annotated tag, clean worktree, and
  `HEAD == origin/main` without requiring a branch name;
- runs the Swift suite and explicitly packages the distribution variant with
  the commit-count build number;
- checks the embedded Sparkle framework, rpath, update keys, licenses, and
  absence of unused XPC services;
- checks the Keychain EdDSA public key against the app's committed public key;
- signs Sparkle's nested helpers and framework inside-out with the same
  Developer ID identity, then signs the app with hardened runtime and trusted
  timestamps;
- notarizes and staples the app, creates/signs/notarizes/staples the DMG, then
  mounts and revalidates the distribution;
- writes and verifies the SHA-256 checksum; and
- uses Sparkle's pinned `generate_appcast` to create a signed, one-version
  `appcast.xml` with one full update, no deltas, the immutable versioned DMG
  URL, build/version/minimum macOS metadata, and GitHub release-notes link.

Outputs for version `$version` are:

```text
apps/macos/dist/Limit Lifeboat.app
apps/macos/dist/Limit-Lifeboat-$version-arm64.dmg
apps/macos/dist/Limit-Lifeboat-$version-arm64.dmg.sha256
apps/macos/dist/appcast.xml
```

The script validates every required property, but review the candidate before
publishing:

```bash
app="apps/macos/dist/Limit Lifeboat.app"
dmg="apps/macos/dist/Limit-Lifeboat-${version}-arm64.dmg"
sparkle_tools="apps/macos/.build/artifacts/sparkle/Sparkle/bin"

codesign --verify --all-architectures --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
spctl -a -t exec -vv "$app"
spctl -a -t open --context context:primary-signature -vv "$dmg"
hdiutil verify "$dmg"
(cd apps/macos/dist && shasum -a 256 -c "Limit-Lifeboat-${version}-arm64.dmg.sha256")
xmllint --noout apps/macos/dist/appcast.xml
"$sparkle_tools/sign_update" --account limit-lifeboat --verify \
  apps/macos/dist/appcast.xml
```

Require Team ID `3DQ7YC2YH2`, bundle ID `com.limitlifeboat.app`, arm64-only
code, hardened runtime, trusted timestamps, valid staples, Gatekeeper
acceptance, exact license copies, and the expected Sparkle feed metadata. If
notarization fails, use the submission ID printed by the script:

```bash
xcrun notarytool log <submission-id> --keychain-profile limit-lifeboat
```

Fix the cause and create a new candidate. Never bypass signing, notarization,
Sparkle signature, or Gatekeeper checks.

## Push the verified tag and create a draft

Publication is deliberately separate from building. After independent review,
run:

```bash
TEAM_ID=3DQ7YC2YH2 \
  SPARKLE_ACCOUNT=limit-lifeboat \
  apps/macos/scripts/publish-draft.sh
```

This script revalidates the checksum, DMG, mounted app, every nested signature,
Team ID, hardened runtime, notarization staples, Gatekeeper, licenses, Sparkle
metadata, signed feed, and enclosure EdDSA signature. It then proves the tag
and release do not already exist remotely, pushes the already-verified tag,
and creates a GitHub draft containing exactly:

```text
Limit-Lifeboat-$version-arm64.dmg
Limit-Lifeboat-$version-arm64.dmg.sha256
appcast.xml
```

It refuses to overwrite a tag, release, or assets. If draft creation fails
after the tag push, diagnose the failure; never force-push or move the tag.

## Test the draft and update path

Download the draft through a browser so the DMG receives normal quarantine.
In disposable accounts on macOS 14 and the current macOS release, verify:

- install, first launch, account discovery/switching, notifications, Terminal
  Automation, relaunch, reinstall, and launch at login;
- Keychain and account-data continuity, legacy migration, and no false
  executable-integrity warning;
- with a freshly recreated `Claude Code-credentials` item, choose **More →
  Authorize Keychain Access…**, enter the macOS password once, and select
  **Always Allow**; then verify login completion, manual and automatic
  switching, Retry, repeated popover opens, relaunch, sleep/wake, Claude item
  updates, and an app update produce no further Limit Lifeboat password
  dialogs (Claude's own requester-named authorization is a separate check);
- manual **Check for Updates**, scheduled gentle reminder, menu-bar **Update**
  affordance, dismiss/skip, and explicit **Install and Relaunch**; and
- the installed version/build after updating and launch-at-login continuity.

Installation must always require the user's explicit Install and Relaunch
action. Scheduled checks must not steal focus.

Before promoting the first Sparkle-enabled release on the website and
Homebrew, install a lower-build Sparkle-enabled candidate and verify that it
updates through the published production appcast on both macOS 14 and current
macOS. Because `releases/latest/download/appcast.xml` does not serve a draft,
perform that final production-feed test immediately after publishing and
before changing the website or Homebrew cask.

`v1.0.0` remains immutable. Its original notification-only checker directs
users to install the Sparkle bootstrap release manually. Only later releases
can update in-app.

## Publish the Homebrew cask

The tap lives in the separate `Johannes-Berggren/homebrew-tap` repository. Use
its own workspace and PR. The initial `v1.0.0` cask uses SHA-256
`0691bcf240b22c8fbc77da4554eb1285ff0bf789e0d4d9ff378b5a1d7a97975c`.
Starting with the first Sparkle-enabled release, include `auto_updates true` so
Homebrew and the app do not compete to own updates.

Always use the immutable versioned URL, never a draft or mutable `latest` DMG
URL. Update the tap README and require its existing lifecycle CI to pass:

```bash
brew style --cask Johannes-Berggren/tap/limit-lifeboat
brew audit --cask --online Johannes-Berggren/tap/limit-lifeboat
brew livecheck --cask Johannes-Berggren/tap/limit-lifeboat
brew install --cask Johannes-Berggren/tap/limit-lifeboat
brew reinstall --cask Johannes-Berggren/tap/limit-lifeboat
brew uninstall --cask Johannes-Berggren/tap/limit-lifeboat
```

Test `brew uninstall --cask --zap` only in a disposable account containing
both current and legacy state. Ordinary uninstall must preserve user data. Zap
must not remove provider-owned Claude or Codex data.

## Publish the website and release

Before publication, require the Swift suite, Astro type-check/build/internal
link checks, shell syntax, ShellCheck, packaging assertions, and tap CI to pass.
Publish the GitHub release only after draft testing succeeds. Then immediately
perform the production-feed update test described above before promoting that
version through Homebrew and the website.

Published tags, versions, DMGs, checksums, and appcasts are immutable. Fixes
always require a new patch release.

## Development artifacts

For a local development bundle:

```bash
apps/macos/scripts/package-app.sh
open "apps/macos/dist/Limit Lifeboat.app"
```

Development packaging uses an Apple Development identity when available and
otherwise falls back to ad-hoc signing. Never distribute a development or
ad-hoc signed build. Regenerate the committed icon only when its source design
changes:

```bash
apps/macos/scripts/generate-icon.sh
```
