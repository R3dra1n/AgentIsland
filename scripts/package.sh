#!/bin/bash
# Packages a build for distribution: a zip and a disk image, their checksums,
# and the install notes.
# The channel defaults to release; the archive name carries the version.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
CHANNEL="${AGENTISLAND_CHANNEL:-release}"
OUTPUT_DIR="${AGENTISLAND_OUTPUT_DIR:-$DIR/build-output/$CHANNEL}"
AGENTISLAND_CHANNEL="$CHANNEL" AGENTISLAND_OUTPUT_DIR="$OUTPUT_DIR" bash scripts/build_app.sh
/usr/bin/python3 scripts/check_public_source.py --app "$OUTPUT_DIR/AgentIsland.app"
APP="$OUTPUT_DIR/AgentIsland.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
mkdir -p dist
ARCH="$(lipo -archs "$APP/Contents/MacOS/AgentIsland" | tr ' ' '-')"
ARCHIVE="AgentIsland-${VERSION}-macOS-${ARCH}.zip"
/usr/bin/ditto --norsrc --noextattr --noqtn -c -k --keepParent "$APP" "dist/$ARCHIVE"
cp docs/install.md dist/INSTALL.md
(cd dist && shasum -a 256 "$ARCHIVE" > "$ARCHIVE.sha256")
# A disk image as well: open it and drag the app onto the Applications folder.
# It carries the same app as the zip; neither is notarized.
IMAGE="AgentIsland-${VERSION}-macOS-${ARCH}.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$APP" "$STAGE/AgentIsland.app"
ln -s /Applications "$STAGE/Applications"
rm -f "dist/$IMAGE"
/usr/bin/hdiutil create -quiet -volname "AgentIsland ${VERSION}" -srcfolder "$STAGE" -fs HFS+ -format UDZO "dist/$IMAGE"
(cd dist && shasum -a 256 "$IMAGE" > "$IMAGE.sha256")
if [[ "${AGENTISLAND_SIGN_IDENTITY:--}" == "-" ]]; then
    printf 'AgentIsland %s (ad-hoc signed; notarization not performed): dist/%s\n' "$VERSION" "$ARCHIVE"
else
    printf 'AgentIsland %s (configured signing identity; notarization not performed): dist/%s\n' "$VERSION" "$ARCHIVE"
fi
