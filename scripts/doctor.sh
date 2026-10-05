#!/usr/bin/env bash
# =============================================================================
# doctor.sh — read-only health check of the capability/adapter model
#
#   ./scripts/doctor.sh            human-readable report
#   ./scripts/doctor.sh --json     machine-readable
#   ./scripts/doctor.sh --strict   warnings also fail the run
#
# Checks: CLI exists/executable/version, shared skill sources, symlink targets,
# MCP config validity per harness, harness config roots, manifest<->lock sync.
#
# NEVER modifies anything. To change the machine use install.sh / update.sh.
#
# Exit codes: 0 healthy, 1 errors found (or warnings with --strict), 2 config.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ATB_STRICT=0
for a in "$@"; do [[ "$a" == "--strict" ]] && ATB_STRICT=1; done
parse_flags "$@"
command -v python3 >/dev/null 2>&1 || die "doctor.sh requires python3"

args=()
[[ "$ATB_JSON" == "1" ]] && args+=(--json)
[[ "$ATB_STRICT" == "1" ]] && args+=(--strict)
exec python3 "$SCRIPTS_DIR/lib/capability.py" doctor "${args[@]}"
