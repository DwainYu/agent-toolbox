#!/usr/bin/env bash
# =============================================================================
# sync.sh — compare manifest (want) vs lock (have) and report drift
#
#   ./scripts/sync.sh                    global + all projects
#   ./scripts/sync.sh global
#   ./scripts/sync.sh project <name>
#   ./scripts/sync.sh all
#   ./scripts/sync.sh --write-lock       regenerate lock.yaml from manifest
#
# sync is NOT update. It only compares and reports. It never touches upstream
# or installs anything. To update upstream, use ./scripts/check-updates.sh.
#
# Exit codes: 0 ok, 1 drift found (differences), 2 config error.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

parse_flags "$@"
command -v python3 >/dev/null 2>&1 || die "sync.sh requires python3"

ask="${ATB_POS[0]:-all}"

if [[ "$ATB_WRITE_LOCK" == "1" ]]; then
  # Regenerate lock.yaml from manifest.resolution
  python3 - "$ATB_ROOT" <<'PY'
import sys, os, yaml, json
from datetime import date
root = sys.argv[1]
def load(p):
    with open(p) as fh: return yaml.safe_load(fh)
manifest = load(os.path.join(root, "manifest.yaml"))
out = {"schema_version": 1, "resources": {}}
now = date.today().isoformat()
for group, items in (manifest.get("resources") or {}).items():
    for res in items:
        rid = res.get("id")
        src = res.get("source") or {}
        resv = res.get("resolution") or {}
        out["resources"][rid] = {
            "requested": {
                "source": src.get("type", ""),
                **({"url": src.get("url")} if src.get("url") else {}),
                **({"package": src.get("package")} if src.get("package") else {}),
                **({"path": src.get("path")} if src.get("path") else {}),
                **({"ref": src.get("ref")} if src.get("ref") is not None else {"ref": ""}),
            },
            "resolved": {
                "version": resv.get("version", ""),
                "commit": resv.get("commit", ""),
            },
            "checked_at": resv.get("checked_at", now),
        }
with open(os.path.join(root, "lock.yaml"), "w") as fh:
    yaml.safe_dump(out, fh, sort_keys=False, allow_unicode=True, default_flow_style=False)
print("lock.yaml regenerated from manifest.resolution.")
PY
  exit "$EXIT_OK"
fi

# ----------------------------------------------------------------------------
# compare manifest vs lock
# ----------------------------------------------------------------------------
python3 - "$ATB_ROOT" "$ask" <<'PY'
import sys, os, yaml
root = sys.argv[1]
ask = sys.argv[2]
def load(p):
    with open(p) as fh: return yaml.safe_load(fh)
manifest = load(os.path.join(root, "manifest.yaml"))
lock = load(os.path.join(root, "lock.yaml"))

lock_res = lock.get("resources", {})
issues = []      # list of (id, kind, message)
up_to_date = 0

for group, items in (manifest.get("resources") or {}).items():
    for res in items:
        rid = res.get("id")
        kind = res.get("kind")
        scope = res.get("scope")
        # scope filter
        if ask == "global" and scope != "global":
            continue
        if ask.startswith("project") and scope != "project":
            continue
        req_src = (res.get("source") or {}).get("type", "")
        req_ref = (res.get("source") or {}).get("ref", "")
        entry = lock_res.get(rid)
        if entry is None:
            issues.append((rid, kind, "not present in lock.yaml"))
            continue
        lk_req = entry.get("requested", {})
        lk_req_src = lk_req.get("source", "")
        lk_req_ref = lk_req.get("ref", "")
        if lk_req_src != req_src:
            issues.append((rid, kind, f"source drift: manifest={req_src} lock={lk_req_src}"))
        elif str(lk_req_ref or "") != str(req_ref or ""):
            issues.append((rid, kind, f"ref drift: manifest={req_ref} lock={lk_req_ref}"))
        else:
            up_to_date += 1
        # note unknown lock entries
for rid in lock_res:
    if rid not in [r.get("id") for g in (manifest.get("resources") or {}).values() for r in g]:
        issues.append((rid, "unknown", "present in lock.yaml but not in manifest"))

if issues:
    print("Drift detected:")
    for rid, kind, msg in issues:
        print(f"  [{kind}] {rid}: {msg}")
    print(f"\n{len(issues)} drift item(s), {up_to_date} in sync.")
    sys.exit(1)
else:
    print(f"All resources in sync ({up_to_date} declared). No drift.")
    sys.exit(0)
PY
