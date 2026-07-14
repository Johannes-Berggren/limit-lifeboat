#!/usr/bin/env bash
# Builds, signs with Developer ID, notarizes, and packages a Limit Lifeboat DMG.
#
# One-time setup (see RELEASING.md):
#   xcrun notarytool store-credentials limit-lifeboat \
#     --apple-id <email> --team-id <TEAMID> --password <app-specific-password>
#
# Usage: apps/macos/scripts/release.sh [version]
# Required environment: TEAM_ID (the permanent 10-character Apple Team ID)
# Environment overrides: VERSION, SIGN_IDENTITY, NOTARY_PROFILE
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
EXPECTED_TAG="v$RELEASE_VERSION"
APP_DIR="$APP_ROOT/dist/$PRODUCT_NAME.app"
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_DIR/Contents/Info.plist"
ENTITLEMENTS="$APP_ROOT/Packaging/LimitLifeboat.entitlements"
TEAM_ID_SOURCE="$APP_ROOT/Sources/LimitLifeboat/DistributionIdentity.swift"
LICENSE_FILE="$REPO_ROOT/LICENSE"
APP_LICENSE="$APP_DIR/Contents/Resources/LICENSE.txt"
DMG_BASENAME="Limit-Lifeboat-$RELEASE_VERSION-$ARCHITECTURE.dmg"
DMG_PATH="$APP_ROOT/dist/$DMG_BASENAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
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
[[ "$RELEASE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z][0-9A-Za-z.-]*)?$ ]] \
  || fail "Invalid release version '$RELEASE_VERSION'"
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

for command_name in awk cmp codesign ditto git grep hdiutil lipo mount plutil readlink security sed shasum spctl swift xcrun; do
  command -v "$command_name" >/dev/null || fail "Required command '$command_name' was not found"
done
xcrun --find notarytool >/dev/null || fail "notarytool is unavailable"
xcrun --find stapler >/dev/null || fail "stapler is unavailable"

[[ -s "$LICENSE_FILE" ]] || fail "The repository license is missing or empty: $LICENSE_FILE"
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
swift test --package-path "$APP_ROOT" --arch "$ARCHITECTURE"

echo "==> Building app"
SKIP_ADHOC_SIGN=1 ARCHITECTURE="$ARCHITECTURE" VERSION="$RELEASE_VERSION" \
  "$APP_ROOT/scripts/package-app.sh"

plutil -lint "$INFO_PLIST" >/dev/null
assert_plist_value "$INFO_PLIST" CFBundleDisplayName "$PRODUCT_NAME"
assert_plist_value "$INFO_PLIST" CFBundleExecutable "$EXECUTABLE_NAME"
assert_plist_value "$INFO_PLIST" CFBundleIdentifier "$BUNDLE_ID"
assert_plist_value "$INFO_PLIST" CFBundleShortVersionString "$RELEASE_VERSION"
assert_plist_value "$INFO_PLIST" LSMinimumSystemVersion "14.0"
cmp -s "$LICENSE_FILE" "$APP_LICENSE" \
  || fail "The app does not contain an exact copy of the repository license"
[[ "$(lipo -archs "$APP_EXECUTABLE")" == "$ARCHITECTURE" ]] \
  || fail "Packaged executable is not arm64-only: $(lipo -archs "$APP_EXECUTABLE")"
[[ "$(xcrun vtool -show-build "$APP_EXECUTABLE" | awk '$1 == "minos" { print $2; exit }')" == "14.0" ]] \
  || fail "Packaged executable does not have a macOS 14.0 deployment target"

echo "==> Signing app with '$SIGN_IDENTITY'"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP_DIR"
codesign --verify --all-architectures --strict --verbose=2 "$APP_DIR"

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
codesign --display --entitlements :- "$APP_DIR" > "$SIGNED_ENTITLEMENTS"
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
rm -f "$DMG_PATH" "$CHECKSUM_PATH"
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
assert_plist_value "$MOUNTED_INFO" CFBundleIdentifier "$BUNDLE_ID"
assert_plist_value "$MOUNTED_INFO" CFBundleShortVersionString "$RELEASE_VERSION"
assert_plist_value "$MOUNTED_INFO" LSMinimumSystemVersion "14.0"
cmp -s "$LICENSE_FILE" "$MOUNTED_LICENSE" \
  || fail "The app inside the DMG does not contain the repository license"
[[ "$(lipo -archs "$MOUNTED_EXECUTABLE")" == "$ARCHITECTURE" ]] \
  || fail "The app inside the DMG is not arm64-only"
codesign --verify --all-architectures --strict --verbose=2 "$MOUNTED_APP"
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

echo "Release ready:"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
