#!/usr/bin/env bash
# Regenerates Packaging/AppIcon.icns from scripts/generate-icon.swift.
# The result is committed; run this only when changing the icon design.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

swift "$APP_ROOT/scripts/generate-icon.swift" "$WORK_DIR/icon_1024.png"

ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$WORK_DIR/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$WORK_DIR/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

mkdir -p "$APP_ROOT/Packaging"
iconutil -c icns "$ICONSET" -o "$APP_ROOT/Packaging/AppIcon.icns"
echo "Wrote $APP_ROOT/Packaging/AppIcon.icns"
