#!/usr/bin/env bash
# Universal release build for Cursor Usage: .app, DMG, and ZIP.
# Usage: ./packaging/build-release.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="Cursor Usage"
EXEC_NAME="CursorUsage"
VOL_NAME="Cursor Usage"
OUT_DIR="$ROOT/release"
STAGE_APP="$OUT_DIR/${APP_NAME}.app"
MIN_OS="14.0"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=(
  "$ROOT/Sources/CursorUsageBar/CursorUsageBarApp.swift"
  "$ROOT/Sources/CursorUsageBar/UsageCore.swift"
)
ICON_ICNS="$ROOT/packaging/icon/AppIcon.icns"
PLIST="$ROOT/packaging/Info.plist"

if [[ ! -f "$ICON_ICNS" ]]; then
  echo "missing icon: $ICON_ICNS" >&2
  exit 1
fi
if [[ ! -f "$PLIST" ]]; then
  echo "missing Info.plist: $PLIST" >&2
  exit 1
fi

BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cursor-usage-build.XXXXXX")"
cleanup() {
  rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

echo ">> compiling arm64 and x86_64"
COMMON_FLAGS=(
  -O
  -whole-module-optimization
  -parse-as-library
  -sdk "$SDK"
  -framework AppKit
  -framework SwiftUI
  -framework ServiceManagement
  -lsqlite3
)

swiftc "${COMMON_FLAGS[@]}" \
  -target "arm64-apple-macosx${MIN_OS}" \
  "${SOURCES[@]}" \
  -o "$BUILD_DIR/CursorUsage-arm64"

swiftc "${COMMON_FLAGS[@]}" \
  -target "x86_64-apple-macosx${MIN_OS}" \
  "${SOURCES[@]}" \
  -o "$BUILD_DIR/CursorUsage-x86_64"

lipo -create \
  "$BUILD_DIR/CursorUsage-arm64" \
  "$BUILD_DIR/CursorUsage-x86_64" \
  -o "$BUILD_DIR/CursorUsage"

echo ">> assembling app bundle"
rm -rf "$STAGE_APP"
mkdir -p "$STAGE_APP/Contents/MacOS" "$STAGE_APP/Contents/Resources"
cp "$PLIST" "$STAGE_APP/Contents/Info.plist"
cp "$BUILD_DIR/CursorUsage" "$STAGE_APP/Contents/MacOS/$EXEC_NAME"
chmod +x "$STAGE_APP/Contents/MacOS/$EXEC_NAME"
cp "$ICON_ICNS" "$STAGE_APP/Contents/Resources/AppIcon.icns"

echo ">> ad-hoc codesign"
codesign --force --deep --sign - "$STAGE_APP"

echo ">> self-test"
"$STAGE_APP/Contents/MacOS/$EXEC_NAME" --self-test

echo ">> building ZIP"
mkdir -p "$OUT_DIR"
ditto -c -k --keepParent "$STAGE_APP" "$OUT_DIR/Cursor-Usage.zip"

echo ">> building DMG"
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/cursor-usage-dmg.XXXXXX")"
cp -R "$STAGE_APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$OUT_DIR/Cursor-Usage.dmg"
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$DMG_STAGE" \
  -ov \
  -format UDZO \
  -fs APFS \
  "$OUT_DIR/Cursor-Usage.dmg" >/dev/null
rm -rf "$DMG_STAGE"

echo ">> done"
file "$STAGE_APP/Contents/MacOS/$EXEC_NAME"
ls -lh "$OUT_DIR/Cursor-Usage.dmg" "$OUT_DIR/Cursor-Usage.zip"
shasum -a 256 "$OUT_DIR/Cursor-Usage.dmg" "$OUT_DIR/Cursor-Usage.zip"
