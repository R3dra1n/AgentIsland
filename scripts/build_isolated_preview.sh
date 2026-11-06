#!/bin/bash
# Developer-only isolated test build that can run beside the real app: its own
# bundle id, preferences and process lock, stamped "<version>-preview".
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTISLAND_CHANNEL=preview bash "$DIR/scripts/build_app.sh"
printf 'Launch only with other observers disabled and a dedicated Antigravity test question.\n'
