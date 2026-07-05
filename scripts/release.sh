#!/usr/bin/env bash
# Builds, signs (Developer ID), notarizes, and packages a distributable DMG.
#
# One-time setup (see RELEASING.md):
#   - Developer ID Application certificate in the login keychain
#   - xcrun notarytool store-credentials llm-usage-monitor \
#       --apple-id <email> --team-id <TEAMID> --password <app-specific-password>
#
# Usage: ./scripts/release.sh [version]
# Env overrides: VERSION, SIGN_IDENTITY, NOTARY_PROFILE
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="LLMUsageMonitor"
VERSION="${VERSION:-${1:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-llm-usage-monitor}"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION.dmg"
ENTITLEMENTS="$ROOT_DIR/Packaging/$APP_NAME.entitlements"

SKIP_ADHOC_SIGN=1 VERSION="$VERSION" "$ROOT_DIR/scripts/package-app.sh"

echo "==> Signing app with '$SIGN_IDENTITY'"
# Single binary, no nested code: one codesign invocation suffices.
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "==> Notarizing app"
ZIP_PATH="$ROOT_DIR/dist/$APP_NAME.zip"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP_DIR"
rm -f "$ZIP_PATH"

echo "==> Building DMG"
STAGE="$ROOT_DIR/dist/dmg-staging"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "LLM Usage Monitor" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
rm -rf "$STAGE"

echo "==> Signing and notarizing DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG_PATH"

echo "==> Gatekeeper verification"
spctl -a -t exec -vv "$APP_DIR"
spctl -a -t open --context context:primary-signature -vv "$DMG_PATH"

echo "Release ready: $DMG_PATH"
