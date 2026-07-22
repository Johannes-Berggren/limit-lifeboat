#!/usr/bin/env bash
# Builds and assembles apps/macos/dist/Limit Lifeboat.app for Apple Silicon.
# APP_VARIANT defaults to development, which uses isolated app-owned storage
# and disables updates and launch at login. Development builds use SIGN_IDENTITY
# when provided, otherwise the first Apple Development
# identity, and fall back to ad-hoc signing. scripts/release.sh re-signs for
# distribution (set SKIP_ADHOC_SIGN=1 to leave the bundle unsigned for that
# step).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
ARCHITECTURE="${ARCHITECTURE:-arm64}"
APP_VARIANT="${APP_VARIANT:-development}"
PRODUCT_NAME="Limit Lifeboat"
EXECUTABLE_NAME="LimitLifeboat"
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
SPARKLE_PUBLIC_KEY="sByqwP3sYWWv46jT+x7vgv7tt+iujcezHs7WX+gyP7g="
SPARKLE_FEED_URL="https://github.com/Johannes-Berggren/limit-lifeboat/releases/latest/download/appcast.xml"

case "$APP_VARIANT" in
  development)
    DISPLAY_NAME="Limit Lifeboat Dev"
    BUNDLE_ID="com.limitlifeboat.app.dev"
    CREDENTIAL_SERVICE="com.limitlifeboat.app.dev.credentials"
    APPLICATION_SUPPORT_NAME="LimitLifeboat-Dev"
    SPARKLE_AUTOMATIC_CHECKS="false"
    ;;
  distribution)
    DISPLAY_NAME="Limit Lifeboat"
    BUNDLE_ID="com.limitlifeboat.app"
    CREDENTIAL_SERVICE="com.limitlifeboat.app.credentials"
    APPLICATION_SUPPORT_NAME="LimitLifeboat"
    SPARKLE_AUTOMATIC_CHECKS="true"
    ;;
  *)
    echo "APP_VARIANT must be 'development' or 'distribution': '$APP_VARIANT'" >&2
    exit 1
    ;;
esac

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

swift build --package-path "$APP_ROOT" --disable-keychain -c "$CONFIGURATION" --arch "$ARCHITECTURE"
BUILD_DIR="$(swift build --package-path "$APP_ROOT" --disable-keychain -c "$CONFIGURATION" --arch "$ARCHITECTURE" --show-bin-path)"
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
# SPM emits bundled resources (the provider marks) as a .bundle next to the
# executable; Bundle.module resolves it relative to the binary, so it must sit
# beside the executable inside the app.
RESOURCE_BUNDLE="$BUILD_DIR/LimitLifeboat_LimitLifeboat.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "Expected the SPM resource bundle at $RESOURCE_BUNDLE" >&2
  exit 1
fi
ditto "$RESOURCE_BUNDLE" "$MACOS_DIR/LimitLifeboat_LimitLifeboat.bundle"
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
  <string>$DISPLAY_NAME</string>
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
  <key>LimitLifeboatAppVariant</key>
  <string>$APP_VARIANT</string>
  <key>LimitLifeboatApplicationSupportDirectoryName</key>
  <string>$APPLICATION_SUPPORT_NAME</string>
  <key>LimitLifeboatCredentialService</key>
  <string>$CREDENTIAL_SERVICE</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Limit Lifeboat can open Terminal to help you run official CLI login commands.</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>SUEnableAutomaticChecks</key>
  <$SPARKLE_AUTOMATIC_CHECKS/>
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
    if [[ "$APP_VARIANT" == "development" ]]; then
      RESOLVED_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development:/ { print $2; exit }')"
    else
      RESOLVED_SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk '/"Developer ID Application:/ { print $2; exit }')"
    fi
  fi
  if [[ -z "$RESOLVED_SIGN_IDENTITY" ]]; then
    RESOLVED_SIGN_IDENTITY="-"
  fi
  if [[ "$RESOLVED_SIGN_IDENTITY" == "-" ]]; then
    echo "Warning: no stable signing identity selected for the $APP_VARIANT variant; using ad-hoc signing." >&2
    if [[ "$APP_VARIANT" == "development" ]]; then
      echo "This build cannot claim durable Keychain authorization; approvals may not survive the next rebuild. Set SIGN_IDENTITY to an Apple Development identity." >&2
    else
      echo "This test package cannot launch as a distribution build. Releases must use the pinned-team Developer ID Application identity." >&2
    fi
  else
    echo "Signing $APP_VARIANT app with '$RESOLVED_SIGN_IDENTITY'."
  fi

  codesign --force --sign "$RESOLVED_SIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK/Versions/B/Autoupdate"
  codesign --force --sign "$RESOLVED_SIGN_IDENTITY" \
    "$SPARKLE_FRAMEWORK/Versions/B/Updater.app"
  codesign --force --sign "$RESOLVED_SIGN_IDENTITY" "$SPARKLE_FRAMEWORK"
  codesign --force --sign "$RESOLVED_SIGN_IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP_DIR"
  codesign --verify --all-architectures --strict --verbose=2 "$APP_DIR"
  codesign --verify --all-architectures --strict --verbose=2 "$SPARKLE_FRAMEWORK"

  if [[ "$APP_VARIANT" == "development" ]]; then
    SIGNING_DETAILS="$(codesign --display --verbose=4 "$APP_DIR" 2>&1)"
    if grep -Fq "Authority=Apple Development:" <<< "$SIGNING_DETAILS" \
      && grep -Eq '^TeamIdentifier=[A-Z0-9]{10}$' <<< "$SIGNING_DETAILS"; then
      echo "Development bundle has a stable Apple Development requirement; native Always Allow authorization can survive rebuilds."
    else
      echo "Warning: this development bundle is not signed with a stable Apple Development identity." >&2
      echo "The app will label Keychain authorization as nondurable and may ask again after rebuilding." >&2
    fi
  fi
fi

echo "Built $APP_DIR (variant $APP_VARIANT, version $VERSION, build $BUILD_NUMBER)"
