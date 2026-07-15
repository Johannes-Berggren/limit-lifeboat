#!/usr/bin/env bash
# Revalidates a completed local release, pushes its verified tag, and creates a
# new GitHub draft. It never replaces an existing remote tag or release.
#
# Usage: apps/macos/scripts/publish-draft.sh [version]
# Required environment: TEAM_ID (the permanent 10-character Apple Team ID)
# Environment overrides: VERSION, SPARKLE_ACCOUNT
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
REPOSITORY="Johannes-Berggren/limit-lifeboat"
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
SPARKLE_ACCOUNT="${SPARKLE_ACCOUNT:-limit-lifeboat}"
EXPECTED_TAG="v$RELEASE_VERSION"
DMG_BASENAME="Limit-Lifeboat-$RELEASE_VERSION-$ARCHITECTURE.dmg"
DMG_PATH="$APP_ROOT/dist/$DMG_BASENAME"
CHECKSUM_PATH="$DMG_PATH.sha256"
APPCAST_PATH="$APP_ROOT/dist/appcast.xml"
SPARKLE_LICENSE_FILE="$APP_ROOT/Packaging/Sparkle-LICENSE.txt"
TEAM_ID_SOURCE="$APP_ROOT/Sources/LimitLifeboat/DistributionIdentity.swift"
SPARKLE_TOOLS="$APP_ROOT/.build/artifacts/sparkle/Sparkle/bin"
GENERATE_KEYS="$SPARKLE_TOOLS/generate_keys"
SIGN_UPDATE="$SPARKLE_TOOLS/sign_update"
FEED_URL="https://github.com/$REPOSITORY/releases/latest/download/appcast.xml"
PUBLIC_DOWNLOAD_ROOT="https://github.com/$REPOSITORY/releases/download/$EXPECTED_TAG"
RELEASE_NOTES_URL="https://github.com/$REPOSITORY/releases/tag/$EXPECTED_TAG"
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

assert_developer_id_signature() {
  local artifact="$1"
  local label="$2"
  local details

  codesign --verify --all-architectures --strict --verbose=2 "$artifact"
  details="$(codesign --display --verbose=4 "$artifact" 2>&1)"
  grep -Fq "Authority=Developer ID Application:" <<< "$details" \
    || fail "$label is not Developer ID signed"
  grep -Fxq "TeamIdentifier=$TEAM_ID" <<< "$details" \
    || fail "$label TeamIdentifier does not match $TEAM_ID"
  grep -Eq '^Timestamp=' <<< "$details" || fail "$label has no trusted timestamp"
  grep -Eq '^CodeDirectory .*flags=.*runtime' <<< "$details" \
    || fail "$label does not have hardened runtime enabled"
}

echo "==> Publication preflight"
[[ "$RELEASE_VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
  || fail "Release version '$RELEASE_VERSION' must be stable major.minor.patch SemVer"
[[ "$RELEASE_VERSION" == "$FILE_VERSION" ]] \
  || fail "Release version '$RELEASE_VERSION' does not match VERSION ('$FILE_VERSION')"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] \
  || fail "TEAM_ID must be the permanent 10-character Apple Developer Team ID"
PINNED_TEAM_ID="$(sed -nE 's/^[[:space:]]*static let appleTeamIdentifier = "([^"]+)".*/\1/p' "$TEAM_ID_SOURCE")"
[[ "$TEAM_ID" == "$PINNED_TEAM_ID" ]] \
  || fail "TEAM_ID '$TEAM_ID' does not match the committed release team '$PINNED_TEAM_ID'"

for command_name in cmp codesign gh git grep hdiutil lipo mount otool plutil readlink sed shasum spctl stat xmllint xcrun; do
  command -v "$command_name" >/dev/null || fail "Required command '$command_name' was not found"
done
[[ -x "$GENERATE_KEYS" ]] || fail "Sparkle generate_keys is unavailable: $GENERATE_KEYS"
[[ -x "$SIGN_UPDATE" ]] || fail "Sparkle sign_update is unavailable: $SIGN_UPDATE"
[[ -s "$DMG_PATH" ]] || fail "Release DMG is missing: $DMG_PATH"
[[ -s "$CHECKSUM_PATH" ]] || fail "Release checksum is missing: $CHECKSUM_PATH"
[[ -s "$APPCAST_PATH" ]] || fail "Release appcast is missing: $APPCAST_PATH"
[[ -s "$REPO_ROOT/LICENSE" ]] || fail "Repository license is missing"
[[ -s "$SPARKLE_LICENSE_FILE" ]] || fail "Sparkle license notice is missing"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain=v1 --untracked-files=all)" ]] \
  || fail "The worktree must be clean before publishing"
ORIGIN_MAIN="$(git -C "$REPO_ROOT" rev-parse --verify 'refs/remotes/origin/main^{commit}' 2>/dev/null || true)"
[[ -n "$ORIGIN_MAIN" ]] || fail "Run git fetch origin so origin/main can be verified"
[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$ORIGIN_MAIN" ]] \
  || fail "HEAD must match the fetched origin/main commit exactly"
[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == \
    "$(git -C "$REPO_ROOT" rev-parse --verify "$EXPECTED_TAG^{commit}" 2>/dev/null || true)" ]] \
  || fail "HEAD must be exactly tagged $EXPECTED_TAG"
[[ "$(git -C "$REPO_ROOT" cat-file -t "refs/tags/$EXPECTED_TAG" 2>/dev/null || true)" == "tag" ]] \
  || fail "$EXPECTED_TAG must be an annotated tag"
BUILD_NUMBER="$(git -C "$REPO_ROOT" rev-list --count HEAD)"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || fail "Commit-count build number is invalid: $BUILD_NUMBER"

KEYCHAIN_PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)" \
  || fail "Could not read the Sparkle key from Keychain account '$SPARKLE_ACCOUNT'"
[[ "$KEYCHAIN_PUBLIC_KEY" =~ ^[A-Za-z0-9+/]{43}=$ ]] \
  || fail "Keychain account '$SPARKLE_ACCOUNT' returned an invalid Sparkle public key"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/limit-lifeboat-publish.XXXXXX")"
SPARKLE_PRIVATE_KEY_FILE="$WORK_DIR/sparkle-ed25519-private-key"
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -x "$SPARKLE_PRIVATE_KEY_FILE" >/dev/null \
  || fail "Could not export the Sparkle private key from Keychain account '$SPARKLE_ACCOUNT'"

echo "==> Revalidating release artifacts"
(
  cd "$APP_ROOT/dist"
  shasum -a 256 -c "$DMG_BASENAME.sha256"
)
hdiutil verify "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
DMG_CODESIGN_DETAILS="$(codesign --display --verbose=4 "$DMG_PATH" 2>&1)"
grep -Fq "Authority=Developer ID Application:" <<< "$DMG_CODESIGN_DETAILS" \
  || fail "DMG is not Developer ID signed"
grep -Fxq "TeamIdentifier=$TEAM_ID" <<< "$DMG_CODESIGN_DETAILS" \
  || fail "DMG TeamIdentifier does not match $TEAM_ID"
xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG_PATH"

MOUNT_POINT="$WORK_DIR/mounted-dmg"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_POINT" -quiet

APP="$MOUNT_POINT/$PRODUCT_NAME.app"
EXECUTABLE="$APP/Contents/MacOS/$EXECUTABLE_NAME"
INFO="$APP/Contents/Info.plist"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
AUTOUPDATE="$FRAMEWORK/Versions/B/Autoupdate"
UPDATER="$FRAMEWORK/Versions/B/Updater.app"
[[ -d "$APP" ]] || fail "DMG does not contain $PRODUCT_NAME.app"
[[ -L "$MOUNT_POINT/Applications" && "$(readlink "$MOUNT_POINT/Applications")" == "/Applications" ]] \
  || fail "DMG does not contain the expected Applications symlink"
assert_plist_value "$INFO" CFBundleIdentifier "$BUNDLE_ID"
assert_plist_value "$INFO" CFBundleShortVersionString "$RELEASE_VERSION"
assert_plist_value "$INFO" CFBundleVersion "$BUILD_NUMBER"
assert_plist_value "$INFO" LSMinimumSystemVersion "14.0"
assert_plist_value "$INFO" SUEnableAutomaticChecks "true"
assert_plist_value "$INFO" SUAutomaticallyUpdate "false"
assert_plist_value "$INFO" SUScheduledCheckInterval "86400"
assert_plist_value "$INFO" SUFeedURL "$FEED_URL"
assert_plist_value "$INFO" SUPublicEDKey "$KEYCHAIN_PUBLIC_KEY"
assert_plist_value "$INFO" SURequireSignedFeed "true"
assert_plist_value "$INFO" SUVerifyUpdateBeforeExtraction "true"
cmp -s "$REPO_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt" \
  || fail "Bundled repository license does not match"
cmp -s "$SPARKLE_LICENSE_FILE" "$APP/Contents/Resources/ThirdPartyLicenses/Sparkle.txt" \
  || fail "Bundled Sparkle license notice does not match"
[[ ! -e "$FRAMEWORK/Versions/B/XPCServices" ]] || fail "DMG app includes unused Sparkle XPC services"
[[ "$(lipo -archs "$EXECUTABLE")" == "$ARCHITECTURE" ]] || fail "DMG app is not arm64-only"
otool -L "$EXECUTABLE" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle' \
  || fail "DMG app is not linked to Sparkle.framework"
otool -l "$EXECUTABLE" | grep -A2 LC_RPATH | grep -Fq '@executable_path/../Frameworks' \
  || fail "DMG app lacks the Sparkle framework rpath"
assert_developer_id_signature "$AUTOUPDATE" "Sparkle Autoupdate"
assert_developer_id_signature "$UPDATER" "Sparkle Updater.app"
assert_developer_id_signature "$FRAMEWORK" "Sparkle.framework"
assert_developer_id_signature "$APP" "Limit Lifeboat.app"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"
hdiutil detach "$MOUNT_POINT" -quiet
MOUNT_POINT=""

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
APPCAST_URL="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@url)' "$APPCAST_PATH")"
APPCAST_LENGTH="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@length)' "$APPCAST_PATH")"
APPCAST_SIGNATURE="$(xmllint --xpath 'string(//*[local-name()="enclosure"]/@*[local-name()="edSignature"])' "$APPCAST_PATH")"
[[ "$APPCAST_ITEM_COUNT" == "1" && "$APPCAST_ENCLOSURE_COUNT" == "1" ]] \
  || fail "Appcast must contain exactly one full update"
[[ "$APPCAST_DELTA_COUNT" == "0" ]] || fail "Appcast must not contain deltas"
[[ "$APPCAST_VERSION" == "$BUILD_NUMBER" ]] || fail "Appcast build does not match the release commit count"
[[ "$APPCAST_SHORT_VERSION" == "$RELEASE_VERSION" ]] || fail "Appcast semantic version does not match VERSION"
[[ "$APPCAST_MINIMUM_SYSTEM" == "14.0" ]] || fail "Appcast minimum system is not macOS 14.0"
[[ "$APPCAST_HARDWARE" == "$ARCHITECTURE" ]] || fail "Appcast hardware is not arm64"
[[ "$APPCAST_RELEASE_NOTES" == "$RELEASE_NOTES_URL" ]] || fail "Appcast release-notes URL is incorrect"
[[ "$APPCAST_URL" == "$PUBLIC_DOWNLOAD_ROOT/$DMG_BASENAME" ]] || fail "Appcast enclosure URL is incorrect"
[[ "$APPCAST_LENGTH" == "$(stat -f '%z' "$DMG_PATH")" ]] || fail "Appcast enclosure length is incorrect"
[[ -n "$APPCAST_SIGNATURE" ]] || fail "Appcast enclosure has no EdDSA signature"
"$SIGN_UPDATE" --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE" --verify "$DMG_PATH" "$APPCAST_SIGNATURE"

echo "==> Checking GitHub destination"
gh auth status --hostname github.com >/dev/null
[[ -z "$(git -C "$REPO_ROOT" ls-remote --tags origin "refs/tags/$EXPECTED_TAG")" ]] \
  || fail "Remote tag $EXPECTED_TAG already exists; refusing to overwrite it"

set +e
RELEASE_LOOKUP="$(gh api --include "repos/$REPOSITORY/releases/tags/$EXPECTED_TAG" 2>&1)"
RELEASE_LOOKUP_STATUS=$?
set -e
if (( RELEASE_LOOKUP_STATUS == 0 )); then
  fail "GitHub release $EXPECTED_TAG already exists; refusing to overwrite its release or assets"
fi
grep -Eq '^HTTP/[0-9.]+ 404 ' <<< "$RELEASE_LOOKUP" \
  || fail "Could not prove that GitHub release $EXPECTED_TAG is absent"

echo "==> Pushing verified tag and creating draft"
git -C "$REPO_ROOT" push origin "refs/tags/$EXPECTED_TAG:refs/tags/$EXPECTED_TAG"
gh release create "$EXPECTED_TAG" \
  "$DMG_PATH" \
  "$CHECKSUM_PATH" \
  "$APPCAST_PATH" \
  --repo "$REPOSITORY" \
  --verify-tag \
  --draft \
  --title "Limit Lifeboat $RELEASE_VERSION" \
  --generate-notes

echo "Draft release created for $EXPECTED_TAG with:"
echo "  $DMG_PATH"
echo "  $CHECKSUM_PATH"
echo "  $APPCAST_PATH"
