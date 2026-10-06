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
#  12. harness adapter registry (harnesses:) — ids, strategies, formats, paths
#  13. capability registry (capabilities:) — dimensions, cross-refs into
#      resources/harnesses, installer templates, harness overrides
#  14. profile capabilities reference real capabilities; profile config files exist
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

allowed_kinds = {"skill", "mcp", "extension", "package", "prompt", "theme", "cli"}
allowed_groups = {"skills": "skill", "mcp": "mcp", "extensions": "extension",
                  "packages": "package", "prompts": "prompt", "themes": "theme",
                  "clis": "cli"}
allowed_scopes = {"global", "project"}
allowed_sources = {"local", "git", "github", "npm", "url", "builtin", "manual"}
allowed_policies = {"manual", "daily", "weekly", "monthly", "pin"}
allowed_skill_strategies = {"shared", "symlink", "installer"}
allowed_mcp_strategies = {"shared", "native", "profile"}
allowed_mcp_formats = {"mcpServers", "opencode-mcp"}
allowed_mcp_definitions = {"shared", "profile-global"}
allowed_harness_status = {"active", "planned", "installed-unverified", "verified", "unsupported"}
allowed_transports = {"stdio", "http", "sse"}
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

# ------------------------------------------------------- harness adapter registry
harness_ids = {}
if manifest:
    hs = manifest.get("harnesses")
    if hs is None:
        hs = {}
    if not isinstance(hs, dict):
        err("harnesses must be a mapping of <harness-id>: {...}")
        hs = {}
    for hid, h in sorted(hs.items()):
        if not isinstance(h, dict):
            err(f"harness '{hid}' must be a mapping")
            continue
        if h.get("id", hid) != hid:
            err(f"harness '{hid}': id '{h.get('id')}' does not match its key")
        if not h.get("config_root"):
            err(f"harness '{hid}': missing config_root")
        if h.get("status", "active") not in allowed_harness_status:
            err(f"harness '{hid}': invalid status '{h.get('status')}'")
        if h.get("skill_strategy") not in allowed_skill_strategies:
            err(f"harness '{hid}': invalid skill_strategy '{h.get('skill_strategy')}'")
        if h.get("mcp_strategy") not in allowed_mcp_strategies:
            err(f"harness '{hid}': invalid mcp_strategy '{h.get('mcp_strategy')}'")
        if h.get("mcp_format") not in allowed_mcp_formats:
            err(f"harness '{hid}': invalid mcp_format '{h.get('mcp_format')}'")
        if h.get("mcp_strategy") == "native" and not h.get("mcp_file"):
            err(f"harness '{hid}': mcp_strategy 'native' requires mcp_file")
        if h.get("skill_strategy") in ("symlink", "installer") and not h.get("skill_dir"):
            err(f"harness '{hid}': skill_strategy '{h.get('skill_strategy')}' requires skill_dir")
        if h.get("installer_ids") and not isinstance(h.get("installer_ids"), dict):
            err(f"harness '{hid}': installer_ids must be a mapping")
        harness_ids[hid] = h

# ---------------------------------------------------------- capability registry
caps = {}
if manifest:
    raw_caps = manifest.get("capabilities")
    if raw_caps is None:
        raw_caps = {}
    if not isinstance(raw_caps, dict):
        err("capabilities must be a mapping of <capability-id>: {...}")
        raw_caps = {}
    caps = raw_caps
    for cid, c in sorted(caps.items()):
        if not isinstance(c, dict):
            err(f"capability '{cid}' must be a mapping")
            continue
        if c.get("id", cid) != cid:
            err(f"capability '{cid}': id '{c.get('id')}' does not match its key")
        if not c.get("name"):
            err(f"capability '{cid}': missing name")
        if not c.get("description"):
            err(f"capability '{cid}': missing description")
        cli, skills, mcp = c.get("cli"), c.get("skills"), c.get("mcp")
        if not (cli or skills or mcp):
            err(f"capability '{cid}': declares no cli, skills or mcp dimension")
        if cli:
            if not isinstance(cli, dict) or not cli.get("command"):
                err(f"capability '{cid}': cli.command is required")
            else:
                r = cli.get("resource")
                grp = seen_ids.get(r) if r else None
                if not r:
                    err(f"capability '{cid}': cli.resource is required")
                elif grp is None:
                    err(f"capability '{cid}': cli.resource '{r}' is not in manifest resources")
                elif grp != "clis":
                    err(f"capability '{cid}': cli.resource '{r}' must live in the clis group (got '{grp}')")
                up = cli.get("updater")
                if up is not None and (not up.get("command") or not isinstance(up.get("args"), list)):
                    err(f"capability '{cid}': cli.updater needs command + args list")
        if skills is not None:
            if not isinstance(skills, list) or not skills:
                err(f"capability '{cid}': skills must be a non-empty list")
            else:
                for s in skills:
                    if not isinstance(s, dict):
                        err(f"capability '{cid}': skills entry must be a mapping")
                        continue
                    r = s.get("resource")
                    grp = seen_ids.get(r) if r else None
                    if not r:
                        err(f"capability '{cid}': skills entry missing resource")
                    elif grp is None:
                        err(f"capability '{cid}': skills.resource '{r}' is not in manifest resources")
                    elif grp != "skills":
                        err(f"capability '{cid}': skills.resource '{r}' must live in the skills group (got '{grp}')")
                    if not s.get("shared_path"):
                        err(f"capability '{cid}': skills entry '{r}' missing shared_path (single source of truth)")
        if mcp is not None:
            if not isinstance(mcp, dict):
                err(f"capability '{cid}': mcp must be a mapping")
            else:
                if not mcp.get("server_name"):
                    err(f"capability '{cid}': mcp.server_name is required")
                if mcp.get("definition") not in allowed_mcp_definitions:
                    err(f"capability '{cid}': mcp.definition must be one of {sorted(allowed_mcp_definitions)}")
                if mcp.get("transport") is not None and mcp.get("transport") not in allowed_transports:
                    err(f"capability '{cid}': invalid mcp.transport '{mcp.get('transport')}'")
        inst = c.get("installer")
        if inst is not None:
            if not isinstance(inst, dict) or not inst.get("command"):
                err(f"capability '{cid}': installer.command is required")
            elif not isinstance(inst.get("args"), list) or not inst.get("id"):
                err(f"capability '{cid}': installer needs id + args list")
            elif "{id}" not in " ".join(str(a) for a in inst["args"]):
                err("capability '" + cid + "': installer.args must contain the "
                    "'{id}' harness-id placeholder")
        hc = c.get("harnesses")
        if not isinstance(hc, dict) or not hc:
            err(f"capability '{cid}': must declare a non-empty harnesses mapping")
        else:
            for hid, ov in sorted(hc.items()):
                if hid not in harness_ids:
                    err(f"capability '{cid}': unknown harness '{hid}'")
                    continue
                if not isinstance(ov, dict):
                    err(f"capability '{cid}': harness override '{hid}' must be a mapping")
                    continue
                ss, ms = ov.get("skill_strategy"), ov.get("mcp_strategy")
                if ss is not None and ss not in allowed_skill_strategies:
                    err(f"capability '{cid}': harness '{hid}' invalid skill_strategy '{ss}'")
                if ms is not None and ms not in allowed_mcp_strategies:
                    err(f"capability '{cid}': harness '{hid}' invalid mcp_strategy '{ms}'")
                if skills and not (ss or harness_ids[hid].get("skill_strategy")):
                    err(f"capability '{cid}': harness '{hid}' has no resolvable skill_strategy")
                if mcp and not (ms or harness_ids[hid].get("mcp_strategy")):
                    err(f"capability '{cid}': harness '{hid}' has no resolvable mcp_strategy")

# ------------------------------------------------- profile <-> capability refs
if manifest:
    profiles = manifest.get("profiles") or {}

    def _check_profile_caps(lst, where):
        if lst is None:
            return
        if not isinstance(lst, list):
            err(f"{where}: must be a list of capability ids")
            return
        for c in lst:
            if c not in caps:
                err(f"{where}: unknown capability '{c}'")

    _check_profile_caps((profiles.get("global") or {}).get("capabilities"),
                        "profiles.global.capabilities")
    for pname, p in sorted((profiles.get("projects") or {}).items()):
        _check_profile_caps(p.get("capabilities"), f"profiles.projects.{pname}.capabilities")
    # every config file referenced by a profile must exist
    def _check_profile_files(cfg, where):
        if not isinstance(cfg, dict):
            return
        for key, rel in cfg.items():
            if not isinstance(rel, str):
                continue
            if key in ("skills", "extensions") or rel.startswith("~"):
                continue
            if not os.path.exists(os.path.join(root, rel)):
                err(f"{where}: referenced config file missing: {rel}")
    _check_profile_files((profiles.get("shared") or {}).get("config"), "profiles.shared")
    _check_profile_files((profiles.get("global") or {}).get("config"), "profiles.global")
    for pname, p in sorted((profiles.get("projects") or {}).items()):
        _check_profile_files(p.get("config"), f"profiles.projects.{pname}")

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
