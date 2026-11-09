#!/bin/bash
# Builds AgentIsland.app for one of two channels that never share state:
#
#   release  the version that is actually run          io.github.r3dra1n.AgentIsland
#   preview  an isolated test build, safe to run       local.agentisland.isolatedpreview
#            beside the real app (own bundle id,
#            preferences and process lock)
#
# The version number lives in one place, the VERSION file. A release build is
# stamped with it as is; a preview build is stamped "<version>-preview" so the
# two can never be mistaken for each other.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

VERSION="$(tr -d '[:space:]' < "$DIR/VERSION")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'VERSION must look like 1.2.3, got: %s\n' "$VERSION" >&2; exit 1; }
CHANNEL="${AGENTISLAND_CHANNEL:-release}"
case "$CHANNEL" in
    release)
        BUNDLE_ID="io.github.r3dra1n.AgentIsland"
        DISPLAY_NAME="AgentIsland"
        SHORT_VERSION="$VERSION"
        ;;
    preview)
        BUNDLE_ID="local.agentisland.isolatedpreview"
        DISPLAY_NAME="AgentIsland Isolated Preview"
        SHORT_VERSION="$VERSION-preview"
        ;;
    *)
        printf 'Unknown AGENTISLAND_CHANNEL "%s": use release or preview\n' "$CHANNEL" >&2
        exit 1
        ;;
esac
# A build number that only ever goes up: the number of commits, unless given.
if [[ -n "${AGENTISLAND_BUILD_NUMBER:-}" ]]; then
    BUILD_NUMBER="$AGENTISLAND_BUILD_NUMBER"
elif git -C "$DIR" rev-parse --verify HEAD >/dev/null 2>&1; then
    BUILD_NUMBER="$(git -C "$DIR" rev-list --count HEAD)"
else
    BUILD_NUMBER=1
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$DIR/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
# The preview channel compiles with an extra flag, so it gets its own scratch
# path instead of invalidating the release build's cache on every switch.
if [[ "$CHANNEL" == preview ]]; then DEFAULT_BUILD="$DIR/.build/preview"; else DEFAULT_BUILD="$DIR/.build"; fi
BUILD_PATH="${AGENTISLAND_BUILD_PATH:-$DEFAULT_BUILD}"
OUTPUT_DIR="${AGENTISLAND_OUTPUT_DIR:-$DIR/build-output/$CHANNEL}"
mkdir -p "$OUTPUT_DIR"
BUILD_FLAGS=()
if [[ "${AGENTISLAND_DISABLE_BUILD_SANDBOX:-0}" == 1 ]]; then BUILD_FLAGS+=(--disable-sandbox); fi
if [[ "${AGENTISLAND_UNIVERSAL:-0}" == 1 ]]; then BUILD_FLAGS+=(--arch arm64 --arch x86_64); fi
if [[ "$CHANNEL" == preview ]]; then BUILD_FLAGS+=(-Xswiftc -DAGENTISLAND_ISOLATED_PREVIEW); fi
if [[ "${#BUILD_FLAGS[@]}" -gt 0 ]]; then
    swift build -c release --scratch-path "$BUILD_PATH" "${BUILD_FLAGS[@]}"
    BIN_DIR="$(swift build -c release --scratch-path "$BUILD_PATH" "${BUILD_FLAGS[@]}" --show-bin-path)"
else
    swift build -c release --scratch-path "$BUILD_PATH"
    BIN_DIR="$(swift build -c release --scratch-path "$BUILD_PATH" --show-bin-path)"
fi
STAGE="$(mktemp -d "$OUTPUT_DIR/.app-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/AgentIsland.app"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$BIN_DIR/AgentIsland" "$APP/Contents/MacOS/AgentIsland"
cp "$BIN_DIR/AgentIslandHook" "$APP/Contents/MacOS/AgentIslandHook"
# Debug symbol paths can disclose the build machine's home directory. Keep
# dSYMs local and remove those symbols before signing the distributed binary.
/usr/bin/strip -S "$APP/Contents/MacOS/AgentIsland"
/usr/bin/strip -S "$APP/Contents/MacOS/AgentIslandHook"
# Package resources inside the signed app; AIIconProvider resolves this layout first.
RESOURCE_BUNDLE="$BIN_DIR/AgentIsland_AgentIsland.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || { printf 'Missing SwiftPM resource bundle\n' >&2; exit 1; }
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
if [[ -d "$DIR/Resources" ]]; then
    cp -R "$DIR/Resources/"* "$APP/Contents/Resources/"
fi
cp "$DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
[[ -f "$APP/Contents/Resources/AppIcon.icns" ]] || { printf 'Missing Resources/AppIcon.icns (regenerate with scripts/make_app_icon.swift)\n' >&2; exit 1; }
# The app needs no Python at run time, so none is bundled: the hook recorder and
# its installer are native (AgentIslandHook).
PLIST="$APP/Contents/Info.plist"
cat > "$PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentIsland</string>
<key>CFBundleIdentifier</key><string>placeholder</string>
<key>CFBundleName</key><string>AgentIsland</string>
<key>CFBundleDisplayName</key><string>placeholder</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    -c "Set :CFBundleDisplayName $DISPLAY_NAME" \
    -c "Set :CFBundleShortVersionString $SHORT_VERSION" \
    -c "Set :CFBundleVersion $BUILD_NUMBER" \
    -c "Add :AgentIslandChannel string $CHANNEL" "$PLIST"
# Use a stable developer certificate when provided. Ad-hoc signatures bind
# permissions to this build's hash and cannot preserve grants across rebuilds.
# A preview build is always ad-hoc: it must never share an identity with the real app.
if [[ "$CHANNEL" == preview ]]; then SIGN_IDENTITY="-"; else SIGN_IDENTITY="${AGENTISLAND_SIGN_IDENTITY:--}"; fi
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/AgentIslandHook"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'Ad-hoc build: Accessibility permission may need renewal after rebuilding.\n'
fi
codesign --verify --strict "$APP"
codesign --verify --strict "$APP/Contents/MacOS/AgentIslandHook"
# Keep exactly one previous build, and only once the replacement has built and signed.
if [[ -e "$OUTPUT_DIR/AgentIsland.app" ]]; then
    rm -rf "$OUTPUT_DIR/AgentIsland.previous.app"
    mv "$OUTPUT_DIR/AgentIsland.app" "$OUTPUT_DIR/AgentIsland.previous.app"
fi
mv "$APP" "$OUTPUT_DIR/AgentIsland.app"
printf 'Built %s %s (build %s): %s\n' "$CHANNEL" "$SHORT_VERSION" "$BUILD_NUMBER" "$OUTPUT_DIR/AgentIsland.app"
