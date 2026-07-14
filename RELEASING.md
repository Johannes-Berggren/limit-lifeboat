# Releasing Limit Lifeboat

Limit Lifeboat releases are built locally, signed with a Developer ID
Application certificate, notarized by Apple, and published as immutable GitHub
release assets. The Homebrew Cask installs that same DMG.

The first stable release is `1.0.0`. Release artifacts support Apple Silicon
and macOS 14 Sonoma or newer.

## One-time Apple setup

1. In Apple Developer **Membership details**, confirm the legal team name and
   Team ID for the JB Ventures organization. Use this same team for the App ID,
   Developer ID certificate, signing, and notarization. Do not assume the Team
   ID from an Apple Development certificate belongs to the intended team.
   Record the 10-character Team ID as the permanent `TEAM_ID` for Limit
   Lifeboat before publishing v1. The Team ID anchors the code-signing identity;
   it is separate from the `com.limitlifeboat.app` bundle identifier and the
   organization's display name.
   Replace `UNCONFIGURED` in
   `Sources/LimitLifeboat/DistributionIdentity.swift` with that confirmed Team
   ID in the release-preparation pull request. This pins both the release
   script and the migration-time Developer ID requirement; never change it
   after v1 without a separate identity migration.
2. Register the explicit App ID `com.limitlifeboat.app` under that team.
3. Have the team's Account Holder create a **Developer ID Application**
   certificate. Install the certificate and its private key in the login
   keychain. A Developer ID Installer certificate is not needed for a DMG.
4. Confirm that the expected identity and Team ID are available:

   ```bash
   security find-identity -v -p codesigning
   ```

   The output must contain exactly the Developer ID Application identity that
   should own every public Limit Lifeboat release. If more than one matches,
   always set `SIGN_IDENTITY` to the full identity string.
5. Create an app-specific password for the Apple ID that will submit builds,
   then store it in the release keychain profile:

   ```bash
   xcrun notarytool store-credentials limit-lifeboat \
     --apple-id "<apple-id>" \
     --team-id "<TEAMID>" \
     --password "<app-specific-password>"
   ```

   The default profile name is `limit-lifeboat`. The release script accepts a
   different name through `NOTARY_PROFILE`, but the standard profile should be
   used for v1.

Also enable GitHub private vulnerability reporting and release immutability for
`Johannes-Berggren/limit-lifeboat` before publishing v1. Do not put signing
certificates, private keys, Apple credentials, or notarization credentials in
the repository or GitHub Actions.

## Prepare a release

Merge the version bump and every release change through the protected `main`
branch before creating a tag. Then fetch and build the exact `origin/main`
commit with no tracked or untracked changes. `VERSION` must contain a plain
semantic version without a `v` prefix, and `HEAD` must have the exact matching
`v<version>` tag.

```bash
# After the release-preparation pull request has merged:
git fetch origin
git switch main
git pull --ff-only origin main
test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
git status --short

version="$(tr -d '[:space:]' < VERSION)"
git tag -a "v${version}" -m "Limit Lifeboat ${version}"

git describe --tags --exact-match HEAD
```

Do not move or reuse a version tag after it has been pushed. If the release
candidate needs a code change, delete only the unpushed local tag, make the
change on a new branch, merge its pull request, fast-forward local `main`, and
create a new local tag on that corrected `origin/main` commit.

## Build, sign, and notarize

Run tests and the release command on an Apple Silicon Mac with the Xcode 26
toolchain and macOS 26 SDK selected and the Developer ID certificate installed:

```bash
swift test
TEAM_ID="<10-character Team ID>" \
  SIGN_IDENTITY="Developer ID Application: <legal team name> (<TEAMID>)" \
  NOTARY_PROFILE="limit-lifeboat" \
  ./scripts/release.sh
```

`TEAM_ID` is mandatory on every release invocation, must match the committed
`DistributionIdentity.appleTeamIdentifier`, and must be the permanent team
confirmed in Apple Developer Membership details. The script rejects a
selected Developer ID certificate whose leaf subject OU differs from
`TEAM_ID`, then repeats that check against the signed app's `TeamIdentifier`
and designated requirement.

The script requires a clean exact tag matching `VERSION`, and refuses to build
unless `HEAD` is the fetched `origin/main` commit. It also requires the release
and signed entitlements to contain only the Apple Events Automation entitlement
(in particular, debug and hardened-runtime bypass entitlements are rejected). It packages
`Limit Lifeboat.app`, signs it with the hardened runtime and timestamp,
notarizes and staples the app, builds and signs the DMG, notarizes and staples
the DMG, and performs local integrity and Gatekeeper checks.

`./scripts/release.sh <version>` and the `VERSION` environment variable are
available for automation, but either value must match the committed `VERSION`
file. Do not supply conflicting environment and positional versions.
`SIGN_IDENTITY` and `NOTARY_PROFILE` remain optional overrides; neither
replaces the mandatory `TEAM_ID` check.

For version `1.0.0`, the publishable outputs are:

```text
dist/Limit-Lifeboat-1.0.0-arm64.dmg
dist/Limit-Lifeboat-1.0.0-arm64.dmg.sha256
```

Verify the release identity and artifacts independently before uploading:

```bash
app="dist/Limit Lifeboat.app"
dmg="dist/Limit-Lifeboat-${version}-arm64.dmg"

codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=4 "$app" 2>&1
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
spctl -a -t exec -vv "$app"
spctl -a -t open --context context:primary-signature -vv "$dmg"
hdiutil verify "$dmg"
(cd dist && shasum -a 256 -c "Limit-Lifeboat-${version}-arm64.dmg.sha256")
file "$app/Contents/MacOS/LimitLifeboat"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist"
```

Review the `codesign` output and require the intended Team ID, hardened
runtime, timestamp, and `com.limitlifeboat.app`. Require an arm64 executable
and reject any artifact that fails a command above.

If notarization fails, use the submission ID printed by `notarytool`:

```bash
xcrun notarytool log <submission-id> --keychain-profile limit-lifeboat
```

Fix the underlying problem and issue a new release candidate. Never bypass
notarization or Gatekeeper validation.

## Draft and validate the GitHub release

Push the tag only after local verification succeeds. The tagged commit is
already on the protected `main` branch from the preparation workflow above:

```bash
git push origin "v${version}"

gh release create "v${version}" \
  "dist/Limit-Lifeboat-${version}-arm64.dmg" \
  "dist/Limit-Lifeboat-${version}-arm64.dmg.sha256" \
  --repo Johannes-Berggren/limit-lifeboat \
  --draft \
  --title "Limit Lifeboat ${version}" \
  --generate-notes
```

Keep the release as a draft while testing. On a clean Apple Silicon test Mac
running macOS 14 or newer:

1. Download both assets through a web browser so the DMG receives the normal
   quarantine attribute. Do not remove or alter quarantine metadata.
2. Verify the downloaded checksum, open the DMG, drag **Limit Lifeboat** to
   Applications, and launch it from Finder.
3. Confirm Gatekeeper accepts the app without an unidentified-developer
   bypass, the bundle identifier is `com.limitlifeboat.app`, and the app is
   arm64.
4. Exercise first launch, account discovery, Keychain access, notifications,
   Terminal Automation, account switching, relaunch, launch at login, and the
   update link. Test legacy migration separately when legacy data is present.

Publish the draft only after every validation passes and release immutability
is enabled for the repository. Once published, the version, tag, DMG, and
checksum are permanent. Never replace an artifact for a published version;
fixes require a new patch release.

## Update the Homebrew tap

After the GitHub release is public, update
`Johannes-Berggren/homebrew-tap` at `Casks/limit-lifeboat.rb` with the new
version and the SHA-256 from the published checksum file. The Cask URL must
point to the versioned, immutable GitHub release asset:

```text
https://github.com/Johannes-Berggren/limit-lifeboat/releases/download/v<version>/Limit-Lifeboat-<version>-arm64.dmg
```

Do not publish a Cask that uses a draft asset, a mutable `latest` download URL,
or a locally calculated checksum from a different DMG. Commit and push the tap
change, then validate from a clean Homebrew installation or disposable macOS
account:

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

Test `brew uninstall --cask --zap Johannes-Berggren/tap/limit-lifeboat` only in
a disposable account because it removes Limit Lifeboat's local data. Confirm
that ordinary uninstall leaves user data intact. The reviewed `zap trash:` list
must contain these exact app-owned paths so a reinstall cannot inherit a stale
migration transaction:

```ruby
zap trash: [
  "~/Library/Application Support/LimitLifeboat",
  "~/Library/Application Support/LLMUsageMonitor",
  "~/Library/Application Support/.LimitLifeboatMigration-v1-stage",
  "~/Library/Application Support/.LimitLifeboatMigration-v1.json",
  "~/Library/Application Support/.LimitLifeboatMigration-v1.lock",
  "~/Library/Preferences/com.limitlifeboat.app.plist",
  "~/Library/Preferences/com.johannesberggren.LLMUsageMonitor.plist",
]
```

Do not use broad globs or remove provider-owned Claude/Codex data. Verify each
path against a disposable account containing both current and legacy state.

## Development builds

```bash
./scripts/package-app.sh
open "dist/Limit Lifeboat.app"
```

Development packaging uses an Apple Development identity when available and
otherwise falls back to ad-hoc signing. A rebuilt app may need fresh Keychain,
notification, or Automation approval. Never distribute a development or
ad-hoc signed build, and never use `swift run` as a release candidate.

`Packaging/AppIcon.icns` is generated from `scripts/generate-icon.swift`; use
`./scripts/generate-icon.sh` to regenerate it when the source design changes.
