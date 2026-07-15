#!/usr/bin/env bash
# Builds and assembles apps/macos/dist/Limit Lifeboat.app for Apple Silicon. Development
# builds use SIGN_IDENTITY when provided, otherwise the first Apple Development
# identity, and fall back to ad-hoc signing. scripts/release.sh re-signs for
# distribution (set SKIP_ADHOC_SIGN=1 to leave the bundle unsigned for that
# step).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHITECTURE="${ARCHITECTURE:-arm64}"
PRODUCT_NAME="Limit Lifeboat"
EXECUTABLE_NAME="LimitLifeboat"
BUNDLE_ID="com.limitlifeboat.app"
APP_DIR="$APP_ROOT/dist/$PRODUCT_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_EXECUTABLE="$MACOS_DIR/$EXECUTABLE_NAME"
SPARKLE_ARTIFACT_ROOT="$APP_ROOT/.build/artifacts/sparkle/Sparkle"
SPARKLE_SOURCE="$SPARKLE_ARTIFACT_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_FRAMEWORK="$FRAMEWORKS_DIR/Sparkle.framework"
PROCESS_HELPER="$APP_ROOT/scripts/manage-workspace-app.sh"
ENTITLEMENTS="$APP_ROOT/Packaging/LimitLifeboat.entitlements"
LICENSE_FILE="$REPO_ROOT/LICENSE"
BUNDLED_LICENSE="$RESOURCES_DIR/LICENSE.txt"
SPARKLE_LICENSE_FILE="$APP_ROOT/Packaging/Sparkle-LICENSE.txt"
BUNDLED_SPARKLE_LICENSE="$RESOURCES_DIR/ThirdPartyLicenses/Sparkle.txt"
SPARKLE_PUBLIC_KEY="9mfTfQVDLtvuNmxMr1BvduLMOiVeceFp5rOkOC3PW5Y="
SPARKLE_FEED_URL="https://github.com/Johannes-Berggren/limit-lifeboat/releases/latest/download/appcast.xml"

VERSION="${VERSION:-$(tr -d '[:space:]' < "$APP_ROOT/VERSION")}"
# Keep build numbers monotonic across native and website commits in the
# monorepo, rather than counting commits from a package-local history.
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$REPO_ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"

if [[ "$ARCHITECTURE" != "arm64" ]]; then
  echo "Unsupported architecture '$ARCHITECTURE'; Limit Lifeboat is distributed for arm64 only." >&2
  exit 1
fi

if [[ ! "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo "Version must use stable major.minor.patch SemVer: '$VERSION'" >&2
  exit 1
fi

if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
  echo "Build number must be a positive integer: '$BUILD_NUMBER'" >&2
  exit 1
fi

plutil -lint "$ENTITLEMENTS" >/dev/null
[[ -s "$LICENSE_FILE" ]] || {
  echo "Expected the repository license at $LICENSE_FILE" >&2
  exit 1
}
[[ -s "$SPARKLE_LICENSE_FILE" ]] || {
  echo "Expected the Sparkle license at $SPARKLE_LICENSE_FILE" >&2
  exit 1
}
"$PROCESS_HELPER" check "$APP_EXECUTABLE"

swift build --package-path "$APP_ROOT" -c "$CONFIGURATION" --arch "$ARCHITECTURE"
BUILD_DIR="$(swift build --package-path "$APP_ROOT" -c "$CONFIGURATION" --arch "$ARCHITECTURE" --show-bin-path)"
BUILD_BIN="$BUILD_DIR/$EXECUTABLE_NAME"

if [[ ! -x "$BUILD_BIN" ]]; then
  echo "Expected executable was not produced at $BUILD_BIN" >&2
  exit 1
fi

if [[ ! -d "$SPARKLE_SOURCE" ]]; then
  echo "Expected the resolved Sparkle framework at $SPARKLE_SOURCE" >&2
  exit 1
fi

# Check again immediately before replacement so a copy launched during the
# build cannot be orphaned by the rm below.
"$PROCESS_HELPER" check "$APP_EXECUTABLE"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR/ThirdPartyLicenses"
cp "$BUILD_BIN" "$APP_EXECUTABLE"
ditto "$SPARKLE_SOURCE" "$SPARKLE_FRAMEWORK"
# Limit Lifeboat is not sandboxed, so Sparkle's sandbox-only XPC services are
# unnecessary. Removing both the real directory and top-level symlink also
# keeps the nested signing surface small and explicit.
rm -rf "$SPARKLE_FRAMEWORK/Versions/B/XPCServices" "$SPARKLE_FRAMEWORK/XPCServices"
cp "$APP_ROOT/Packaging/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$LICENSE_FILE" "$BUNDLED_LICENSE"
cp "$SPARKLE_LICENSE_FILE" "$BUNDLED_SPARKLE_LICENSE"
cmp -s "$LICENSE_FILE" "$BUNDLED_LICENSE" || {
  echo "The bundled license does not match $LICENSE_FILE" >&2
  exit 1
}
cmp -s "$SPARKLE_LICENSE_FILE" "$BUNDLED_SPARKLE_LICENSE" || {
  echo "The bundled Sparkle license does not match $SPARKLE_LICENSE_FILE" >&2
  exit 1
}

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>Limit Lifeboat</string>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$PRODUCT_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSAppleEventsUsageDescription</key>
  <string>Limit Lifeboat can open Terminal to help you run official CLI login commands.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$SPARKLE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>86400</integer>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

if [[ "$(lipo -archs "$APP_EXECUTABLE")" != "arm64" ]]; then
  echo "Packaged executable must contain only arm64 code: $(lipo -archs "$APP_EXECUTABLE")" >&2
  exit 1
fi

if ! otool -L "$APP_EXECUTABLE" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
  echo "Packaged executable is not linked to Sparkle through @rpath." >&2
  exit 1
fi

if ! otool -l "$APP_EXECUTABLE" | grep -A2 'cmd LC_RPATH' | grep -Fq '@executable_path/../Frameworks'; then
  echo "Packaged executable is missing the app Frameworks runtime search path." >&2
  exit 1
fi

if [[ "${SKIP_ADHOC_SIGN:-0}" != "1" ]]; then
  RESOLVED_SIGN_IDENTITY="${SIGN_IDENTITY:-}"
  if [[ -z "$RESOLVED_SIGN_IDENTITY" ]]; then
    RESOLVED_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }')"
  fi
  if [[ -z "$RESOLVED_SIGN_IDENTITY" ]]; then
    RESOLVED_SIGN_IDENTITY="-"
    echo "Warning: no Apple Development signing identity found; using ad-hoc signing." >&2
    echo "Keychain 'Always Allow' approvals may not survive the next rebuild. Set SIGN_IDENTITY to use a stable identity." >&2
  else
    echo "Signing development app with '$RESOLVED_SIGN_IDENTITY'."
  fi

  codesign --force --sign "$RESOLVED_SIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
  codesign --force --sign "$RESOLVED_SIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
  codesign --force --sign "$RESOLVED_SIGN_IDENTITY" "$SPARKLE_FRAMEWORK"
  codesign --force --sign "$RESOLVED_SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_DIR"
  codesign --verify --all-architectures --strict --verbose=2 "$SPARKLE_FRAMEWORK"
fi

echo "Built $APP_DIR (version $VERSION, build $BUILD_NUMBER)"
