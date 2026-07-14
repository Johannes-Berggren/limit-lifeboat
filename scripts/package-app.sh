#!/usr/bin/env bash
# Builds and assembles dist/Limit Lifeboat.app for Apple Silicon. Development
# builds use SIGN_IDENTITY when provided, otherwise the first Apple Development
# identity, and fall back to ad-hoc signing. scripts/release.sh re-signs for
# distribution (set SKIP_ADHOC_SIGN=1 to leave the bundle unsigned for that
# step).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHITECTURE="${ARCHITECTURE:-arm64}"
PRODUCT_NAME="Limit Lifeboat"
EXECUTABLE_NAME="LimitLifeboat"
BUNDLE_ID="com.limitlifeboat.app"
APP_DIR="$ROOT_DIR/dist/$PRODUCT_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_EXECUTABLE="$MACOS_DIR/$EXECUTABLE_NAME"
PROCESS_HELPER="$ROOT_DIR/scripts/manage-workspace-app.sh"
ENTITLEMENTS="$ROOT_DIR/Packaging/LimitLifeboat.entitlements"

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

if [[ "$ARCHITECTURE" != "arm64" ]]; then
  echo "Unsupported architecture '$ARCHITECTURE'; Limit Lifeboat is distributed for arm64 only." >&2
  exit 1
fi

plutil -lint "$ENTITLEMENTS" >/dev/null
"$PROCESS_HELPER" check "$APP_EXECUTABLE"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --arch "$ARCHITECTURE"
BUILD_DIR="$(swift build -c "$CONFIGURATION" --arch "$ARCHITECTURE" --show-bin-path)"
BUILD_BIN="$BUILD_DIR/$EXECUTABLE_NAME"

if [[ ! -x "$BUILD_BIN" ]]; then
  echo "Expected executable was not produced at $BUILD_BIN" >&2
  exit 1
fi

# Check again immediately before replacement so a copy launched during the
# build cannot be orphaned by the rm below.
"$PROCESS_HELPER" check "$APP_EXECUTABLE"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_BIN" "$APP_EXECUTABLE"
cp "$ROOT_DIR/Packaging/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

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
</dict>
</plist>
PLIST

plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null

if [[ "$(lipo -archs "$APP_EXECUTABLE")" != "arm64" ]]; then
  echo "Packaged executable must contain only arm64 code: $(lipo -archs "$APP_EXECUTABLE")" >&2
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
    --entitlements "$ENTITLEMENTS" \
    "$APP_DIR"
fi

echo "Built $APP_DIR (version $VERSION, build $BUILD_NUMBER)"
