#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
OUTPUT_DIR="${AGENTISLAND_OUTPUT_DIR:-$DIR/build-output}"
AGENTISLAND_OUTPUT_DIR="$OUTPUT_DIR" bash scripts/build_app.sh
/usr/bin/python3 scripts/check_public_source.py --app "$OUTPUT_DIR/AgentIsland.app"
mkdir -p dist
ARCH="$(lipo -archs "$OUTPUT_DIR/AgentIsland.app/Contents/MacOS/AgentIsland" | tr ' ' '-')"
ARCHIVE="AgentIsland-macOS-${ARCH}-preview.zip"
/usr/bin/ditto --norsrc --noextattr --noqtn -c -k --keepParent "$OUTPUT_DIR/AgentIsland.app" "dist/$ARCHIVE"
cp docs/preview-install.md dist/INSTALL.md
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
if [[ "${AGENTISLAND_SIGN_IDENTITY:--}" == "-" ]]; then
    printf 'Developer preview (ad-hoc signed; notarization not performed): dist/%s\n' "$ARCHIVE"
else
    printf 'Developer preview (configured signing identity; notarization not performed): dist/%s\n' "$ARCHIVE"
fi
