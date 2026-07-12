#!/usr/bin/env bash
# Builds and assembles dist/LLMUsageMonitor.app. Dev builds use SIGN_IDENTITY
# when provided, otherwise the first Apple Development identity, and fall back
# to ad-hoc signing. scripts/release.sh re-signs for distribution (set
# SKIP_ADHOC_SIGN=1 to leave the bundle unsigned for that step).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="LLMUsageMonitor"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILD_BIN="$ROOT_DIR/.build/$CONFIGURATION/$APP_NAME"
APP_EXECUTABLE="$MACOS_DIR/$APP_NAME"
PROCESS_HELPER="$ROOT_DIR/scripts/manage-workspace-app.sh"

VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")}"
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || echo 1)"

"$PROCESS_HELPER" check "$APP_EXECUTABLE"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

# Check again immediately before replacement so a copy launched during the
# build cannot be orphaned by the rm below.
"$PROCESS_HELPER" check "$APP_EXECUTABLE"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_BIN" "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Packaging/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>LLM Usage Monitor</string>
  <key>CFBundleExecutable</key>
  <string>LLMUsageMonitor</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.johannesberggren.LLMUsageMonitor</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>LLM Usage Monitor</string>
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
  <string>LLM Usage Monitor can open Terminal to help you run official CLI login commands.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

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
    --entitlements "$ROOT_DIR/Packaging/$APP_NAME.entitlements" \
    "$APP_DIR"
fi

echo "Built $APP_DIR (version $VERSION, build $BUILD_NUMBER)"
