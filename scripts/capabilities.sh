#!/usr/bin/env bash
# =============================================================================
# capabilities.sh — capability x harness overview (read-only)
#
#   ./scripts/capabilities.sh              per-capability adapter status
#   ./scripts/capabilities.sh --grid       the capability x harness matrix
#   ./scripts/capabilities.sh --json       machine-readable
#
# Exit codes: 0 always (unless a config error).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ATB_GRID=0
for a in "$@"; do [[ "$a" == "--grid" ]] && ATB_GRID=1; done
parse_flags "$@"
command -v python3 >/dev/null 2>&1 || die "capabilities.sh requires python3"

args=()
[[ "$ATB_JSON" == "1" ]] && args+=(--json)
[[ "$ATB_GRID" == "1" ]] && args+=(--grid)
exec python3 "$SCRIPTS_DIR/lib/capability.py" matrix "${args[@]}"
