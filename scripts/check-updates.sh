#!/usr/bin/env bash
# =============================================================================
# check-updates.sh — probe upstream for newer versions and report / prepare PR
#
#   ./scripts/check-updates.sh               human-readable summary
#   ./scripts/check-updates.sh --json        machine-readable JSON (for CI)
#   ./scripts/check-updates.sh --mock        use tests/fixtures (no network)
#   ./scripts/check-updates.sh --apply       update manifest + lock + report
#
# Policy mapping (from manifest update.policy):
#   pin      -> never propose an update
#   manual   -> only checked when you run this script
#   daily/weekly/monthly -> checked (GitHub Actions schedules this)
#
# Upstream resolution by source.type:
#   npm      -> npm view <package> version
#   github/git -> git ls-remote --tags (only when source.ref is set)
#   url      -> hosted endpoint, no local version; reported as-is
#   local/builtin/manual -> skipped (no resolvable upstream)
#
# IMPORTANT: this never runs `pi install` / `pi update`. It only resolves and
# writes the manifest/lock/report inside this repo. Installing to your real
# machine is done by ./scripts/install.sh (explicitly).
#
# Exit codes: 0 no updates, 1 updates available, 2 config/validation failure.
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

parse_flags "$@"
command -v python3 >/dev/null 2>&1 || die "check-updates.sh requires python3"
command -v jq >/dev/null 2>&1 || die "check-updates.sh requires jq"

# validate first (lightweight) so we never proceed on a broken manifest
./scripts/validate.sh >/dev/null 2>&1 || die "validation failed; fix manifest/lock first"

MOCK_ARGS=()
[[ "$ATB_MOCK" == "1" ]] && MOCK_ARGS+=(--mock)

# ----------------------------------------------------------------------------
# resolution in python (handles npm/git/url/local, with mock support)
# ----------------------------------------------------------------------------
python3 - "$ATB_ROOT" "$ATB_JSON" "$ATB_APPLY" "${MOCK_ARGS[@]}" <<'PY'
import sys, os, json, subprocess, re
from datetime import date
import yaml

root, as_json, do_apply = sys.argv[1], sys.argv[2] == "1", sys.argv[3] == "1"
mock = "--mock" in sys.argv

def load(p):
    with open(p) as fh:
        return yaml.safe_load(fh)

def save_yaml(p, data):
    with open(p, "w") as fh:
        yaml.safe_dump(data, fh, sort_keys=False, allow_unicode=True, default_flow_style=False)

def load_mock():
    p = os.path.join(root, "tests", "fixtures", "npm-versions.json")
    if os.path.exists(p):
        with open(p) as fh:
            return json.load(fh)
    return {}

MANIFEST = load(os.path.join(root, "manifest.yaml"))
LOCK = load(os.path.join(root, "lock.yaml"))
NPM_MOCK = load_mock()

def npm_latest(pkg):
    if mock:
        return NPM_MOCK.get(pkg)
    try:
        out = subprocess.run(["npm", "view", pkg, "version"],
                             capture_output=True, text=True, timeout=30)
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return None

def git_latest_tags(url, ref):
    # returns the latest tag that matches the current ref family prefix, e.g. v*
    if mock:
        return None
    try:
        out = subprocess.run(["git", "ls-remote", "--tags", url],
                             capture_output=True, text=True, timeout=45)
    except Exception:
        return None
    if out.returncode != 0:
        return None
    tags = {}
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        sha, refname = parts[0], parts[1]
        refname = refname.replace("refs/tags/", "").replace("^{}", "")
        if refname.endswith("^{}"):
            continue
        tags[refname] = sha
    if not tags:
        return None
    # prefer a tag whose prefix matches current ref, else semantic highest
    if ref:
        pfxs = [ref]
        for t in tags:
            if t.startswith(ref):
                return (t, tags[t])
    # pick highest semver-ish tag
    key = lambda t: [int(x) if x.isdigit() else 0 for x in re.findall(r"\d+", t)]
    best = max(tags, key=key)
    return (best, tags[best])

updates = []       # {id,kind,scope,source,current,latest,executable,security_review_required,command_changed}
pinned = 0
manual_skip = 0
uptodate = 0
hosted = 0
skipped = 0
errors = []

def is_executable(kind):
    return kind in ("extension", "package", "mcp")

for group, items in (MANIFEST.get("resources") or {}).items():
    for res in items:
        rid = res.get("id"); kind = res.get("kind"); scope = res.get("scope")
        src = res.get("source") or {}
        pol = (res.get("update") or {}).get("policy", "manual")
        cur = (res.get("resolution") or {}).get("version", "")
        cur_ref = src.get("ref", "")
        stype = src.get("type", "manual")

        if pol == "pin":
            pinned += 1; continue
        if pol == "manual":
            manual_skip += 1; continue
        # checkable: daily/weekly/monthly
        latest = None
        lang = None
        if stype == "npm":
            latest = npm_latest(src.get("package", ""))
            lang = "npm"
        elif stype in ("github", "git") and src.get("url"):
            if cur_ref:
                r = git_latest_tags(src["url"], cur_ref)
                if r:
                    latest, latest_commit = r[0], r[1]
                    lang = "git"
            else:
                skipped += 1; continue
        elif stype == "url":
            hosted += 1; continue
        else:
            skipped += 1; continue

        if latest is None:
            skipped += 1; continue

        cur_norm = str(cur) if cur else str(cur_ref)
        if latest == cur_norm:
            uptodate += 1
            continue

        # figure out whether the MCP command/url/args changed (only for mcp)
        command_changed = False
        if kind == "mcp":
            rt = res.get("runtime") or {}
            command_changed = bool(rt.get("command") or rt.get("url"))

        updates.append({
            "id": rid, "name": res.get("name", rid), "kind": kind,
            "scope": scope,
            "source": f"{stype}:{src.get('package') or src.get('url') or ''}",
            "current": cur_norm, "latest": latest,
            "executable": is_executable(kind),
            "security_review_required": is_executable(kind) or (res.get("security") or {}).get("review_required", False),
            "projects": res.get("projects", []),
            "command_changed": command_changed,
        })

# ---- maybe apply ----------------------------------------------------------
report_path = os.path.join(root, "CHANGELOG", "update-report.json")
if do_apply:
    # bump manifest.resolution + source.ref for npm (latest is the new version)
    for u in updates:
        for group, items in (MANIFEST.get("resources") or {}).items():
            for res in items:
                if res.get("id") != u["id"]:
                    continue
                res.setdefault("resolution", {})["version"] = u["latest"]
                res.setdefault("resolution", {})["commit"] = u.get("latest_commit", "")
                res.setdefault("resolution", {})["checked_at"] = date.today().isoformat()
                if res.get("source", {}).get("type") == "npm":
                    res["source"]["ref"] = u["latest"]
                if res.get("source", {}).get("type") in ("github", "git"):
                    res["source"]["ref"] = u["latest"]
    save_yaml(os.path.join(root, "manifest.yaml"), MANIFEST)
    # regenerate lock from manifest
    now = date.today().isoformat()
    lock = {"schema_version": 1, "resources": {}}
    for group, items in (MANIFEST.get("resources") or {}).items():
        for res in items:
            rid = res.get("id"); src = res.get("source") or {}; resv = res.get("resolution") or {}
            lock["resources"][rid] = {
                "requested": {"source": src.get("type", ""),
                              **({"url": src.get("url")} if src.get("url") else {}),
                              **({"package": src.get("package")} if src.get("package") else {}),
                              **({"path": src.get("path")} if src.get("path") else {}),
                              "ref": src.get("ref", "")},
                "resolved": {"version": resv.get("version", ""), "commit": resv.get("commit", "")},
                "checked_at": resv.get("checked_at", now),
            }
    save_yaml(os.path.join(root, "lock.yaml"), lock)
    os.makedirs(os.path.dirname(report_path), exist_ok=True)
    with open(report_path, "w") as fh:
        json.dump({"generated_at": date.today().isoformat(), "updates": updates}, fh, indent=2)
    print(f"Applied {len(updates)} update(s): manifest.yaml + lock.yaml + {os.path.relpath(report_path, root)}")

# ---- output ----------------------------------------------------------------
if as_json:
    print(json.dumps({"updates": updates, "count": len(updates),
                      "summary": {"updates": len(updates), "pinned": pinned,
                                  "up_to_date": uptodate, "hosted": hosted,
                                  "skipped": skipped, "manual": manual_skip},
                      "valid": not errors}, indent=2))
else:
    groups = {}
    for u in updates:
        groups.setdefault(u["kind"], []).append(u)
    print("Agent Toolbox Update Check")
    print("")
    labels = {"skill": "Skills", "mcp": "MCP", "extension": "Extensions",
              "package": "Packages", "prompt": "Prompts", "theme": "Themes"}
    for kind in ("skill", "mcp", "extension", "package", "prompt", "theme"):
        us = [u for u in updates if u["kind"] == kind]
        if not us:
            continue
        print(labels[kind])
        for u in us:
            flag = "↑"
            print(f"  {flag} {u['id']:<28} {u['current']} -> {u['latest']}  ({u['source']})")
        print("")
    print("Summary:")
    print(f"  {len(updates)} update(s) available")
    print(f"  {pinned} pinned")
    print(f"  {uptodate} up to date")
    print(f"  {skipped} skipped (no resolvable upstream)")
    print(f"  {hosted} hosted (no local version)")
sys.exit(1 if updates else 0)
PY
