# Releasing LLM Usage Monitor

## One-time setup

1. **Developer ID certificate** — install your "Developer ID Application"
   certificate (with private key) in the login keychain. Verify:

   ```bash
   security find-identity -v -p codesigning
   # must list: Developer ID Application: <Name> (<TEAMID>)
   ```

2. **Notary credentials** — create an app-specific password at
   [appleid.apple.com](https://appleid.apple.com), then store a notary
   profile (the release script uses the profile name `llm-usage-monitor`
   by default; override with `NOTARY_PROFILE`):

   ```bash
   xcrun notarytool store-credentials llm-usage-monitor \
     --apple-id <apple-id-email> \
     --team-id <TEAMID> \
     --password <app-specific-password>
   ```

## Per release

```bash
# 1. Bump the version and commit
echo "1.1.0" > VERSION
git commit -am "Release 1.1.0"

# 2. Sign, notarize, and package (takes a few minutes for notarization)
./scripts/release.sh

# 3. Tag and publish
git tag "v$(cat VERSION)" && git push --tags
# Attach dist/LLMUsageMonitor-<version>.dmg to a GitHub release
```

Env overrides: `SIGN_IDENTITY` (default `Developer ID Application`, a
partial match is fine when only one such identity is installed),
`NOTARY_PROFILE`, `VERSION`.

## Dev builds

```bash
./scripts/package-app.sh && open dist/LLMUsageMonitor.app
```

Dev builds are ad-hoc signed: notifications work, but macOS resets
permission grants (notifications, Automation) on every rebuild because the
ad-hoc code identity changes. Never use `swift run` — outside an app bundle
UserNotifications raises an exception (the app guards against the crash,
but notifications will be missing).

## Troubleshooting

- **Notarization rejected**: get the log with
  `xcrun notarytool log <submission-id> --keychain-profile llm-usage-monitor`.
- **First signed build re-prompts for Keychain and Automation**: expected —
  the code identity changed from the dev builds, so macOS treats it as a
  new app.
- **Gatekeeper check locally**: `spctl -a -t exec -vv dist/LLMUsageMonitor.app`
  (run by release.sh at the end).

## Icon

`Packaging/AppIcon.icns` is committed. To change the design, edit
`scripts/generate-icon.swift` and run `./scripts/generate-icon.sh`.
