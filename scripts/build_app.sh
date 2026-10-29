#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$DIR/.build/module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
BUILD_PATH="${AGENTISLAND_BUILD_PATH:-$DIR/.build}"
OUTPUT_DIR="${AGENTISLAND_OUTPUT_DIR:-$DIR/build-output}"
mkdir -p "$OUTPUT_DIR"
BUILD_FLAGS=()
if [[ "${AGENTISLAND_DISABLE_BUILD_SANDBOX:-0}" == 1 ]]; then BUILD_FLAGS+=(--disable-sandbox); fi
if [[ "${AGENTISLAND_UNIVERSAL:-0}" == 1 ]]; then BUILD_FLAGS+=(--arch arm64 --arch x86_64); fi
if [[ "${AGENTISLAND_ISOLATED_PREVIEW:-0}" == 1 ]]; then BUILD_FLAGS+=(-Xswiftc -DAGENTISLAND_ISOLATED_PREVIEW); fi
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
mkdir -p "$APP/Contents/Resources/hooks"
cp "$DIR/scripts/configure_hooks.py" "$DIR/scripts/record_hook.py" "$APP/Contents/Resources/hooks/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentIsland</string>
<key>CFBundleIdentifier</key><string>com.antigravity.AgentIsland</string>
<key>CFBundleName</key><string>AgentIsland</string>
<key>CFBundleDisplayName</key><string>AgentIsland</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Use a stable developer certificate when provided. Ad-hoc signatures bind
# permissions to this build's hash and cannot preserve grants across rebuilds.
SIGN_IDENTITY="${AGENTISLAND_SIGN_IDENTITY:--}"
codesign --force --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/AgentIslandHook"
codesign --force --sign "$SIGN_IDENTITY" "$APP"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    printf 'Ad-hoc build: Accessibility permission may need renewal after rebuilding.\n'
fi
codesign --verify --strict "$APP"
codesign --verify --strict "$APP/Contents/MacOS/AgentIslandHook"
# Keep the previous build until the replacement has built and signed successfully.
if [[ -e "$OUTPUT_DIR/AgentIsland.app" ]]; then
    BACKUP="$OUTPUT_DIR/AgentIsland.previous.$(date +%Y%m%d%H%M%S).app"
    mv "$OUTPUT_DIR/AgentIsland.app" "$BACKUP"
fi
mv "$APP" "$OUTPUT_DIR/AgentIsland.app"
printf 'Built %s\n' "$OUTPUT_DIR/AgentIsland.app"
