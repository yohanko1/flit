#!/bin/bash
# Builds the SwiftPM binary and assembles + signs Flit.app in build/.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Flit.app"
IDENTITY="${FLIT_SIGN_IDENTITY:-Flit Dev}"

swift build -c "$CONFIG" 2>&1 | grep -vE '^\[|^Compiling|^Build complete' || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Flit"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Flit"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/Flit.icns ] && cp Resources/Flit.icns "$APP/Contents/Resources/"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  codesign --force --deep --sign "$IDENTITY" --identifier dev.yohanko.flit \
    --entitlements Resources/Flit.entitlements "$APP"
  echo "Signed with \"$IDENTITY\"."
else
  codesign --force --deep --sign - --identifier dev.yohanko.flit "$APP"
  echo "WARNING: no \"$IDENTITY\" identity; signed ad-hoc. Permissions will reset on each rebuild."
  echo "         Run 'make cert' once to fix this."
fi
echo "Built $APP"
