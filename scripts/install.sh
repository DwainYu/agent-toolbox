#!/usr/bin/env bash
# =============================================================================
# install.sh — apply profiles / capabilities to the live environment
#
# Profile mode (V1, unchanged):
#   ./scripts/install.sh global                     dry-run preview
#   ./scripts/install.sh global --apply             write ~/.pi/agent/
#   ./scripts/install.sh project <name> [--target /path] [--dry-run|--apply]
#   ./scripts/install.sh shared [--apply]           write ~/.agents/mcp.json
#
# Capability mode (V2, thin adapter install):
#   ./scripts/install.sh browser --harness codebuddy
#   ./scripts/install.sh code-review --harness pi
#   ./scripts/install.sh code-intelligence --harness opencode
#   ./scripts/install.sh browser --all-harnesses
#   ./scripts/install.sh <capability> --scope project --project <name> --target /path
#       ^ project-local MCP is an EXPLICIT opt-in; it is never created by default
#
# Principles (both modes):
#   * NEVER overwrite unknown/existing configuration. We only ADD what the
#     profile declares and is missing. Existing differing values are preserved.
#   * Idempotent: running again is a no-op when already in sync.
#   * Backup before any write (<file>.atb-backup.<ts>).
#   * Default is dry-run; you must pass --apply to change the machine.
#   * Capability installs delegate to official installers (bsk, npx skills)
#     or create links into ~/.agents/skills — never a second copy of a tool.
#
# Exit codes: 0 ok, 2 config error.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

parse_flags "$@"
command -v python3 >/dev/null 2>&1 || die "install.sh requires python3"

# Is $1 a declared capability id? -> capability mode (scripts/lib/capability.py).
# The ORIGINAL argv is handed over so capability.py can parse --harness,
# --all-harnesses, --scope, --project, --target, --apply/--dry-run itself.
first="${ATB_POS[0]:-}"
if [[ -n "$first" && "$first" != "global" && "$first" != "project" && "$first" != "shared" ]]; then
  if yqdata "$MANIFEST" --arg c "$first" \
       'if ((.capabilities // {}) | has($c)) then "yes" else "no" end' 2>/dev/null | grep -qx yes; then
    exec python3 "$SCRIPTS_DIR/lib/capability.py" install "$@"
  fi
fi

if [[ "$first" == "global" ]]; then
  MODE="global"
elif [[ "$first" == "shared" ]]; then
  MODE="shared"
elif [[ "$first" == "project" ]]; then
  MODE="project"
  PROJECT="${ATB_POS[1]:-}"
  [[ -z "$PROJECT" ]] && die "usage: ./scripts/install.sh project <name> [--target /path]"
else
  die "usage: ./scripts/install.sh global|shared|project <name> | <capability> --harness <id> [flags]"
fi

# ----------------------------------------------------------------------------
# merge plan/apply in python
# ----------------------------------------------------------------------------
# merge_config <mode> <profile-json> <target-json> <ctype> <label>
#   ctype: settings | mcp | mcp-opencode
#   mode:  plan | apply
# The add-only / backup-first logic lives in scripts/lib/merge_config.py so that
# install.sh and the capability installer share exactly one merge implementation.
merge_config() {
  local mode="$1" prof="$2" target="$3" ctype="$4" label="$5"
  die_if_not_file "$prof" "profile"
  python3 "$SCRIPTS_DIR/lib/merge_config.py" "$mode" "$prof" "$target" "$ctype" "$label"
}

# ----------------------------------------------------------------------------
# package advisory (list pi install commands, never auto-run here)
# ----------------------------------------------------------------------------
package_advice() {
  echo "Packages (install these with Pi natively, e.g.):"
  yqjson "$MANIFEST" '.resources.packages[] | select(.scope == "global") | "  pi install npm:" + (.source.package // .id) + "@" + (.source.ref // "")' \
    | sed 's/"//g'
}

# =============================================================================
# SHARED — tool-agnostic layer (~/.agents/mcp.json)
# This is the default home for shared MCP definitions. Harnesses either read it
# directly (Pi) or mirror it into their native config (CodeBuddy/Qoder/OpenCode).
# =============================================================================
if [[ "$MODE" == "shared" ]]; then
  target_dir="${HOME}/.agents"
  src="${PROFILES_DIR}/shared/mcp.json"
  if [[ "$ATB_DRY_RUN" == "1" || "$ATB_APPLY" != "1" ]]; then
    echo "Dry run — nothing written. Pass --apply to write."
    echo "Shared layer: ${target_dir}"
    echo ""
    merge_config plan "$src" "${target_dir}/mcp.json" mcp "shared mcp"
    echo ""
    echo "Shared skills are NOT copied here — they are owned by the official"
    echo "installers (bsk install-skill / npx skills add)."
    exit "$EXIT_OK"
  fi
  echo "Applying shared profile -> ${target_dir}"
  merge_config apply "$src" "${target_dir}/mcp.json" mcp "shared mcp"
  ok "Shared MCP layer applied."
  exit "$EXIT_OK"
fi

# =============================================================================
# GLOBAL
# =============================================================================
if [[ "$MODE" == "global" ]]; then
  target_dir="${HOME}/.pi/agent"
  if [[ "$ATB_DRY_RUN" == "1" || "$ATB_APPLY" != "1" ]]; then
    echo "Dry run — nothing written. Pass --apply to write."
    echo ""
    echo "Would install:"
    merge_config plan "${PROFILES_DIR}/global/settings.json" "${target_dir}/settings.json" settings "global settings"
    echo ""
    merge_config plan "${PROFILES_DIR}/global/mcp.json" "${target_dir}/mcp.json" mcp "global mcp"
    echo ""
    package_advice
    echo ""
    echo "Global skills/extensions are installed by their own installers (bsk, orca, npm)."
    echo "This toolbox records them as metadata; it does not copy them here."
    exit "$EXIT_OK"
  fi

  echo "Applying global profile -> ${target_dir}"
  merge_config apply "${PROFILES_DIR}/global/settings.json" "${target_dir}/settings.json" settings "global settings"
  echo ""
  merge_config apply "${PROFILES_DIR}/global/mcp.json" "${target_dir}/mcp.json" mcp "global mcp"
  echo ""
  ok "Global profile applied. Packages (above) are installed via 'pi install'."
  exit "$EXIT_OK"
fi

# =============================================================================
# PROJECT
# =============================================================================
# resolve target path
if [[ -n "$ATB_TARGET" ]]; then
  target_root="${ATB_TARGET}"
else
  target_root="$(yqdata "$MANIFEST" --arg p "$PROJECT" '.profiles.projects[$p].path // empty')"
  target_root="${target_root/#\~/$HOME}"
  [[ -z "$target_root" ]] && die "unknown project '$PROJECT'. Add it to manifest.yaml profiles.projects or pass --target."
fi

pprofile_dir="${PROFILES_DIR}/projects/${PROJECT}"
die_if_not_file "${pprofile_dir}/mcp.json" "project profile"
p_target="${target_root}/.pi"

if [[ "$ATB_DRY_RUN" == "1" || "$ATB_APPLY" != "1" ]]; then
  echo "Dry run — nothing written. Pass --apply to write."
  echo "Project: ${PROJECT}  target: ${p_target}"
  echo ""
  merge_config plan "${pprofile_dir}/mcp.json" "${p_target}/mcp.json" mcp "project mcp"
  echo ""
  merge_config plan "${pprofile_dir}/settings.json" "${p_target}/settings.json" settings "project settings"
  echo ""
  echo "Note: project skills/extensions are owned by the project repo; the toolbox"
  echo "does not copy them in. They load only after Pi trusts the project."
  exit "$EXIT_OK"
fi

echo "Applying project profile -> ${p_target}"
merge_config apply "${pprofile_dir}/mcp.json" "${p_target}/mcp.json" mcp "project mcp"
echo ""
merge_config apply "${pprofile_dir}/settings.json" "${p_target}/settings.json" settings "project settings"
echo ""
ok "Project profile applied."
exit "$EXIT_OK"
