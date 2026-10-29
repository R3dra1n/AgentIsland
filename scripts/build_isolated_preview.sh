#!/bin/bash
# Developer-only simultaneous preview: separate process lock and preferences.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${AGENTISLAND_ISOLATED_OUTPUT_DIR:-$DIR/build-output/isolated-ui}"
AGENTISLAND_ISOLATED_PREVIEW=1 \
AGENTISLAND_SIGN_IDENTITY=- \
AGENTISLAND_OUTPUT_DIR="$OUTPUT" \
AGENTISLAND_BUILD_PATH="${AGENTISLAND_ISOLATED_BUILD_PATH:-$DIR/.build/isolated-ui}" \
bash "$DIR/scripts/build_app.sh"
APP="$OUTPUT/AgentIsland.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.agentisland.isolatedpreview' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName AgentIsland Isolated Preview' "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf 'Isolated UI preview: %s\n' "$APP"
printf 'Launch only with other observers disabled and a dedicated Antigravity test question.\n'
