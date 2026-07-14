# Releasing Limit Lifeboat

Limit Lifeboat releases are built locally on Apple Silicon, signed with a
Developer ID Application certificate, notarized by Apple, and published as
immutable GitHub release assets. The personal Homebrew tap installs that same
DMG. The v1 target is `1.0.0`, macOS 14+, and arm64 only.

Signing and notarization credentials stay on the release Mac. Never commit a
certificate UUID or fingerprint, certificate/private-key material, Apple ID,
app-specific password, or notary credentials, and never add them to GitHub
Actions.

## One-time launch setup

1. In Apple Developer, confirm that App ID `com.limitlifeboat.app` is
   registered under Team `3DQ7YC2YH2`.
2. Have the team's Account Holder create a **Developer ID Application**
   certificate for that team. Install the certificate and private key in the
   release Mac's login keychain. A Developer ID Installer certificate is not
   needed for a DMG.
3. Confirm that the expected identity is available. If more than one
   Developer ID Application identity appears, pass the full certificate name
   through `SIGN_IDENTITY` when releasing; do not put its UUID in the repo.

   ```bash
   security find-identity -v -p codesigning
   ```

4. Store Apple notarization credentials in the release Mac's Keychain:

   ```bash
   xcrun notarytool store-credentials limit-lifeboat \
     --apple-id "<apple-id>" \
     --team-id "3DQ7YC2YH2" \
     --password "<app-specific-password>"
   xcrun notarytool history --keychain-profile limit-lifeboat
   ```

5. Enable GitHub private vulnerability reporting and release immutability for
   `Johannes-Berggren/limit-lifeboat`.
6. Connect the repository to a Vercel project named `limit-lifeboat`. Set its
   root directory to `apps/site`, framework preset to Astro, Node.js version to
   24, and production branch to `main`. The site is static and needs no Vercel
   adapter. Leave the production domains detached until the GitHub and
   Homebrew downloads described below are public and tested.

## Prepare the exact release commit

Merge every launch change through protected `main`, then work from the exact
fetched `origin/main` commit with a completely clean repository. The release
script intentionally evaluates the whole monorepo for cleanliness and tags;
the native build number is the repository-wide Git commit count.

```bash
git fetch origin
git switch main
git pull --ff-only origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
git status --short

version="$(tr -d '[:space:]' < apps/macos/VERSION)"
test "$version" = "1.0.0" # v1 only
git tag -a "v${version}" -m "Limit Lifeboat ${version}"
git describe --tags --exact-match HEAD
```

Do not move or reuse a pushed tag. If the candidate needs a code change,
delete only an unpushed local tag, make and merge the fix, fast-forward local
`main`, and tag the corrected `origin/main` commit.

## Build, sign, and notarize locally

Use an Apple Silicon Mac with Xcode 26 and the macOS 26 SDK selected:

```bash
swift test --package-path apps/macos
TEAM_ID=3DQ7YC2YH2 \
  SIGN_IDENTITY="Developer ID Application: <legal team name> (3DQ7YC2YH2)" \
  NOTARY_PROFILE=limit-lifeboat \
  apps/macos/scripts/release.sh
```

`TEAM_ID` is mandatory and must match the pinned value in
`DistributionIdentity.swift`. `SIGN_IDENTITY` may be omitted only when exactly
one Developer ID Application identity is installed. `NOTARY_PROFILE` defaults
to `limit-lifeboat`.

The script requires a clean exact tag matching `apps/macos/VERSION` and
requires `HEAD` to equal fetched `origin/main`. It tests the Swift package,
packages the app, verifies the bundled root MIT license, signs with hardened
runtime and a timestamp, notarizes and staples the app, creates/signs/notarizes
the DMG, mounts and revalidates it, and writes the checksum. Release
entitlements must contain only Apple Events automation.

For v1 the outputs are:

```text
apps/macos/dist/Limit Lifeboat.app
apps/macos/dist/Limit-Lifeboat-1.0.0-arm64.dmg
apps/macos/dist/Limit-Lifeboat-1.0.0-arm64.dmg.sha256
```

Verify the candidate independently before pushing the tag:

```bash
app="apps/macos/dist/Limit Lifeboat.app"
dmg="apps/macos/dist/Limit-Lifeboat-${version}-arm64.dmg"

codesign --verify --all-architectures --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
spctl -a -t exec -vv "$app"
spctl -a -t open --context context:primary-signature -vv "$dmg"
hdiutil verify "$dmg"
(cd apps/macos/dist && shasum -a 256 -c "Limit-Lifeboat-${version}-arm64.dmg.sha256")
cmp LICENSE "$app/Contents/Resources/LICENSE.txt"
file "$app/Contents/MacOS/LimitLifeboat"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist"
```

Require Team ID `3DQ7YC2YH2`, bundle ID `com.limitlifeboat.app`, arm64-only
code, hardened runtime, a trusted timestamp, a valid staple, and the exact MIT
license. If notarization fails, retrieve the log using the submission ID that
the script prints:

```bash
xcrun notarytool log <submission-id> --keychain-profile limit-lifeboat
```

Fix the cause and create a new candidate. Never bypass notarization or
Gatekeeper checks.

## Draft and test the GitHub release

Push the verified tag and create a draft containing the exact DMG and checksum:

```bash
git push origin "v${version}"

gh release create "v${version}" \
  "apps/macos/dist/Limit-Lifeboat-${version}-arm64.dmg" \
  "apps/macos/dist/Limit-Lifeboat-${version}-arm64.dmg.sha256" \
  --repo Johannes-Berggren/limit-lifeboat \
  --draft \
  --title "Limit Lifeboat ${version}" \
  --generate-notes
```

Download the draft through a browser so the DMG receives normal quarantine,
then test on clean macOS 14 and current macOS 26 environments. Verify the
checksum and Gatekeeper, install by dragging to Applications, and exercise
first launch, legacy migration, Keychain continuity, account discovery and
switching, notifications, Terminal Automation, relaunch, reinstall, launch at
login, and the update link. Confirm the app never leaves routine switch
rollback material after success.

Publish only after those checks pass. Published tags, versions, DMGs, and
checksums are immutable; fixes require a new patch release.

## Publish the Homebrew Cask

After the GitHub release is public, add or update
`Casks/limit-lifeboat.rb` in `Johannes-Berggren/homebrew-tap`. Use the checksum
from the published `.sha256` file and the immutable versioned asset URL. The
Cask should have this shape:

```ruby
cask "limit-lifeboat" do
  version "1.0.0"
  sha256 "<published sha256>"

  url "https://github.com/Johannes-Berggren/limit-lifeboat/releases/download/v#{version}/Limit-Lifeboat-#{version}-arm64.dmg",
      verified: "github.com/Johannes-Berggren/limit-lifeboat/"
  name "Limit Lifeboat"
  desc "Monitor and switch between AI coding subscription accounts"
  homepage "https://limitlifeboat.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "Limit Lifeboat.app"

  uninstall quit: "com.limitlifeboat.app"

  zap trash: [
    "~/Library/Application Support/LimitLifeboat",
    "~/Library/Application Support/LLMUsageMonitor",
    "~/Library/Application Support/.LimitLifeboatMigration-v1-stage",
    "~/Library/Application Support/.LimitLifeboatMigration-v1.json",
    "~/Library/Application Support/.LimitLifeboatMigration-v1.lock",
    "~/Library/Preferences/com.limitlifeboat.app.plist",
    "~/Library/Preferences/com.johannesberggren.LLMUsageMonitor.plist",
  ]
end
```

Do not use a draft asset or mutable `latest` URL. Add tap CI for Cask style and
audit, then validate against the public artifact:

```bash
brew update
brew tap Johannes-Berggren/tap
brew style --cask Johannes-Berggren/tap/limit-lifeboat
brew audit --cask --online Johannes-Berggren/tap/limit-lifeboat
brew livecheck --cask Johannes-Berggren/tap/limit-lifeboat
brew install --cask Johannes-Berggren/tap/limit-lifeboat
open -a "Limit Lifeboat"
brew reinstall --cask Johannes-Berggren/tap/limit-lifeboat
brew uninstall --cask Johannes-Berggren/tap/limit-lifeboat
```

Test `brew uninstall --cask --zap Johannes-Berggren/tap/limit-lifeboat` only
in a disposable macOS account containing both current and legacy state.
Ordinary uninstall must preserve user data. Zap must not remove
provider-owned Claude or Codex data.

## Deploy the production website

Before publishing the app, confirm that the launch commit produces a healthy
Vercel preview and passes `npm run site:check`, `npm run site:build`, and the CI
internal-link check. Keep `https://limitlifeboat.com` as the canonical URL.

After the GitHub and Homebrew installs both work:

1. Promote/deploy `main` to the Vercel production project.
2. Add `limitlifeboat.com` and `www.limitlifeboat.com` to that project, with
   the apex as primary and `www` redirected to it.
3. In Namecheap, remove only the old parking A/AAAA/CNAME records and replace
   them with the exact DNS values Vercel shows for those domains. Preserve all
   MX and email-forwarding records.
4. Wait for Vercel to confirm DNS and TLS, then verify the apex, the `www`
   redirect, `/privacy`, `/support`, the branded 404, security headers, the
   GitHub download link, and the displayed Homebrew command.

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
