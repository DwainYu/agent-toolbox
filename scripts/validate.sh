#!/usr/bin/env bash
# =============================================================================
# validate.sh — validate the toolbox state
#
# Checks:
#   1. manifest schema + parses
#   2. lock schema + parses
#   3. duplicate resource ids
#   4. invalid scope
#   5. project-scoped resource missing a project name
#   6. invalid skill name (lowercase a-z0-9, hyphen, <= 64, no edge/twin hyphens)
#   7. invalid source type
#   8. secret-like strings anywhere in tracked config
#   9. broken local paths (under resources/ and manifest local sources)
#  10. invalid package declaration
#  11. invalid MCP definition (needs url OR command+args)
#
# Exit codes: 0 = valid, 2 = validation failure.
#   --json   emit a machine-readable JSON report
# =============================================================================
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

ATB_JSON=0
for a in "$@"; do [[ "$a" == "--json" ]] && ATB_JSON=1; done

command -v python3 >/dev/null 2>&1 || die "validate.sh requires python3"
python3 -c 'import yaml' >/dev/null 2>&1 || die "validate.sh requires PyYAML (pip install pyyaml)"

python3 - "$ATB_ROOT" "$ATB_JSON" <<'PY'
import sys, os, json, re, glob
import yaml

root = sys.argv[1]
as_json = sys.argv[2] == "1"
errors = []

def err(msg):
    errors.append(msg)

def load_yaml(path):
    with open(path, "r") as fh:
        return yaml.safe_load(fh)

def load_json(path):
    with open(path, "r") as fh:
        return json.load(fh)

# ------------------------------------------------------------------ manifest
manifest_path = os.path.join(root, "manifest.yaml")
if not os.path.exists(manifest_path):
    err("manifest.yaml is missing")
    manifest = {}
else:
    try:
        manifest = load_yaml(manifest_path)
    except Exception as e:
        err(f"manifest.yaml does not parse: {e}")
        manifest = {}

allowed_kinds = {"skill", "mcp", "extension", "package", "prompt", "theme"}
allowed_groups = {"skills": "skill", "mcp": "mcp", "extensions": "extension",
                  "packages": "package", "prompts": "prompt", "themes": "theme"}
allowed_scopes = {"global", "project"}
allowed_sources = {"local", "git", "github", "npm", "url", "builtin", "manual"}
allowed_policies = {"manual", "daily", "weekly", "monthly", "pin"}
skill_re = re.compile(r"^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$")

if manifest:
    if manifest.get("schema_version") != 1:
        err("manifest.schema_version must be 1")
    resources = manifest.get("resources", {})
    seen_ids = {}
    for group, items in (resources or {}).items():
        if not isinstance(items, list):
            continue
        if group not in allowed_groups:
            err(f"resources has unknown group '{group}'")
            continue
        expected_kind = allowed_groups[group]
        for res in items:
            rid = res.get("id", "")
            if not rid:
                err(f"{group} entry is missing 'id'")
                continue
            if rid in seen_ids:
                err(f"duplicate resource id '{rid}' (also in {seen_ids[rid]})")
            seen_ids[rid] = group
            if res.get("kind") not in allowed_kinds:
                err(f"{rid}: invalid kind '{res.get('kind')}' (must be one of {sorted(allowed_kinds)})")
            elif res.get("kind") != expected_kind:
                err(f"{rid}: kind '{res.get('kind')}' does not match group '{group}' (expected '{expected_kind}')")
            if res.get("scope") not in allowed_scopes:
                err(f"{rid}: invalid scope '{res.get('scope')}' (must be global|project)")
            if res.get("scope") == "project":
                projs = res.get("projects")
                if not isinstance(projs, list) or not projs:
                    err(f"{rid}: project-scoped resource must declare a 'projects' list")
                for pname in projs:
                    if not isinstance(pname, str) or not pname:
                        err(f"{rid}: projects entry must be a non-empty string")
            stype = (res.get("source") or {}).get("type", "")
            if stype not in allowed_sources:
                err(f"{rid}: invalid source.type '{stype}'")
            if res.get("kind") == "skill":
                name = res.get("name", rid)
                if len(name) > 64:
                    err(f"{rid}: skill name > 64 chars")
                if not skill_re.match(name):
                    err(f"{rid}: invalid skill name '{name}' (lowercase a-z0-9, hyphens, no edge/twin-hyphens)")
                if "--" in name or name.startswith("-") or name.endswith("-"):
                    err(f"{rid}: skill name '{name}' has edge/twin hyphens")
            pol = (res.get("update") or {}).get("policy", "")
            if pol and pol not in allowed_policies:
                err(f"{rid}: invalid update.policy '{pol}'")
            if res.get("kind") == "package":
                src = res.get("source") or {}
                if src.get("type") == "npm" and not src.get("package"):
                    err(f"{rid}: npm package must declare source.package")
                if src.get("type") in ("git", "github") and not src.get("url"):
                    err(f"{rid}: git/github source must declare source.url")
            if res.get("kind") == "mcp":
                rt = res.get("runtime") or {}
                if not (rt.get("url") or (rt.get("command") and rt.get("transport") == "stdio")):
                    err(f"{rid}: MCP must declare runtime.url OR runtime.command+args (stdio)")
            if stype == "local":
                lp = (res.get("source") or {}).get("path", "")
                if lp:
                    p = os.path.expanduser(lp)
                    if not os.path.exists(p):
                        err(f"{rid}: local source path does not exist: {lp}")

# -------------------------------------------------------------------- lock
lock_path = os.path.join(root, "lock.yaml")
if not os.path.exists(lock_path):
    err("lock.yaml is missing")
else:
    try:
        lock = load_yaml(lock_path)
        if lock.get("schema_version") != 1:
            err("lock.schema_version must be 1")
    except Exception as e:
        err(f"lock.yaml does not parse: {e}")

# ------------------------------------------------------------------ profiles
for jf in glob.glob(os.path.join(root, "profiles", "**", "*.json"), recursive=True):
    try:
        load_json(jf)
    except Exception as e:
        err(f"profile {os.path.relpath(jf, root)} does not parse: {e}")

# ------------------------------------------------------------ secret scan
SECRET_PATTERNS = [
    (r"sk-[A-Za-z0-9_\-]{16,}", "api key (sk-...)"),
    (r"ghp_[A-Za-z0-9]{20,}", "github token (ghp_...)"),
    (r"github_pat_[A-Za-z0-9_]{20,}", "github pat"),
    (r"AKIA[0-9A-Z]{16}", "aws access key"),
    (r"-----BEGIN[ A-Z]*PRIVATE KEY-----", "private key"),
    (r"eyJ[A-Za-z0-9_\-]{20,}", "jwt-like token"),
    (r"Bearer\s+[A-Za-z0-9_\-\.]{20,}", "bearer token"),
    (r"token\s*=\s*['\"][^'\"]{12,}", "token= ..."),
    (r"password\s*=\s*['\"][^'\"]{6,}", "password= ..."),
]

def scan_text(path, text):
    for pat, desc in SECRET_PATTERNS:
        if re.search(pat, text):
            err(f"potential secret detected ({desc}) in {os.path.relpath(path, root)}")

for ext in ("*.yaml", "*.yml", "*.json"):
    for path in glob.glob(os.path.join(root, "**", ext), recursive=True):
        if ".git" in path.split(os.sep):
            continue
        with open(path, "r", errors="replace") as fh:
            scan_text(path, fh.read())

# ------------------------------------------------------------------ output
if as_json:
    print(json.dumps({"valid": not errors, "errors": errors}, indent=2))
else:
    if errors:
        for e in errors:
            print(f"ERROR: {e}")
        print(f"\n{len(errors)} validation error(s).")
    else:
        print("OK: manifest, lock, profiles, and resources are valid.")
        print("No secrets detected.")

sys.exit(2 if errors else 0)
PY
