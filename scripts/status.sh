#!/usr/bin/env bash
# =============================================================================
# status.sh — human-readable summary of the toolbox
#
#   ./scripts/status.sh            readable summary
#   ./scripts/status.sh --json     machine-readable JSON (for other agents)
#
# Reads manifest.yaml + lock.yaml and, when running on the actual machine,
# detects drift against the live ~/.pi/agent/ and <repo>/.pi/ environments.
#
# Exit codes: 0 always (unless a config error).
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

parse_flags "$@"
command -v jq >/dev/null 2>&1 || die "status.sh requires jq"

# --- counts -----------------------------------------------------------------
global_counts_scope() {   # global_counts_scope <group> <scope>
  yqjson "$MANIFEST" --arg g "$1" --arg s "$2" \
    '[.resources[$g][] | select(.scope == $s)] | length' 2>/dev/null || echo 0
}

project_names() {
  yqdata "$MANIFEST" '.profiles.projects | keys[]' 2>/dev/null || true
}

project_resource_count() {  # project_resource_count <project> <group>
  yqjson "$MANIFEST" --arg p "$1" --arg g "$2" \
    '[.resources[$g][] | select(.scope == "project") | select((.projects // []) | index($p))] | length' 2>/dev/null || echo 0
}

# ---- updates pending (from a cached report, if present) ---------------------
UPDATE_REPORT="$ATB_ROOT/CHANGELOG/update-report.json"
updates_pending_group() {   # updates_pending_group <kind>
  if [[ -f "$UPDATE_REPORT" ]]; then
    jq -r --arg k "$1" '[.updates[] | select(.kind == $k)] | length' "$UPDATE_REPORT" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

# =============================================================================
# drift detection
# =============================================================================
# Compare two JSON config files and print the identifiers present in profile
# but missing in actual. Returns nothing when clean.
missing_servers() {   # missing_servers <profile.json> <actual.json>
  local prof="$1" actual="$2"
  [[ -f "$actual" ]] || { echo "mcp.json not present"; return; }
  python3 - "$prof" "$actual" <<'PY'
import sys, json
try:
    a = json.load(open(sys.argv[1])).get("mcpServers", {})
    b = json.load(open(sys.argv[2])).get("mcpServers", {})
except Exception:
    sys.exit(0)
for k in sorted(set(a) - set(b)):
    print(k)
PY
}

missing_packages() {  # missing_packages <profile.json> <actual.json>
  local prof="$1" actual="$2"
  [[ -f "$actual" ]] || { echo "settings.json not present"; return; }
  python3 - "$prof" "$actual" <<'PY'
import sys, json
try:
    a = set(json.load(open(sys.argv[1])).get("packages", []))
    b = set(json.load(open(sys.argv[2])).get("packages", []))
except Exception:
    sys.exit(0)
for k in sorted(a - b):
    print(k)
PY
}

detect_drift() {
  local home_pi="${HOME}/.pi/agent"
  if [[ -d "$home_pi" ]]; then
    local miss=""
    # V2: the MCP source of truth is the shared layer, not ~/.pi/agent/mcp.json
    miss+="$(missing_servers "${PROFILES_DIR}/shared/mcp.json" "${HOME}/.agents/mcp.json")"
    miss+="$(missing_packages "${PROFILES_DIR}/global/settings.json" "${home_pi}/settings.json")"
    miss="$(printf '%s\n' "$miss" | sed '/^$/d' | sort -u)"
    if [[ -n "$miss" ]]; then
      echo "global:drift detected: $(echo "$miss" | tr '\n' ' ')"
    else
      echo "global:clean"
    fi
  else
    echo "global:environment not present on this machine"
  fi

  local p
  for p in $(project_names); do
    local ppt="${PROFILES_DIR}/projects/${p}"
    local target="${HOME}/projects/${p}/.pi"
    [[ "$p" == "projects-workspace" ]] && target="${HOME}/projects/.pi"
    if [[ -f "${ppt}/mcp.json" ]]; then
      if [[ -d "$target" ]]; then
        local miss
        miss="$(missing_servers "${ppt}/mcp.json" "${target}/mcp.json")"
        miss="$(printf '%s\n' "$miss" | sed '/^$/d' | sort -u)"
        if [[ -n "$miss" ]]; then
          echo "project:$p:drift detected: $(echo "$miss" | tr '\n' ' ')"
        else
          echo "project:$p:clean"
        fi
      else
        echo "project:$p:environment not present"
      fi
    fi
  done
}

# =============================================================================
# output
# =============================================================================
if [[ "$ATB_JSON" == "1" ]]; then
  projects="{}"
  for p in $(project_names); do
    projects="$(jq --arg p "$p" \
      --argjson s "$(project_resource_count "$p" skills)" \
      --argjson m "$(project_resource_count "$p" mcp)" \
      --argjson e "$(project_resource_count "$p" extensions)" \
      --argjson pk "$(project_resource_count "$p" packages)" \
      '. + {($p): {skills:$s, mcp:$m, extensions:$e, packages:$pk}}' <<<"$projects")"
  done
  updates="{}"
  for k in skills mcp extensions packages; do
    updates="$(jq --arg k "$k" --argjson n "$(updates_pending_group "$k")" '. + {($k): $n}' <<<"$updates")"
  done
  caps_json="$(bash "$SCRIPTS_DIR/capabilities.sh" --json 2>/dev/null || echo '{"capabilities":[]}')"
  jq -n \
    --argjson g_skills "$(global_counts_scope skills global)" \
    --argjson g_mcp "$(global_counts_scope mcp global)" \
    --argjson g_ext "$(global_counts_scope extensions global)" \
    --argjson g_pkg "$(global_counts_scope packages global)" \
    --argjson projects "$projects" \
    --argjson updates "$updates" \
    --argjson caps "$caps_json" \
    '{global:{skills:$g_skills,mcp:$g_mcp,extensions:$g_ext,packages:$g_pkg}, projects:$projects, updates:$updates, capabilities:$caps.capabilities, drift:[]}'
  exit "$EXIT_OK"
fi

echo "Agent Toolbox"
echo ""
# --- capability view (capability -> CLI/MCP -> adapter -> harness) ----------
bash "$SCRIPTS_DIR/capabilities.sh" 2>/dev/null || warn "capability view unavailable"
echo ""
echo "Registry counts"
echo "---------------"
printf '%-12s %s\n' "Skills"     "$(global_counts_scope skills global)"
printf '%-12s %s\n' "MCP"        "$(global_counts_scope mcp global)"
printf '%-12s %s\n' "Extensions" "$(global_counts_scope extensions global)"
printf '%-12s %s\n' "Packages"   "$(global_counts_scope packages global)"
echo ""
echo "Projects"
echo "--------"
for p in $(project_names); do
  echo "$p"
  printf '  %-10s %s\n' "Skills"     "$(project_resource_count "$p" skills)"
  printf '  %-10s %s\n' "MCP"        "$(project_resource_count "$p" mcp)"
  printf '  %-10s %s\n' "Extensions" "$(project_resource_count "$p" extensions)"
  printf '  %-10s %s\n' "Packages"   "$(project_resource_count "$p" packages)"
done
echo ""
echo "Updates"
echo "-------"
printf '%-12s %s\n' "Skills"     "$(updates_pending_group skills)"
printf '%-12s %s\n' "MCP"        "$(updates_pending_group mcp)"
printf '%-12s %s\n' "Extensions" "$(updates_pending_group extensions)"
printf '%-12s %s\n' "Packages"   "$(updates_pending_group packages)"
 [[ ! -f "$UPDATE_REPORT" ]] && echo "(no update report yet — run ./scripts/check-updates.sh)"
 echo ""
 echo "Drift"
 echo "-----"
 while IFS=: read -r scope name status; do
   case "$scope" in
     global)
       # global drift lines are "global:<status>" (2 fields) so state is in $name
       if [[ "$name" == "clean" ]]; then
         echo "Global config clean"
       elif [[ "$name" == "environment not present on this machine" ]]; then
         echo "Global config not checked (env absent)"
       else
         echo "Global config drift detected"
       fi
       ;;
     project)
       if [[ "$status" == "clean" ]]; then
         echo "${name} config clean"
       elif [[ "$status" == "environment not present" ]]; then
         echo "${name} config not checked (env absent)"
       else
         echo "${name} config drift detected"
       fi
       ;;
   esac
 done < <(detect_drift 2>/dev/null)
