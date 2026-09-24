#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building StemDrop (release)…"
swift build -c release

APP_DIR="$ROOT_DIR/build/STEM DROP PLUS 2.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

BIN_PATH="$(swift build -c release --show-bin-path)/StemDrop"
cp "$BIN_PATH" "$MACOS_DIR/StemDrop"
chmod +x "$MACOS_DIR/StemDrop"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

if [ -d "$ROOT_DIR/Resources/engine" ]; then
    echo "Copying bundled engine…"
    cp -R "$ROOT_DIR/Resources/engine" "$RESOURCES_DIR/engine"

    # Resources/engine is a prebuilt Python runtime and can lag behind the
    # checked-in engine package. Always overlay the current package so a normal
    # app rebuild cannot silently ship stale stem behavior.
    ENGINE_SITE_PACKAGES="$RESOURCES_DIR/engine/lib/python3.12/site-packages"
    if [ ! -d "$ENGINE_SITE_PACKAGES" ]; then
        echo "error: bundled Python site-packages not found" >&2
        exit 1
    fi
    echo "Syncing current stemdrop_engine package…"
    mkdir -p "$ENGINE_SITE_PACKAGES/stemdrop_engine"
    cp -R "$ROOT_DIR/Engine/stemdrop_engine/." "$ENGINE_SITE_PACKAGES/stemdrop_engine/"
fi

# Sign with the stable local cert if it exists so macOS keeps the app's
# Documents/Desktop permission across rebuilds (ad-hoc signatures change
# every build and re-trigger the TCC prompt). See Scripts/make_signing_cert.sh.
SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "StemDrop Local Signing"; then
    SIGN_ID="StemDrop Local Signing"
    echo "Codesigning with local cert…"
else
    echo "Ad-hoc codesigning (no 'StemDrop Local Signing' cert found)…"
fi
codesign --force --deep --sign "$SIGN_ID" \
    --entitlements "$ROOT_DIR/Resources/StemDrop.entitlements" \
    "$APP_DIR"

echo "$APP_DIR"

# Keep a stable top-level copy next to the source (not build/) so a Dock icon
# can point at it without launching a stale — or missing — app.
DOCK_APP="$ROOT_DIR/STEM DROP PLUS 2.app"
rm -rf "$DOCK_APP"
cp -R "$APP_DIR" "$DOCK_APP"
echo "$DOCK_APP (Dock copy)"
