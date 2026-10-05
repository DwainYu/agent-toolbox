#!/usr/bin/env bash
# =============================================================================
# update.sh — tool update vs adapter update lifecycle
#
#   ./scripts/update.sh                 report (read-only)
#   ./scripts/update.sh --mock          use tests/fixtures (no network)
#   ./scripts/update.sh --apply         run official updaters + refresh adapters
#   ./scripts/update.sh --apply --reindex
#                                       ALSO run `codegraph index` — only ever
#                                       when index.reindexRecommended is true
#
# Two kinds of update (docs/lifecycle.md):
#   tool update   -> the CLI binary (bsk / ocr / codegraph), via its official
#                    updater (cli.updater), then registry + lock reconciled
#   adapter update-> skills and MCP wiring re-checked and re-applied (idempotent)
#
# CodeGraph index lifecycle is deliberately separate:
#   * code changes   -> watcher + incremental sync, NEVER triggered from here
#   * CLI upgrade    -> restart the harness, then check reindexRecommended
#   * full reindex   -> only with --reindex AND reindexRecommended == true
#
# This script never runs `pi install` and never rewrites project .pi/mcp.json.
#
# Exit codes: 0 nothing to do, 1 updates/issues pending (or applied), 2 config.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ATB_REINDEX=0
for a in "$@"; do [[ "$a" == "--reindex" ]] && ATB_REINDEX=1; done
parse_flags "$@"
command -v python3 >/dev/null 2>&1 || die "update.sh requires python3"

args=()
[[ "$ATB_JSON" == "1" ]] && args+=(--json)
[[ "$ATB_APPLY" == "1" ]] && args+=(--apply)
[[ "$ATB_MOCK" == "1" ]] && args+=(--mock)
[[ "$ATB_REINDEX" == "1" ]] && args+=(--reindex)
exec python3 "$SCRIPTS_DIR/lib/capability.py" update "${args[@]}"
