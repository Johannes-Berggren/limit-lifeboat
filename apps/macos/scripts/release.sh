#!/usr/bin/env bash
# Builds, signs with Developer ID, notarizes, and packages a Limit Lifeboat DMG.
#
# One-time setup (see RELEASING.md):
#   xcrun notarytool store-credentials limit-lifeboat \
#     --apple-id <email> --team-id <TEAMID> --password <app-specific-password>
#
# Usage: apps/macos/scripts/release.sh [version]
# Required environment: TEAM_ID (the permanent 10-character Apple Team ID)
# Environment overrides: VERSION, SIGN_IDENTITY, NOTARY_PROFILE, SPARKLE_ACCOUNT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
PRODUCT_NAME="Limit Lifeboat"
EXECUTABLE_NAME="LimitLifeboat"
BUNDLE_ID="com.limitlifeboat.app"
ARCHITECTURE="arm64"
VERSION_FILE="$APP_ROOT/VERSION"
FILE_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
ARG_VERSION="${1:-}"

if (( $# > 1 )); then
  echo "Usage: $0 [version]" >&2
  exit 2
fi

if [[ -n "$ARG_VERSION" && -n "${VERSION:-}" && "$ARG_VERSION" != "$VERSION" ]]; then
  echo "Positional version '$ARG_VERSION' conflicts with VERSION='$VERSION'." >&2
  exit 2
fi

RELEASE_VERSION="${VERSION:-${ARG_VERSION:-$FILE_VERSION}}"
TEAM_ID="${TEAM_ID:-}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
NOTARY_PROFILE="${NOTARY_PROFILE:-limit-lifeboat}"
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-limit-lifeboat}"
EXPECTED_TAG="v$RELEASE_VERSION"
APP_DIR="$APP_ROOT/dist/$PRODUCT_NAME.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
APP_FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
APP_AUTOUPDATE="$APP_FRAMEWORK/Versions/B/Autoupdate"
APP_UPDATER="$APP_FRAMEWORK/Versions/B/Updater.app"
ENTITLEMENTS="$APP_ROOT/Packaging/LimitLifeboat.entitlements"
TEAM_ID_SOURCE="$APP_ROOT/Sources/LimitLifeboat/DistributionIdentity.swift"
LICENSE_FILE="$REPO_ROOT/LICENSE"
APP_LICENSE="$APP_DIR/Contents/Resources/LICENSE.txt"
SPARKLE_LICENSE_FILE="$APP_ROOT/Packaging/Sparkle-LICENSE.txt"
APP_SPARKLE_LICENSE="$APP_DIR/Contents/Resources/ThirdPartyLicenses/Sparkle.txt"
SPARKLE_TOOLS="$APP_ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_TOOLS/generate_appcast"
GENERATE_KEYS="$SPARKLE_TOOLS/generate_keys"
SIGN_UPDATE="$SPARKLE_TOOLS/sign_update"
FEED_URL="https://github.com/Johannes-Berggren/limit-lifeboat/releases/latest/download/appcast.xml"
PUBLIC_DOWNLOAD_ROOT="https://github.com/Johannes-Berggren/limit-lifeboat/releases/download/$EXPECTED_TAG"
RELEASE_NOTES_URL="https://github.com/Johannes-Berggren/limit-lifeboat/releases/tag/$EXPECTED_TAG"
DMG_BASENAME="Limit-Lifeboat-$RELEASE_VERSION-$ARCHITECTURE.dmg"
DMG_PATH="$APP_ROOT/dist/$DMG_BASENAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
APPCAST_PATH="$APP_ROOT/dist/appcast.xml"
WORK_DIR=""
MOUNT_POINT=""

cleanup() {
  if [[ -n "$MOUNT_POINT" ]] && mount | grep -Fq " on $MOUNT_POINT "; then
    hdiutil detach "$MOUNT_POINT" -quiet || true
  fi
  if [[ -n "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

fail() {
  echo "error: $*" >&2
  exit 1
}

plist_value() {
  local plist="$1"
  local key="$2"
  plutil -extract "$key" raw -o - "$plist"
}

assert_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(plist_value "$plist" "$key")" || fail "Missing $key in $plist"
  [[ "$actual" == "$expected" ]] || fail "$key in $plist is '$actual'; expected '$expected'"
}

assert_release_entitlements() {
  local plist="$1"
  local actual_json
  local expected_json='{"com.apple.security.automation.apple-events":true}'

  actual_json="$(plutil -convert json -o - "$plist")" \
    || fail "Could not read entitlements from $plist"
  [[ "$actual_json" == "$expected_json" ]] \
    || fail "Release entitlements in $plist must contain only the Apple Events automation entitlement"
}

assert_developer_id_signature() {
  local artifact="$1"
  local label="$2"
  local details

  codesign --verify --all-architectures --strict --verbose=2 "$artifact"
  details="$(codesign --display --verbose=4 "$artifact" 2>&1)"
  grep -Fq "Authority=Developer ID Application:" <<< "$details" \
    || fail "$label is not signed with a Developer ID Application certificate"
  grep -Fxq "TeamIdentifier=$TEAM_ID" <<< "$details" \
    || fail "$label TeamIdentifier does not match expected Apple Team $TEAM_ID"
  grep -Eq '^Timestamp=' <<< "$details" \
    || fail "$label has no trusted timestamp"
  grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$details" \
    || fail "$label does not have hardened runtime enabled"
}

notarize() {
  local artifact="$1"
  local label="$2"
  local result_path="$WORK_DIR/notary-$label.json"
  local log_path="$WORK_DIR/notary-$label-log.json"
  local submission_id=""
  local status=""
  local submit_exit=0

  xcrun notarytool submit "$artifact" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json > "$result_path" || submit_exit=$?

  cat "$result_path"
  submission_id="$(plutil -extract id raw -o - "$result_path" 2>/dev/null || true)"
  status="$(plutil -extract status raw -o - "$result_path" 2>/dev/null || true)"

  if (( submit_exit != 0 )) || [[ "$status" != "Accepted" ]]; then
    echo "Notarization failed for $artifact (status: ${status:-unknown})." >&2
    if [[ -n "$submission_id" ]]; then
      if xcrun notarytool log --keychain-profile "$NOTARY_PROFILE" \
        "$submission_id" "$log_path"; then
        cat "$log_path" >&2
      else
        echo "Unable to retrieve notarization log for submission $submission_id." >&2
      fi
    fi
    return 1
  fi
}

echo "==> Release preflight"
[[ "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "Release version '$RELEASE_VERSION' must be stable major.minor.patch SemVer"
[[ "$RELEASE_VERSION" == "$FILE_VERSION" ]] \
  || fail "Release version '$RELEASE_VERSION' does not match VERSION ('$FILE_VERSION')"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "TEAM_ID must be the permanent 10-character Apple Developer Team ID"
PINNED_TEAM_ID="$(sed -nE 's/^[[:space:]]*static let appleTeamIdentifier = "([^"]+)".*/\1/p' "$TEAM_ID_SOURCE")"
[[ "$PINNED_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "The committed release team in $TEAM_ID_SOURCE is invalid"
[[ "$TEAM_ID" == "$PINNED_TEAM_ID" ]] \
  || fail "TEAM_ID '$TEAM_ID' does not match the committed release team '$PINNED_TEAM_ID'"
[[ "$(uname -m)" == "$ARCHITECTURE" ]] \
  || fail "Releases must be built on an Apple Silicon Mac (found $(uname -m))"

for command_name in awk cmp codesign ditto git grep hdiutil lipo mount otool plutil readlink security sed shasum spctl stat swift xmllint xcrun; do
  command -v "$command_name" >/dev/null || fail "Required command '$command_name' was not found"
done
xcrun --find notarytool >/dev/null || fail "notarytool is unavailable"
xcrun --find stapler >/dev/null || fail "stapler is unavailable"

[[ -s "$LICENSE_FILE" ]] || fail "The repository license is missing or empty: $LICENSE_FILE"
[[ -s "$SPARKLE_LICENSE_FILE" ]] || fail "The Sparkle license is missing or empty: $SPARKLE_LICENSE_FILE"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]] \
  || fail "The worktree must be clean before releasing"
ORIGIN_MAIN="$(git -C "$REPO_ROOT" rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null || true)"
[[ -n "$ORIGIN_MAIN" ]] \
  || fail "The fetched origin/main ref is unavailable; run git fetch origin before releasing"
[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$ORIGIN_MAIN" ]] \
  || fail "HEAD must match the fetched origin/main commit exactly"
[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == \
    "$(git -C "$REPO_ROOT" rev-parse --verify "$EXPECTED_TAG^{commit}" 2>/dev/null || true)" ]] \
  || fail "HEAD must be exactly tagged $EXPECTED_TAG"
[[ "$(git -C "$REPO_ROOT" cat-file -t "refs/tags/$EXPECTED_TAG" 2>/dev/null || true)" == "tag" ]] \
  || fail "$EXPECTED_TAG must be an annotated tag"
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "Commit-count build number is invalid: $BUILD_NUMBER"

plutil -lint "$ENTITLEMENTS" >/dev/null
assert_release_entitlements "$ENTITLEMENTS"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/limit-lifeboat-release.XXXXXX")"

CODESIGN_IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ "$SIGN_IDENTITY" == "Developer ID Application" ]]; then
  DEVELOPER_ID_COUNT="$(awk '/"Developer ID Application:/ { count++ } END { print count + 0 }' <<< "$CODESIGN_IDENTITIES")"
  [[ "$DEVELOPER_ID_COUNT" == "1" ]] \
    || fail "Expected exactly one Developer ID Application identity, found $DEVELOPER_ID_COUNT; set SIGN_IDENTITY to the full certificate name"
  SIGN_IDENTITY="$(awk -F '"' '/"Developer ID Application:/ { print $2; exit }' <<< "$CODESIGN_IDENTITIES")"
fi

MATCHING_IDENTITIES="$(grep -F "$SIGN_IDENTITY" <<< "$CODESIGN_IDENTITIES" || true)"
MATCHING_IDENTITY_COUNT="$(grep -c . <<< "$MATCHING_IDENTITIES" || true)"
[[ "$MATCHING_IDENTITY_COUNT" == "1" ]] \
  || fail "SIGN_IDENTITY must select exactly one installed signing identity (matched $MATCHING_IDENTITY_COUNT)"
grep -Fq '"Developer ID Application:' <<< "$MATCHING_IDENTITIES" \
  || fail "SIGN_IDENTITY does not select a Developer ID Application certificate"
grep -Fq "($TEAM_ID)\"" <<< "$MATCHING_IDENTITIES" \
  || fail "SIGN_IDENTITY does not belong to expected Apple Team $TEAM_ID"

echo "==> Checking notarization credentials"
xcrun notarytool history \
  --keychain-profile "$NOTARY_PROFILE" \
  --output-format json >/dev/null \
  || fail "Cannot authenticate with notarytool profile '$NOTARY_PROFILE'"

echo "==> Running tests"
swift test --package-path "$APP_ROOT" --disable-keychain --arch "$ARCHITECTURE"

for sparkle_tool in "$GENERATE_APPCAST" "$GENERATE_KEYS" "$SIGN_UPDATE"; do
  [[ -x "$sparkle_tool" ]] || fail "Sparkle release tool is unavailable: $sparkle_tool"
done
KEYCHAIN_PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)" \
  || fail "Could not read the Sparkle EdDSA key from Keychain account '$SPARKLE_ACCOUNT'"
[[ "$KEYCHAIN_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "Keychain account '$SPARKLE_ACCOUNT' returned an invalid Sparkle public key"
SPARKLE_PRIVATE_KEY_FILE="$WORK_DIR/sparkle-ed25519-private-key"
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -x "$SPARKLE_PRIVATE_KEY_FILE" >/dev/null \
  || fail "Could not export the Sparkle private key from Keychain account '$SPARKLE_ACCOUNT'"

echo "==> Building app"
SKIP_ADHOC_SIGN=1 ARCHITECTURE="$ARCHITECTURE" VERSION="$RELEASE_VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
  "$APP_ROOT/scripts/package-app.sh"

plutil -lint "$INFO_PLIST" >/dev/null
assert_plist_value "$INFO_PLIST" CFBundleDisplayName "$PRODUCT_NAME"
assert_plist_value "$INFO_PLIST" CFBundleExecutable "$EXECUTABLE_NAME"
assert_plist_value "$INFO_PLIST" CFBundleIdentifier "$BUNDLE_ID"
assert_plist_value "$INFO_PLIST" CFBundleShortVersionString "$RELEASE_VERSION"
assert_plist_value "$INFO_PLIST" CFBundleVersion "$BUILD_NUMBER"
assert_plist_value "$INFO_PLIST" LSMinimumSystemVersion "14.0"
assert_plist_value "$INFO_PLIST" SUEnableAutomaticChecks "true"
assert_plist_value "$INFO_PLIST" SUAutomaticallyUpdate "false"
assert_plist_value "$INFO_PLIST" SUScheduledCheckInterval "86400"
assert_plist_value "$INFO_PLIST" SUFeedURL "$FEED_URL"
assert_plist_value "$INFO_PLIST" SUPublicEDKey "$KEYCHAIN_PUBLIC_KEY"
assert_plist_value "$INFO_PLIST" SURequireSignedFeed "true"
assert_plist_value "$INFO_PLIST" SUVerifyUpdateBeforeExtraction "true"
cmp -s "$LICENSE_FILE" "$APP_LICENSE" \
  || fail "The app does not contain an exact copy of the repository license"
cmp -s "$SPARKLE_LICENSE_FILE" "$APP_SPARKLE_LICENSE" \
  || fail "The app does not contain an exact copy of the Sparkle license notice"
[[ -d "$APP_FRAMEWORK" ]] || fail "The app does not contain Sparkle.framework"
[[ ! -e "$APP_FRAMEWORK/Versions/B/XPCServices" ]] \
  || fail "The non-sandboxed app must not include Sparkle's unused XPC services"
otool -L "$APP_EXECUTABLE" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' \
  || fail "Packaged executable is not linked to embedded Sparkle.framework"
otool -l "$APP_EXECUTABLE" | grep -A2 LC_RPATH | grep -Fq '@executable_path/../Frameworks' \
  || fail "Packaged executable does not contain the Sparkle framework rpath"
[[ "$(lipo -archs "$APP_EXECUTABLE")" == "$ARCHITECTURE" ]] \
  || fail "Packaged executable is not arm64-only: $(lipo -archs "$APP_EXECUTABLE")"
[[ "$(xcrun vtool -show-build "$APP_EXECUTABLE" | awk '$1 == "minos" { print $2; exit }')" == "14.0" ]] \
  || fail "Packaged executable does not have a macOS 14.0 deployment target"

echo "==> Signing Sparkle inside-out with '$SIGN_IDENTITY'"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_AUTOUPDATE"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_UPDATER"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_FRAMEWORK"
assert_developer_id_signature "$APP_AUTOUPDATE" "Sparkle Autoupdate"
assert_developer_id_signature "$APP_UPDATER" "Sparkle Updater.app"
assert_developer_id_signature "$APP_FRAMEWORK" "Sparkle.framework"

echo "==> Signing app with '$SIGN_IDENTITY'"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --all-architectures --strict --verbose=2 "$APP_DIR"
assert_developer_id_signature "$APP_AUTOUPDATE" "Embedded Sparkle Autoupdate"
assert_developer_id_signature "$APP_UPDATER" "Embedded Sparkle Updater.app"
assert_developer_id_signature "$APP_FRAMEWORK" "Embedded Sparkle.framework"

CODESIGN_DETAILS="$(codesign --display --verbose=4 "$APP_DIR" 2>&1)"
grep -Fxq "Identifier=$BUNDLE_ID" <<< "$CODESIGN_DETAILS" \
  || fail "Signed app identifier does not match $BUNDLE_ID"
grep -Fq "Authority=Developer ID Application:" <<< "$CODESIGN_DETAILS" \
  || fail "App is not signed with a Developer ID Application certificate"
grep -Fxq "TeamIdentifier=$TEAM_ID" <<< "$CODESIGN_DETAILS" \
  || fail "Signed app TeamIdentifier does not match expected Apple Team $TEAM_ID"
grep -Eq '^Timestamp=' <<< "$CODESIGN_DETAILS" \
  || fail "Signed app has no trusted timestamp"
grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$CODESIGN_DETAILS" \
  || fail "Signed app does not have hardened runtime enabled"

DESIGNATED_REQUIREMENT="$(codesign --display --requirements - "$APP_DIR" 2>&1)"
grep -Fq "designated => identifier \"$BUNDLE_ID\"" <<< "$DESIGNATED_REQUIREMENT" \
  || fail "App designated requirement does not bind bundle ID $BUNDLE_ID"
grep -Fq 'anchor apple generic' <<< "$DESIGNATED_REQUIREMENT" \
  || fail "App designated requirement does not use Apple's trust anchor"
grep -Fq "certificate leaf[subject.OU] = \"$TEAM_ID\"" <<< "$DESIGNATED_REQUIREMENT" \
  || fail "App designated requirement does not bind Apple Team $TEAM_ID"

SIGNED_ENTITLEMENTS="$WORK_DIR/signed-entitlements.plist"
codesign --display --entitlements - --xml "$APP_DIR" > "$SIGNED_ENTITLEMENTS"
plutil -lint "$SIGNED_ENTITLEMENTS" >/dev/null
assert_release_entitlements "$SIGNED_ENTITLEMENTS"

echo "==> Notarizing app"
APP_ZIP="$WORK_DIR/Limit-Lifeboat-$RELEASE_VERSION-$ARCHITECTURE.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$APP_ZIP"
notarize "$APP_ZIP" app
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

echo "==> Building DMG"
STAGE="$WORK_DIR/dmg-staging"
mkdir -p "$STAGE"
ditto "$APP_DIR" "$STAGE/$PRODUCT_NAME.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH" "$CHECKSUM_PATH" "$APPCAST_PATH"
hdiutil create \
  -volname "$PRODUCT_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "==> Signing and notarizing DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
DMG_CODESIGN_DETAILS="$(codesign --display --verbose=4 "$DMG_PATH" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<< "$DMG_CODESIGN_DETAILS" \
  || fail "DMG is not signed with a Developer ID Application certificate"
grep -Fxq "TeamIdentifier=$TEAM_ID" <<< "$DMG_CODESIGN_DETAILS" \
  || fail "DMG TeamIdentifier does not match expected Apple Team $TEAM_ID"
notarize "$DMG_PATH" dmg
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"

echo "==> Validating distribution"
hdiutil verify "$DMG_PATH"
spctl --assess --type execute --verbose=4 "$APP_DIR"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

MOUNT_POINT="$WORK_DIR/mounted-dmg"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet
[[ -d "$MOUNT_POINT/$PRODUCT_NAME.app" ]] \
  || fail "DMG does not contain $PRODUCT_NAME.app"
[[ -L "$MOUNT_POINT/Applications" && "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  || fail "DMG does not contain the expected Applications symlink"
MOUNTED_APP="$MOUNT_POINT/$PRODUCT_NAME.app"
MOUNTED_EXECUTABLE="$MOUNTED_APP/Contents/MacOS/$EXECUTABLE_NAME"
MOUNTED_INFO="$MOUNTED_APP/Contents/Info.plist"
MOUNTED_LICENSE="$MOUNTED_APP/Contents/Resources/LICENSE.txt"
MOUNTED_SPARKLE_LICENSE="$MOUNTED_APP/Contents/Resources/ThirdPartyLicenses/Sparkle.txt"
MOUNTED_FRAMEWORK="$MOUNTED_APP/Contents/Frameworks/Sparkle.framework"
MOUNTED_AUTOUPDATE="$MOUNTED_FRAMEWORK/Versions/B/Autoupdate"
MOUNTED_UPDATER="$MOUNTED_FRAMEWORK/Versions/B/Updater.app"
assert_plist_value "$MOUNTED_INFO" CFBundleIdentifier "$BUNDLE_ID"
assert_plist_value "$MOUNTED_INFO" CFBundleShortVersionString "$RELEASE_VERSION"
assert_plist_value "$MOUNTED_INFO" CFBundleVersion "$BUILD_NUMBER"
assert_plist_value "$MOUNTED_INFO" LSMinimumSystemVersion "14.0"
assert_plist_value "$MOUNTED_INFO" SUEnableAutomaticChecks "true"
assert_plist_value "$MOUNTED_INFO" SUAutomaticallyUpdate "false"
assert_plist_value "$MOUNTED_INFO" SUScheduledCheckInterval "86400"
assert_plist_value "$MOUNTED_INFO" SUFeedURL "$FEED_URL"
assert_plist_value "$MOUNTED_INFO" SUPublicEDKey "$KEYCHAIN_PUBLIC_KEY"
assert_plist_value "$MOUNTED_INFO" SURequireSignedFeed "true"
assert_plist_value "$MOUNTED_INFO" SUVerifyUpdateBeforeExtraction "true"
cmp -s "$LICENSE_FILE" "$MOUNTED_LICENSE" \
  || fail "The app inside the DMG does not contain the repository license"
cmp -s "$SPARKLE_LICENSE_FILE" "$MOUNTED_SPARKLE_LICENSE" \
  || fail "The app inside the DMG does not contain the Sparkle license notice"
[[ -d "$MOUNTED_FRAMEWORK" ]] || fail "The app inside the DMG does not contain Sparkle.framework"
[[ ! -e "$MOUNTED_FRAMEWORK/Versions/B/XPCServices" ]] \
  || fail "The app inside the DMG contains unused Sparkle XPC services"
otool -L "$MOUNTED_EXECUTABLE" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' \
  || fail "The app inside the DMG is not linked to Sparkle.framework"
otool -l "$MOUNTED_EXECUTABLE" | grep -A2 LC_RPATH | grep -Fq '@executable_path/../Frameworks' \
  || fail "The app inside the DMG lacks the Sparkle framework rpath"
[[ "$(lipo -archs "$MOUNTED_EXECUTABLE")" == "$ARCHITECTURE" ]] \
  || fail "The app inside the DMG is not arm64-only"
codesign --verify --all-architectures --strict --verbose=2 "$MOUNTED_APP"
assert_developer_id_signature "$MOUNTED_AUTOUPDATE" "DMG Sparkle Autoupdate"
assert_developer_id_signature "$MOUNTED_UPDATER" "DMG Sparkle Updater.app"
assert_developer_id_signature "$MOUNTED_FRAMEWORK" "DMG Sparkle.framework"
MOUNTED_CODESIGN_DETAILS="$(codesign --display --verbose=4 "$MOUNTED_APP" 2>&1)"
grep -Fxq "Identifier=$BUNDLE_ID" <<< "$MOUNTED_CODESIGN_DETAILS" \
  || fail "The app inside the DMG has the wrong signing identifier"
grep -Fxq "TeamIdentifier=$TEAM_ID" <<< "$MOUNTED_CODESIGN_DETAILS" \
  || fail "The app inside the DMG has the wrong Apple Team ID"
xcrun stapler validate "$MOUNTED_APP"
spctl --assess --type execute --verbose=4 "$MOUNTED_APP"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

(
  cd "$APP_ROOT/dist"
  shasum -a 256 "$DMG_BASENAME" > "$DMG_BASENAME.sha256"
  shasum -a 256 -c "$DMG_BASENAME.sha256"
)

echo "==> Generating signed Sparkle appcast"
APPCAST_SOURCE="$WORK_DIR/appcast-source"
mkdir -p "$APPCAST_SOURCE"
ditto "$DMG_PATH" "$APPCAST_SOURCE/$DMG_BASENAME"
"$GENERATE_APPCAST" \
  --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" \
  --download-url-prefix "$PUBLIC_DOWNLOAD_ROOT/" \
  --full-release-notes-url "$RELEASE_NOTES_URL" \
  --link "https://limitlifeboat.com" \
  --maximum-versions 1 \
  --maximum-deltas 0 \
  -o "$APPCAST_PATH" \
  "$APPCAST_SOURCE"

xmllint --noout "$APPCAST_PATH"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify "$APPCAST_PATH"

APPCAST_ITEM_COUNT="$(xmllint --xpath 'count(//*[local-name()="item"])' "$APPCAST_PATH")"
APPCAST_ENCLOSURE_COUNT="$(xmllint --xpath 'count(//*[local-name()="enclosure"])' "$APPCAST_PATH")"
APPCAST_DELTA_COUNT="$(xmllint --xpath 'count(//*[local-name()="deltaFrom"])' "$APPCAST_PATH")"
APPCAST_VERSION="$(xmllint --xpath 'string(//*[local-name()="version"])' "$APPCAST_PATH")"
APPCAST_SHORT_VERSION="$(xmllint --xpath 'string(//*[local-name()="shortVersionString"])' "$APPCAST_PATH")"
APPCAST_MINIMUM_SYSTEM="$(xmllint --xpath 'string(//*[local-name()="minimumSystemVersion"])' "$APPCAST_PATH")"
APPCAST_HARDWARE="$(xmllint --xpath 'string(//*[local-name()="hardwareRequirements"])' "$APPCAST_PATH")"
APPCAST_RELEASE_NOTES="$(xmllint --xpath 'string(//*[local-name()="fullReleaseNotesLink"])' "$APPCAST_PATH")"
APPCAST_ENCLOSURE_URL="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$APPCAST_PATH")"
APPCAST_ENCLOSURE_LENGTH="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@length)' "$APPCAST_PATH")"
APPCAST_ENCLOSURE_SIGNATURE="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"

[[ "$APPCAST_ITEM_COUNT" == "1" && "$APPCAST_ENCLOSURE_COUNT" == "1" ]] \
  || fail "Appcast must contain exactly one full update"
[[ "$APPCAST_DELTA_COUNT" == "0" ]] || fail "Appcast must not contain delta updates"
[[ "$APPCAST_VERSION" == "$BUILD_NUMBER" ]] \
  || fail "Appcast build '$APPCAST_VERSION' does not match '$BUILD_NUMBER'"
[[ "$APPCAST_SHORT_VERSION" == "$RELEASE_VERSION" ]] \
  || fail "Appcast version '$APPCAST_SHORT_VERSION' does not match '$RELEASE_VERSION'"
[[ "$APPCAST_MINIMUM_SYSTEM" == "14.0" ]] \
  || fail "Appcast minimum macOS is '$APPCAST_MINIMUM_SYSTEM'; expected '14.0'"
[[ "$APPCAST_HARDWARE" == "$ARCHITECTURE" ]] \
  || fail "Appcast hardware requirement is '$APPCAST_HARDWARE'; expected '$ARCHITECTURE'"
[[ "$APPCAST_RELEASE_NOTES" == "$RELEASE_NOTES_URL" ]] \
  || fail "Appcast release notes URL does not target $EXPECTED_TAG"
[[ "$APPCAST_ENCLOSURE_URL" == "$PUBLIC_DOWNLOAD_ROOT/$DMG_BASENAME" ]] \
  || fail "Appcast enclosure does not use the immutable versioned DMG URL"
[[ "$APPCAST_ENCLOSURE_LENGTH" == "$(stat -f '%z' "$DMG_PATH")" ]] \
  || fail "Appcast enclosure length does not match the DMG"
[[ -n "$APPCAST_ENCLOSURE_SIGNATURE" ]] \
  || fail "Appcast enclosure has no EdDSA signature"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify \
  "$DMG_PATH" "$APPCAST_ENCLOSURE_SIGNATURE"

echo "Release ready:"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
echo "  $APPCAST_PATH"
