#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
# XCTest requires the full Xcode developer directory on this machine.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$DIR/.build/test-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
FLAGS=()
if [[ "${AGENTISLAND_DISABLE_BUILD_SANDBOX:-0}" == 1 ]]; then FLAGS+=(--disable-sandbox); fi
if [[ "${#FLAGS[@]}" -gt 0 ]]; then
    swift test --scratch-path "${AGENTISLAND_BUILD_PATH:-$DIR/.build}" "${FLAGS[@]}"
    swift build --product AgentIslandHook --scratch-path "${AGENTISLAND_BUILD_PATH:-$DIR/.build}" "${FLAGS[@]}"
    BIN_DIR="$(swift build --product AgentIslandHook --scratch-path "${AGENTISLAND_BUILD_PATH:-$DIR/.build}" "${FLAGS[@]}" --show-bin-path)"
else
    # macOS Bash 3.2 treats an empty array as unset under `set -u`.
    swift test --scratch-path "${AGENTISLAND_BUILD_PATH:-$DIR/.build}"
    swift build --product AgentIslandHook --scratch-path "${AGENTISLAND_BUILD_PATH:-$DIR/.build}"
    BIN_DIR="$(swift build --product AgentIslandHook --scratch-path "${AGENTISLAND_BUILD_PATH:-$DIR/.build}" --show-bin-path)"
fi
export AGENTISLAND_TEST_HOOK="$BIN_DIR/AgentIslandHook"
/usr/bin/python3 -m unittest discover -s Tests -p 'test_*.py'
