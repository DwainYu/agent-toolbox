#!/usr/bin/env bash
# =============================================================================
# install.sh — apply toolbox profiles to the live environment (explicit only)
#
#   ./scripts/install.sh global                     dry-run preview
#   ./scripts/install.sh global --dry-run           dry-run preview
#   ./scripts/install.sh global --apply             actually write ~/.pi/agent/
#   ./scripts/install.sh project <name> [--target /path] [--dry-run|--apply]
#
# Principles:
#   * NEVER overwrite unknown/existing configuration. We only ADD what the
#     profile declares and is missing. Existing differing values are preserved.
#   * Idempotent: running again is a no-op when already in sync.
#   * Backup before any write (<file>.atb-backup.<ts>).
#   * Default is dry-run; you must pass --apply to change the machine.
#
# Exit codes: 0 ok, 2 config error.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

parse_flags "$@"
command -v python3 >/dev/null 2>&1 || die "install.sh requires python3"

if [[ "${ATB_POS[0]:-}" == "global" ]]; then
  MODE="global"
elif [[ "${ATB_POS[0]:-}" == "project" ]]; then
  MODE="project"
  PROJECT="${ATB_POS[1]:-}"
  [[ -z "$PROJECT" ]] && die "usage: ./scripts/install.sh project <name> [--target /path]"
else
  die "usage: ./scripts/install.sh global|project <name> [flags]"
fi

# ----------------------------------------------------------------------------
# merge plan/apply in python
# ----------------------------------------------------------------------------
# merge_config <mode> <profile-json> <target-json> <ctype> <label>
#   ctype: settings | mcp
#   mode:  plan | apply
merge_config() {
  local mode="$1" prof="$2" target="$3" ctype="$4" label="$5"
  die_if_not_file "$prof" "profile"
  python3 - "$mode" "$prof" "$target" "$ctype" "$label" <<'PY'
import sys, os, json, shutil, time
mode, prof, target, ctype, label = sys.argv[1:6]

try:
    with open(prof) as fh:
        profile = json.load(fh)
except Exception as e:
    print(f"ERROR: {label}: profile does not parse: {e}", file=sys.stderr)
    sys.exit(2)

target_data = {}
if os.path.exists(target):
    try:
        with open(target) as fh:
            target_data = json.load(fh)
    except Exception as e:
        print(f"ERROR: {label}: target does not parse: {e}", file=sys.stderr)
        sys.exit(2)

added = []      # identifiers that would be added
preserved = []  # identifiers that already exist / differ (kept)
modified = []   # files that would change

if ctype == "settings":
    prof_pkgs = profile.get("packages", [])
    tgt_pkgs = target_data.get("packages", [])
    for p in prof_pkgs:
        if p not in tgt_pkgs:
            added.append(p)
        else:
            preserved.append(p)
    # theme: set only if target lacks it
    if "theme" in profile and "theme" not in target_data:
        added.append(f"theme={profile['theme']}")
    elif "theme" in profile:
        preserved.append(f"theme={target_data.get('theme','')}")
    # extensions
    for e in profile.get("extensions", []):
        if e not in target_data.get("extensions", []):
            added.append(f"extension:{e}")
        else:
            preserved.append(f"extension:{e}")
    # other existing keys we never touch
    for k in target_data:
        if k not in ("packages", "theme", "extensions"):
            preserved.append(f"key:{k} (user-owned, preserved)")
    if added:
        modified.append(target)

elif ctype == "mcp":
    prof_servers = profile.get("mcpServers", {})
    tgt_servers = target_data.get("mcpServers", {})
    for sid in prof_servers:
        if sid not in tgt_servers:
            added.append(sid)
        elif tgt_servers[sid] != prof_servers[sid]:
            preserved.append(f"{sid} (existing differs, preserved)")
        else:
            preserved.append(sid)
    for sid in tgt_servers:
        if sid not in prof_servers:
            preserved.append(f"{sid} (unknown existing server, preserved)")
    if added:
        modified.append(target)

# ---- output ---------------------------------------------------------------
if mode == "apply":
    if os.path.exists(target):
        ts = time.strftime("%Y%m%d-%H%M%S")
        shutil.copy2(target, f"{target}.atb-backup.{ts}")
    if ctype == "settings":
        new = dict(target_data)
        new.setdefault("packages", [])
        for p in added:
            if p not in new["packages"] and not p.startswith("theme="):
                new["packages"].append(p)
        if "theme" in profile and "theme" not in new:
            new["theme"] = profile["theme"]
        if "extensions" in profile and "extensions" not in new:
            new["extensions"] = profile["extensions"]
        mode_json = json.dumps(new, indent=2, ensure_ascii=False) + "\n"
    else:
        new = dict(target_data)
        new.setdefault("mcpServers", {})
        for sid, cfg in profile.get("mcpServers", {}).items():
            if sid not in new["mcpServers"]:
                new["mcpServers"][sid] = cfg
        mode_json = json.dumps(new, indent=2, ensure_ascii=False) + "\n"
    os.makedirs(os.path.dirname(target), exist_ok=True)
    with open(target, "w") as fh:
        fh.write(mode_json)
    for a in added:
        print(f"  + {a}")
    print(f"  wrote {target}")
else:
    if added:
        print(f"Would modify: {target}")
        for a in added:
            print(f"  + {a}")
    else:
        print(f"Would leave unchanged: {target}")
    if preserved:
        for p in preserved:
            print(f"  ~ preserve: {p}")
PY
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
