#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — verify this machine can run the toolbox (read-only check)
#
#   ./scripts/bootstrap.sh [--json]
#
# This is a health check, NOT a setup. It never installs anything. If a check
# fails, it prints what you need to install yourself and exits non-zero.
#
# Exit codes: 0 all good, 1 missing prerequisites, 2 config error.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

parse_flags "$@"

# We build the report as JSON-decoded entries (name, status, detail, required) and
# then render either human or JSON depending on the flag.
declare -a report   # each element: name|status|required|detail

add_check() { # add_check <name> <status> <required> <detail>
  report+=("$1|$2|$3|$4")
}

# --- core toolchain --------------------------------------------------------
check_cmd() { # check_cmd <name> <cmd...>
  local name="$1" cmd="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    add_check "$name" ok required ""
  else
    add_check "$name" missing required "install '$cmd'"
  fi
}

check_opt() {
  local name="$1" cmd="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    add_check "$name" ok optional ""
  else
    add_check "$name" absent optional ""
  fi
}

check_path() { # check_path <name> <path> <required|optional>
  local name="$1" path="$2" req="$3"
  if [[ -e "$path" ]]; then
    add_check "$name" ok "$req" ""
  else
    add_check "$name" missing "$req" "expected $path"
  fi
}

check_cmd "bash" bash
check_cmd "git" git
check_cmd "jq" jq
check_cmd "npm" npm
check_cmd "node" node
check_cmd "pi" pi
check_opt "npx" npx

# --- YAML engine -----------------------------------------------------------
if command -v yq >/dev/null 2>&1; then
  add_check "yaml-engine" ok required "yq"
elif python3 -c "import yaml" >/dev/null 2>&1; then
  add_check "yaml-engine" ok required "python3 + PyYAML"
else
  add_check "yaml-engine" missing required "install yq OR python3 + PyYAML"
fi

if python3 -c "import yaml, datetime; yaml.safe_load('d: 2026-10-02')" >/dev/null 2>&1; then
  add_check "yaml-dates" ok required "PyYAML date handling"
else
  add_check "yaml-dates" missing required "PyYAML must load unquoted dates"
fi

# --- repo structure --------------------------------------------------------
check_path "manifest.yaml" "$ATB_ROOT/manifest.yaml" required
check_path "lock.yaml" "$ATB_ROOT/lock.yaml" required
check_path "catalog" "$ATB_ROOT/catalog" required
check_path "profiles" "$ATB_ROOT/profiles" required
check_path "scripts" "$ATB_ROOT/scripts" required
check_path ".github/workflows" "$ATB_ROOT/.github/workflows" optional

# --- project dirs from manifest --------------------------------------------
while IFS='|' read -r pname ppath; do
  [[ -z "$pname" ]] && continue
  ppath="${ppath/#\~/$HOME}"
  if [[ -d "$ppath" ]]; then
    add_check "project:$pname" ok optional "present"
  else
    add_check "project:$pname" missing optional "expected $ppath"
  fi
done < <(yqdata "$MANIFEST" '.profiles.projects | to_entries[] | "\(.key)|\(.value.path)"' 2>/dev/null || true)

# --- global pi agent dir ---------------------------------------------------
if [[ -d "$HOME/.pi/agent" ]]; then
  add_check "~/.pi/agent" ok optional "present"
else
  add_check "~/.pi/agent" absent optional "no global agent config"
fi

# --- render -----------------------------------------------------------------
render_json() {
  local entries=""
  for r in "${report[@]}"; do
    IFS='|' read -r n st req det <<<"$r"
    local enc
    enc=$(printf '%s' "$n" | jq -Rs .)
    entries+="{\"name\":$enc,\"status\":\"$st\",\"required\":\"$req\",\"detail\":$(printf '%s' "$det" | jq -Rs .)},"
  done
  entries="${entries%,}"
  local ok missing absent
  ok=$(for r in "${report[@]}"; do echo "$r"; done | awk -F'|' '$2=="ok"{n++}END{print n+0}')
  missing=$(for r in "${report[@]}"; do echo "$r"; done | awk -F'|' '$2=="missing"{n++}END{print n+0}')
  absent=$(for r in "${report[@]}"; do echo "$r"; done | awk -F'|' '$2=="absent"{n++}END{print n+0}')
  jq -n --argjson entries "[$entries]" \
     --argjson ok "$ok" --argjson missing "$missing" --argjson absent "$absent" \
     '{checks:$entries, summary:{ok:$ok, missing:$missing, absent:$absent}, healthy:($missing==0)}'
}

render_human() {
  echo "Agent Toolbox bootstrap"
  echo "========================"
  echo ""
  echo "Checks:"
  for r in "${report[@]}"; do
    IFS='|' read -r n st req det <<<"$r"
    case "$st" in
      ok)       printf '  ✓ %-20s %s\n' "$n" "$det" ;;
      absent)   printf '  · %-20s absent (optional)%s\n' "$n" "$( [[ -n "$det" ]] && echo " — $det")" ;;
      missing)  printf '  ✗ %-20s MISSING%s\n' "$n" "$( [[ -n "$det" ]] && echo " — $det")" ;;
    esac
  done
  echo ""
  local missing
  missing=$(for r in "${report[@]}"; do echo "$r"; done | awk -F'|' '$2=="missing"{n++}END{print n+0}')
  echo "Summary:"
  echo "  ${#report[@]} checks, $missing missing"
  if [[ "$missing" -gt 0 ]]; then
    echo ""
    echo "Install the missing prerequisites, then re-run ./scripts/bootstrap.sh"
  fi
}

if [[ "$ATB_JSON" == "1" ]]; then
  render_json
else
  render_human
fi

missing=$(for r in "${report[@]}"; do echo "$r"; done | awk -F'|' '$2=="missing"{n++}END{print n+0}')
[[ "$missing" -gt 0 ]] && exit "$EXIT_CONFIG"
exit "$EXIT_OK"
