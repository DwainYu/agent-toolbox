#!/usr/bin/env python3
# =============================================================================
# capability.py — capability / harness-adapter engine for agent-toolbox
#
# This is the implementation behind the thin shell wrappers in scripts/.
# It never re-implements an upstream installer: skills are attached with links
# or by delegating to the capability's official installer (bsk / npx skills),
# MCP definitions are mirrored add-only into a harness's native config, and the
# CLI itself is only ever probed -- never downloaded or copied.
#
# Subcommands:
#   matrix                       capability x harness overview
#   install <capability>         plan/apply adapters for one capability
#   doctor                       read-only health check of CLI/skill/MCP/adapters
#   update                       tool + adapter update lifecycle
#
# Exit codes: 0 ok / nothing to do, 1 issues or actions reported, 2 config error.
# =============================================================================
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

try:
    import yaml
except ImportError:  # pragma: no cover
    print("ERROR: PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from merge_config import (  # noqa: E402
    MCP_KEY,
    backup_file,
    load_json,
    merge_mcp_servers,
    apply_mcp_servers,
    to_format,
    write_json,
)

EXIT_OK = 0
EXIT_ISSUES = 1
EXIT_CONFIG = 2

OK, WARN, MISSING, ERROR = "ok", "warn", "missing", "error"
STATE_ICON = {OK: "✓", WARN: "⚠", MISSING: "✗", ERROR: "✗"}

# skill adapter states (docs/adapters.md). A copy is NOT a duplicated
# capability: the CLI/MCP body always lives once. These states only describe
# how the adapter folder physically presents itself to one harness.
S_SHARED = "shared"           # harness scans the shared dir directly
S_LINK = "symlink"            # symlink in harness dir -> shared source
S_MANAGED_COPY = "managed-copy"  # installer-produced copy, provenance verified
S_FOREIGN = "foreign-copy"    # copy/link whose provenance cannot be proven
S_BROKEN = "broken"           # dangling symlink or incomplete skill dir
S_ABSENT = "absent"


def expand(path):
    if not path:
        return path
    return os.path.expanduser(os.path.expandvars(str(path)))


def repo_root():
    return os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))


def log(msg=""):
    print(msg)


def rel(path, root):
    try:
        if path.startswith(root):
            return "~/" + os.path.relpath(path, os.path.expanduser("~"))
    except Exception:
        pass
    return path


def norm_source(url):
    """'https://github.com/alibaba/open-code-review(.git)' -> 'alibaba/open-code-review'."""
    u = str(url or "").strip().lower()
    u = re.sub(r"^(https?://|ssh://|git@)", "", u)
    u = re.sub(r"\.git$", "", u)
    parts = [p for p in u.replace(":", "/").split("/") if p]
    if parts and "." in parts[0]:  # drop the host segment
        parts = parts[1:]
    return "/".join(parts)


def dir_fingerprint(root):
    """{relpath: sha256|link-target} for every file, or None if unreadable."""
    files = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            p = os.path.join(dirpath, fn)
            r = os.path.relpath(p, root)
            if os.path.islink(p):
                files[r] = "link:" + os.readlink(p)
                continue
            try:
                with open(p, "rb") as fh:
                    files[r] = "sha:" + hashlib.sha256(fh.read()).hexdigest()
            except Exception:
                return None
    return files or None


class Registry(object):
    """Read-only view over manifest.yaml + lock.yaml."""

    def __init__(self, root=None):
        self.root = root or repo_root()
        self.manifest_path = os.path.join(self.root, "manifest.yaml")
        self.lock_path = os.path.join(self.root, "lock.yaml")
        if not os.path.exists(self.manifest_path):
            raise FileNotFoundError("manifest.yaml not found at %s" % self.manifest_path)
        with open(self.manifest_path) as fh:
            self.m = yaml.safe_load(fh) or {}
        self.caps = self.m.get("capabilities") or {}
        self.harnesses = self.m.get("harnesses") or {}
        self.profiles = self.m.get("profiles") or {}
        self.resources = {}
        self.group_of = {}
        for group, items in (self.m.get("resources") or {}).items():
            for r in items or []:
                if isinstance(r, dict) and r.get("id"):
                    self.resources[r["id"]] = r
                    self.group_of[r["id"]] = group
        shared_root = (self.m.get("toolbox") or {}).get("shared_root") or "~/.agents"
        self.shared = expand(shared_root)
        self.shared_skills = os.path.join(self.shared, "skills")
        self.shared_mcp = os.path.join(self.shared, "mcp.json")
        # the official `skills` CLI records installer provenance here
        self.skill_lock_path = os.path.join(self.shared, ".skill-lock.json")
        self._skill_lock = None

    # -- lookups ----------------------------------------------------------
    def cap(self, cid):
        if cid not in self.caps:
            raise KeyError("unknown capability '%s' (known: %s)"
                           % (cid, ", ".join(sorted(self.caps))))
        return self.caps[cid]

    def harness(self, hid):
        if hid not in self.harnesses:
            raise KeyError("unknown harness '%s' (known: %s)"
                           % (hid, ", ".join(sorted(self.harnesses))))
        return self.harnesses[hid]

    def active_harnesses(self):
        """Harnesses in the support matrix. 'verified' is operationally the same
        commitment as 'active' — both participate; nothing else does."""
        return [h for h in self.harnesses.values()
                if h.get("status", "active") in ("active", "verified")]

    def lifecycle_harnesses(self):
        """Declared harnesses outside the matrix (planned / installed-unverified /
        unsupported). Report-only states: never auto-wired, never an error."""
        return [h for h in self.harnesses.values()
                if h.get("status", "active") not in ("active", "verified")]

    def harness_present(self, h):
        return os.path.isdir(expand(h.get("config_root") or ""))

    def strategy(self, cap, h, kind):
        ov = (cap.get("harnesses") or {}).get(h["id"]) or {}
        if kind == "skill":
            return ov.get("skill_strategy") or h.get("skill_strategy")
        return ov.get("mcp_strategy") or h.get("mcp_strategy")

    def definition_file(self, cap):
        """Repo-side file that declares this capability's canonical MCP server."""
        definition = (cap.get("mcp") or {}).get("definition", "shared")
        if definition == "shared":
            return os.path.join(self.root, "profiles", "shared", "mcp.json")
        return os.path.join(self.root, "profiles", "global", "mcp.json")

    def mcp_target(self, cap, h, strategy):
        if strategy == "shared":
            return self.shared_mcp
        if strategy == "profile":
            return os.path.join(expand(h.get("config_root") or ""), "mcp.json")
        if strategy == "native":
            return expand(h.get("mcp_file") or "")
        return None

    def skill_lock_sources(self):
        """{skill-name: normalized-source} from the official installer lock.

        The lock is machine-local evidence of what an official installer
        placed; a missing/unreadable lock simply proves nothing.
        """
        if self._skill_lock is None:
            data = {}
            if os.path.exists(self.skill_lock_path):
                try:
                    with open(self.skill_lock_path) as fh:
                        raw = json.load(fh)
                    for name, entry in (raw.get("skills") or {}).items():
                        src = norm_source(entry.get("source")
                                          or entry.get("sourceUrl") or "")
                        if src:
                            data[name] = src
                except Exception:
                    data = {}
            self._skill_lock = data
        return self._skill_lock

    def skill_declared_source(self, resource_id):
        res = self.resources.get(resource_id) or {}
        src = res.get("source") or {}
        return norm_source(src.get("url") or src.get("package") or "")


# ---------------------------------------------------------------------------
# probes (read-only)
# ---------------------------------------------------------------------------
def probe_cli(command):
    """Return {'path':..., 'version':...} for a CLI on PATH. Never installs."""
    info = {"command": command, "path": None, "version": None, "raw": None, "error": None}
    if not command:
        info["error"] = "no command declared"
        return info
    path = shutil.which(command)
    if not path:
        info["error"] = "not on PATH"
        return info
    info["path"] = path
    try:
        proc = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=20)
    except Exception as exc:  # pragma: no cover
        info["error"] = "version probe failed: %s" % exc
        return info
    out = (proc.stdout or "") + (proc.stderr or "")
    first = out.splitlines()[0].strip() if out.strip() else ""
    info["raw"] = first
    m = re.search(r"(\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.\-]+)?)", first)
    if m:
        info["version"] = m.group(1)
    elif first:
        info["version"] = first
    else:
        info["error"] = "no version output (exit %s)" % proc.returncode
    return info


def skill_state(reg, skill_id, shared_path, harness, declared_source):
    """(state, detail) for this skill adapter in this harness. Read-only.

    A real-directory copy counts as managed-copy only on provable evidence:
      1. the official installer lock (~/.agents/.skill-lock.json) records this
         skill from the same source the registry declares, or
      2. the copy is byte-identical to the shared source it derives from.
    Anything else is foreign-copy -- we never hand out managed-copy status
    just because a name matches.
    """
    shared = expand(shared_path)
    shared_ok = os.path.isdir(shared)
    shared_real = os.path.realpath(shared) if shared_ok else None
    scan_dirs = [expand(d) for d in (harness.get("skill_scan_dirs") or [])]
    if shared_ok and any(os.path.realpath(d) == os.path.dirname(shared_real)
                         for d in scan_dirs if d):
        return S_SHARED, ""
    skill_dir = expand(harness.get("skill_dir") or "")
    link = os.path.join(skill_dir, skill_id) if skill_dir else None
    if not (link and os.path.lexists(link)):
        return S_ABSENT, ""
    if os.path.islink(link):
        if not os.path.exists(link):
            return S_BROKEN, "broken: dangling symlink: %s" % link
        if shared_ok and os.path.realpath(link) == shared_real:
            return S_LINK, ""
        return S_FOREIGN, "foreign-copy: symlink points somewhere else: %s" % os.path.realpath(link)
    # real directory copy
    if not os.path.isfile(os.path.join(link, "SKILL.md")):
        return S_BROKEN, "broken: incomplete skill copy (no SKILL.md): %s" % link
    lock_src = reg.skill_lock_sources().get(skill_id)
    if lock_src and declared_source and lock_src == declared_source:
        return S_MANAGED_COPY, ("installer-managed copy (lock source '%s' matches "
                                "the declared upstream)" % lock_src)
    if shared_ok:
        copy_fp, shared_fp = dir_fingerprint(link), dir_fingerprint(shared)
        if copy_fp is not None and copy_fp == shared_fp:
            return S_MANAGED_COPY, "copy identical to the shared source"
    return S_FOREIGN, ("foreign-copy: provenance not established (not in the "
                       "installer lock and differs from the shared source)")


def skill_status(state):
    if state in (S_SHARED, S_LINK, S_MANAGED_COPY):
        return OK
    if state == S_ABSENT:
        return MISSING
    return WARN


def mcp_launch_equal(expected, actual, fmt):
    """Are two MCP entries functionally the same server?

    Extra optional keys (`type`, `lifecycle`, `enabled`) do not change which
    server gets launched, so they are ignored here. The add-only merge used at
    install time still compares exactly and therefore never overwrites.
    """
    if not isinstance(actual, dict):
        return False
    if fmt == "opencode-mcp" or expected.get("url") or actual.get("url"):
        return (list(expected.get("command") or []) == list(actual.get("command") or [])
                and actual.get("url") == expected.get("url"))
    return (actual.get("command") == expected.get("command")
            and list(actual.get("args") or []) == list(expected.get("args") or []))


def mcp_state(reg, cap, h, strategy):
    """Read-only MCP adapter state for (capability, harness)."""
    cap_mcp = cap.get("mcp") or {}
    server = cap_mcp.get("server_name")
    out = {"server_name": server, "strategy": strategy, "format": h.get("mcp_format"),
           "definition_file": reg.definition_file(cap), "target": None,
           "state": S_ABSENT, "status": MISSING, "detail": ""}
    if not server:
        return out
    try:
        profile = load_json(out["definition_file"])
    except Exception as exc:
        out.update(state="unparsable", status=ERROR,
                   detail="canonical definition unreadable: %s" % exc)
        return out
    canonical = (profile.get("mcpServers") or {}).get(server)
    if canonical is None:
        out.update(state="no-definition", status=ERROR,
                   detail="server '%s' missing from %s" % (server, out["definition_file"]))
        return out
    out["canonical"] = canonical
    target = reg.mcp_target(cap, h, strategy)
    out["target"] = target
    if not target:
        out.update(state="unsupported", status=WARN, detail="no target for strategy")
        return out
    if not os.path.exists(target):
        out.update(state="absent", status=MISSING, detail="target config not present")
        return out
    try:
        data = load_json(target)
    except Exception as exc:
        out.update(state="unparsable", status=ERROR,
                   detail="%s does not parse: %s" % (target, exc))
        return out
    fmt = h.get("mcp_format") or "mcpServers"
    actual = (data.get(MCP_KEY[fmt]) or {}).get(server)
    if actual is None:
        out.update(state="absent", status=MISSING, detail="server not in %s" % target)
        return out
    expected = to_format(canonical, fmt)
    if actual == expected:
        out.update(state="exact", status=OK, detail="matches shared definition")
    elif mcp_launch_equal(expected, actual, fmt):
        out.update(state="equivalent", status=OK,
                   detail="launch-identical to shared definition")
    else:
        out.update(state="drift", status=WARN,
                   detail="launches a different server than the shared definition")
    return out


# ---------------------------------------------------------------------------
# resolve: capability x harness -> live picture (read-only)
# ---------------------------------------------------------------------------
def resolve(reg, cap_id, harness_ids):
    cap = reg.cap(cap_id)
    cli = cap.get("cli") or {}
    cli_info = None
    if cli:
        live = probe_cli(cli.get("command"))
        res = reg.resources.get(cli.get("resource")) or {}
        declared = str(((res.get("resolution") or {}).get("version")) or "")
        status, detail = OK, ""
        if not live["path"]:
            status, detail = MISSING, (live.get("error") or "missing")
        elif declared and live.get("version") and live["version"] != declared:
            status = WARN
            detail = "installed %s != declared %s" % (live["version"], declared)
        cli_info = {
            "resource": cli.get("resource"), "command": cli.get("command"),
            "required": bool(cli.get("required")), "path": live.get("path"),
            "version": live.get("version"), "declared": declared,
            "status": status, "detail": detail, "updater": cli.get("updater"),
        }

    mcp_declared = cap.get("mcp") or None
    out = {
        "id": cap.get("id", cap_id), "name": cap.get("name", cap_id),
        "provider": cap.get("provider", ""), "description": cap.get("description", ""),
        "cli": cli_info,
        "skills_declared": [s.get("resource") for s in (cap.get("skills") or [])],
        "installer": cap.get("installer"),
        "mcp_declared": mcp_declared,
        "harnesses": [], "warnings": [],
    }

    for hid in harness_ids:
        h = reg.harness(hid)
        present = reg.harness_present(h)
        entry = {
            "id": hid, "name": h.get("name", hid), "status": h.get("status", "active"),
            "present": present, "config_root": expand(h.get("config_root") or ""),
            "skill_strategy": reg.strategy(cap, h, "skill"),
            "mcp_strategy": reg.strategy(cap, h, "mcp"),
            "skills": [], "mcp": None, "warnings": [],
        }
        if not present:
            entry["warnings"].append("harness config root not present: %s"
                                     % h.get("config_root"))

        for s in cap.get("skills") or []:
            sid = s.get("resource")
            state, detail = skill_state(reg, sid, s.get("shared_path"), h,
                                        reg.skill_declared_source(sid))
            st = skill_status(state)
            link = os.path.join(expand(h.get("skill_dir") or ""), sid) \
                if h.get("skill_dir") else None
            if state == S_ABSENT:
                detail = "not attached to this harness (strategy: %s)" % entry["skill_strategy"]
            entry["skills"].append({
                "id": sid, "shared_path": expand(s.get("shared_path") or ""),
                "shared_present": os.path.isdir(expand(s.get("shared_path") or "")),
                "link": link, "state": state, "status": st,
                "strategy": entry["skill_strategy"], "detail": detail,
            })
            if st != OK:
                entry["warnings"].append("%s: %s" % (sid, detail or state))

        if mcp_declared and mcp_declared.get("enabled"):
            entry["mcp"] = mcp_state(reg, cap, h, entry["mcp_strategy"])
            if entry["mcp"]["status"] != OK:
                entry["warnings"].append("mcp %s: %s"
                                         % (entry["mcp"]["server_name"],
                                            entry["mcp"]["detail"]))

        out["harnesses"].append(entry)
        out["warnings"].extend(["%s: %s" % (hid, w) for w in entry["warnings"]])

    if cli_info and cli_info["status"] != OK:
        out["warnings"].append("cli: %s" % (cli_info["detail"] or cli_info["status"]))
    return out


# ---------------------------------------------------------------------------
# plan: turn a resolve() picture into concrete actions
# ---------------------------------------------------------------------------
def build_actions(reg, res, scope="shared", project=None, target=None):
    cap = reg.cap(res["id"])
    actions = []

    def act(**kw):
        base = {"capability": res["id"], "harness": kw.pop("harness", ""),
                "harness_name": kw.pop("harness_name", ""), "state": "pending",
                "target": "", "command": None, "detail": "", "hint": "",
                "rollback": None}
        base.update(kw)
        actions.append(base)
        return base

    for h in res["harnesses"]:
        hid = h["id"]
        # --- skills -------------------------------------------------------
        for sk in h["skills"]:
            if sk["status"] == OK:
                act(kind="skill-verify", harness=hid, harness_name=h["name"],
                    state="satisfied", id=sk["id"], target=sk["link"] or sk["shared_path"],
                    detail="%s (%s)" % (sk["state"], sk["strategy"]))
                continue
            if sk["state"] in (S_FOREIGN, S_BROKEN):
                act(kind="skill-conflict", harness=hid, harness_name=h["name"],
                    state="conflict", id=sk["id"], target=sk["link"] or "",
                    detail=sk["detail"],
                    hint=("remove the unmanaged adapter, then re-run: "
                          "agent-toolbox install %s --harness %s --apply" % (res["id"], hid)))
                continue
            strat = sk["strategy"]
            if strat == "installer" and cap.get("installer"):
                iid = (reg.harness(hid).get("installer_ids") or {}).get(
                    cap["installer"].get("id"))
                if iid is None:
                    act(kind="skill-installer", harness=hid, harness_name=h["name"],
                        state="error", id=sk["id"], target=sk["shared_path"] or "",
                        detail="harness has no installer id '%s'"
                               % cap["installer"].get("id"))
                    continue
                cmd = [cap["installer"]["command"]] + [
                    str(a).replace("{id}", iid) for a in cap["installer"]["args"]]
                act(kind="skill-installer", harness=hid, harness_name=h["name"],
                    id=sk["id"], target=sk["shared_path"] or "", command=cmd,
                    detail="official installer -> %s" % " ".join(cmd))
            elif strat == "symlink":
                if not sk["shared_present"]:
                    act(kind="skill-shared", harness=hid, harness_name=h["name"],
                        state="error", id=sk["id"], target=sk["shared_path"],
                        detail="shared source missing; run the official installer first",
                        hint="agent-toolbox install %s --harness %s --apply"
                             % (res["id"], hid))
                    continue
                act(kind="skill-link", harness=hid, harness_name=h["name"],
                    id=sk["id"], target=sk["link"],
                    detail="symlink %s -> %s" % (sk["link"], sk["shared_path"]),
                    rollback={"type": "unlink", "path": sk["link"]})
            else:  # shared strategy
                act(kind="skill-shared", harness=hid, harness_name=h["name"],
                    state="error", id=sk["id"], target=sk["shared_path"],
                    detail="harness is expected to scan the shared dir but it does not",
                    hint="verify skill_scan_dirs for harness '%s' in manifest.yaml" % hid)

        # --- mcp ----------------------------------------------------------
        mcp = h.get("mcp")
        if mcp and mcp.get("status") != OK:
            if mcp.get("status") == ERROR:
                act(kind="mcp", harness=hid, harness_name=h["name"], state="error",
                    id=mcp.get("server_name"), target=mcp.get("target") or "",
                    detail=mcp.get("detail"))
            else:
                strategy = mcp.get("strategy")
                kind = "mcp-shared" if strategy in ("shared", "profile") else "mcp-mirror"
                act(kind=kind, harness=hid, harness_name=h["name"],
                    id=mcp.get("server_name"), target=mcp.get("target") or "",
                    detail="merge shared definition into %s (%s)"
                           % (mcp.get("target"), strategy),
                    rollback={"type": "restore", "path": mcp.get("target")})
        elif mcp and mcp.get("status") == OK:
            act(kind="mcp-verify", harness=hid, harness_name=h["name"],
                state="satisfied", id=mcp.get("server_name"), target=mcp.get("target") or "",
                detail=mcp.get("state"))

    # --- project-local MCP (explicit opt-in only) -------------------------
    if scope == "project":
        if not (cap.get("mcp") or {}).get("enabled"):
            act(kind="project-mcp", state="error", id=(cap.get("mcp") or {}).get("server_name"),
                detail="capability has no MCP dimension; --scope project is meaningless")
        elif not (project and target):
            act(kind="project-mcp", state="error",
                id=(cap.get("mcp") or {}).get("server_name"),
                detail="--scope project requires --project <name> and a resolvable --target")
        else:
            pdir = os.path.join(expand(target), ".pi")
            act(kind="project-mcp", harness="project:%s" % project,
                harness_name=project, id=(cap.get("mcp") or {}).get("server_name"),
                target=os.path.join(pdir, "mcp.json"),
                detail="EXPLICIT project-local MCP isolation for '%s'" % project,
                rollback={"type": "restore", "path": os.path.join(pdir, "mcp.json")})
    return actions


# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------
def log_event(root, payload):
    """Append one machine-local, git-ignored record of a mutation."""
    state_dir = os.path.join(root, "state")
    os.makedirs(state_dir, exist_ok=True)
    path = os.path.join(state_dir, "install-log.jsonl")
    payload = dict(payload)
    payload.setdefault("at", time.strftime("%Y-%m-%dT%H:%M:%S"))
    with open(path, "a") as fh:
        fh.write(json.dumps(payload, ensure_ascii=False) + "\n")
    return path


def run_command(cmd, timeout=600):
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return 127, "", "command not found: %s" % cmd[0]
    except Exception as exc:  # pragma: no cover
        return 1, "", str(exc)
    return proc.returncode, (proc.stdout or ""), (proc.stderr or "")


def exec_action(reg, action, apply=False):
    """Execute one pending action. Returns (ok, message)."""
    kind = action["kind"]
    if not apply:
        return True, "planned: %s" % (action["command"] and " ".join(action["command"])
                                      or action["detail"])

    if kind == "skill-installer":
        rc, out, err = run_command(action["command"])
        if rc != 0:
            return False, "installer failed (exit %s): %s" % (rc, (err or out).strip()[:400])
        return True, "ran: %s" % " ".join(action["command"])

    if kind == "skill-link":
        link, shared = action["target"], None
        # shared source comes from the capability declaration
        cap = reg.cap(action["capability"])
        for s in cap.get("skills") or []:
            if s.get("resource") == action["id"]:
                shared = expand(s.get("shared_path"))
        if not shared or not os.path.isdir(shared):
            return False, "shared source missing: %s" % shared
        if os.path.lexists(link):
            return False, "refusing to clobber existing path: %s" % link
        os.makedirs(os.path.dirname(link) or ".", exist_ok=True)
        os.symlink(shared, link)
        return True, "linked %s -> %s" % (link, shared)

    if kind in ("mcp-shared", "mcp-mirror", "project-mcp"):
        return write_mcp(reg, action)

    return False, "unknown action kind: %s" % kind


def write_mcp(reg, action):
    """Merge one MCP server into a target config, add-only, with backup."""
    cap = reg.cap(action["capability"])
    cap_mcp = cap.get("mcp") or {}
    server = action["id"]
    fmt = "mcpServers"
    target = action["target"]

    if action["kind"] == "project-mcp":
        profile_path = reg.definition_file(cap)
    else:
        profile_path = reg.definition_file(cap)
        h = None
        for cand in reg.active_harnesses() + list(reg.harnesses.values()):
            if cand.get("id") == action.get("harness"):
                h = cand
                break
        if h is not None:
            fmt = h.get("mcp_format") or "mcpServers"
    try:
        profile = load_json(profile_path)
    except Exception as exc:
        return False, "canonical definition unreadable: %s" % exc
    if server not in (profile.get("mcpServers") or {}):
        return False, "server '%s' missing from %s" % (server, profile_path)

    target_data = {}
    if os.path.exists(target):
        try:
            target_data = load_json(target)
        except Exception as exc:
            return False, "target does not parse (refusing to write): %s" % exc

    single = {"mcpServers": {server: profile["mcpServers"][server]}}
    added, preserved = merge_mcp_servers(single, target_data, fmt)
    if not added:
        return True, "already present in %s" % target
    backup = backup_file(target)
    new_data = apply_mcp_servers(single, target_data, fmt, added)
    write_json(target, new_data)
    # verify
    try:
        load_json(target)
    except Exception as exc:
        if backup:
            shutil.copy2(backup, target)
        return False, "post-write verification failed, rolled back: %s" % exc
    return True, "merged %s into %s%s" % (server, target,
                                          " (backup %s)" % backup if backup else "")


def apply_actions(reg, actions, apply=False, root=None):
    results = []
    for i, action in enumerate(actions, 1):
        if action["state"] != "pending":
            results.append(dict(action, outcome=action["state"],
                                message=action.get("detail", "")))
            continue
        ok, msg = exec_action(reg, action, apply=apply)
        outcome = "applied" if ok else "failed"
        results.append(dict(action, outcome=outcome, message=msg))
        if apply and root:
            log_event(root, {"event": "install", "capability": action["capability"],
                             "harness": action.get("harness"), "kind": action["kind"],
                             "id": action.get("id"), "outcome": outcome, "message": msg})
    return results


# ---------------------------------------------------------------------------
# rendering
# ---------------------------------------------------------------------------
def worst(statuses):
    order = {OK: 0, WARN: 1, MISSING: 2, ERROR: 3}
    if not statuses:
        return "-"
    return max(statuses, key=lambda s: order.get(s, 0))


def cmd_matrix(reg, args):
    rows = []
    for cid, cap in sorted(reg.caps.items()):
        hids = sorted((cap.get("harnesses") or {}).keys())
        res = resolve(reg, cid, hids)
        rows.append(res)

    if args.json:
        print(json.dumps({"capabilities": rows,
                          "harnesses": [{"id": h["id"], "name": h.get("name"),
                                         "status": h.get("status", "active")}
                                        for h in reg.harnesses.values()]},
                         indent=2, ensure_ascii=False))
        return EXIT_OK

    if args.grid:
        active = reg.active_harnesses()
        width = max([len(c) for c in reg.caps] + [len("capability")]) + 2
        head = "capability".ljust(width) + "".join(
            (h.get("name") or h["id"])[:11].ljust(13) for h in active)
        print("CAPABILITY x HARNESS")
        print(head)
        print("-" * len(head))
        for res in rows:
            line = res["id"].ljust(width)
            for h in active:
                match = [e for e in res["harnesses"] if e["id"] == h["id"]]
                if not match:
                    line += "-".ljust(13)
                    continue
                e = match[0]
                statuses = [s["status"] for s in e["skills"]]
                if e.get("mcp"):
                    statuses.append(e["mcp"]["status"])
                if not statuses:
                    line += "-".ljust(13)
                    continue
                cell = worst(statuses)
                line += STATE_ICON[cell].ljust(13)
            print(line)
        print("")
        print("✓ healthy   ⚠ warning   ✗ missing/error   - not wired for this harness")
        off = reg.lifecycle_harnesses()
        if off:
            print("")
            print("HARNESS LIFECYCLE (declared, outside the matrix — never auto-wired, not an error)")
            for h in sorted(off, key=lambda x: x["id"]):
                here = "config dir present" if reg.harness_present(h) else "no config dir"
                print("  %-12s %-22s %s" % (h["id"], h.get("status", "active"), here))
            print("planned = official path exists, local install not required")
            print("installed-unverified = present, capability Level 1-4 not finished")
            print("a config dir alone never means installed, and never promotes status by itself")
            print("verified promotes into the matrix; a pass mark is only earned by a real smoke test")
        return EXIT_OK

    print("CAPABILITIES")
    for res in rows:
        print("")
        print("%s  [%s]%s" % (res["name"], res["id"],
                              ("  provider: %s" % res["provider"]) if res["provider"] else ""))
        if res.get("cli"):
            c = res["cli"]
            label = "%s %s" % (c["command"], c["version"] or "?")
            if c["declared"] and c["version"] and c["version"] != c["declared"]:
                label += " (declared %s)" % c["declared"]
            print("  %-10s %s %s%s" % ("CLI", STATE_ICON[c["status"]], label,
                                       (" — " + c["detail"]) if c["detail"] else ""))
        if res.get("skills_declared"):
            shared_ok = all(os.path.isdir(expand(s.get("shared_path") or ""))
                            for s in (reg.cap(res["id"]).get("skills") or []))
            print("  %-10s %s %d skill adapter(s), single shared source %s"
                  % ("Skills", STATE_ICON[OK if shared_ok else MISSING],
                     len(res["skills_declared"]),
                     "present" if shared_ok else "MISSING"))
        if res.get("mcp_declared"):
            m = res["mcp_declared"]
            print("  %-10s %s %s (definition: %s)"
                  % ("MCP", STATE_ICON[OK], m.get("server_name"), m.get("definition")))
        if res["harnesses"]:
            parts = []
            for e in res["harnesses"]:
                statuses = [s["status"] for s in e["skills"]]
                if e.get("mcp"):
                    statuses.append(e["mcp"]["status"])
                if not e["present"] and not statuses:
                    parts.append("%s (absent)" % e["name"])
                else:
                    parts.append("%s %s" % (e["name"], STATE_ICON[worst(statuses)]))
            print("  %-10s %s" % ("Harnesses", "  ".join(parts)))
        warns = res["warnings"]
        if warns:
            print("  %-10s" % "Warnings")
            for w in warns:
                print("             ⚠ %s" % w)
        elif not res["harnesses"]:
            print("  %-10s (no harness wired)" % "Harnesses")
    print("")
    print("Run './scripts/doctor.sh' for a full health check,")
    print("'./scripts/install.sh <capability> --harness <id>' to attach a harness.")
    return EXIT_OK


# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------
def resolve_harness_ids(reg, args):
    """Target harnesses for an install.

    Default and --all-harnesses both mean "every ACTIVE harness". A harness
    still marked `status: planned` is only ever touched by naming it explicitly
    with --harness <id> (declare it active in manifest.yaml first in practice).
    """
    if args.harness:
        for hid in args.harness:
            reg.harness(hid)  # raises on unknown id
        return args.harness
    return [h["id"] for h in reg.active_harnesses()]


def cmd_install(reg, args):
    cap = reg.cap(args.capability)
    hids = resolve_harness_ids(reg, args)
    if not hids:
        print("ERROR: no target harness (use --harness <id> or --all-harnesses)",
              file=sys.stderr)
        return EXIT_CONFIG
    target = args.target
    if args.scope == "project" and not target and args.project:
        p = (reg.profiles.get("projects") or {}).get(args.project) or {}
        target = p.get("path")
    res = resolve(reg, args.capability, hids)
    actions = build_actions(reg, res, scope=args.scope, project=args.project, target=target)

    pending = [a for a in actions if a["state"] == "pending"]
    conflicts = [a for a in actions if a["state"] == "conflict"]
    errors = [a for a in actions if a["state"] == "error"]

    if args.json:
        print(json.dumps({"capability": args.capability, "harnesses": hids,
                          "scope": args.scope, "apply": bool(args.apply),
                          "pending": len(pending), "conflicts": len(conflicts),
                          "errors": len(errors), "actions": actions},
                         indent=2, ensure_ascii=False))
    else:
        print("Capability: %s (%s)" % (cap.get("name"), args.capability))
        print("Harnesses:  %s" % ", ".join(hids))
        print("Scope:      %s%s" % (args.scope,
                                    ("  project=%s" % args.project) if args.project else ""))
        print("Mode:       %s" % ("APPLY" if args.apply else "dry-run (pass --apply)"))
        print("")
        if res.get("cli"):
            c = res["cli"]
            print("  %-10s %s %s %s" % ("CLI", STATE_ICON[c["status"]], c["command"],
                                        c["version"] or "MISSING"))
        for a in actions:
            mark = {"pending": "→", "satisfied": "✓", "conflict": "⚠", "error": "✗"}[a["state"]]
            cmd = ("  [%s]" % " ".join(a["command"])) if a.get("command") else ""
            print("  %s %-14s %-12s %s%s" % (mark, a["kind"],
                                             a["harness"] or "-", a["detail"], cmd))
            if a.get("hint"):
                print("      hint: %s" % a["hint"])
        print("")
        if not pending:
            print("Already in sync — nothing to do.")
        else:
            print("%d action(s) pending, %d conflict(s), %d error(s)."
                  % (len(pending), len(conflicts), len(errors)))

    if not args.apply:
        return EXIT_CONFIG if errors else EXIT_OK

    results = apply_actions(reg, actions, apply=True, root=reg.root)
    failed = [r for r in results if r.get("outcome") == "failed"]
    if not args.json:
        print("")
        for r in results:
            if r.get("outcome") in ("applied", "failed"):
                print("  %s %s %s: %s" % ("✓" if r["outcome"] == "applied" else "✗",
                                          r["kind"], r.get("harness") or "-", r["message"]))
        if failed:
            print("")
            print("%d action(s) failed." % len(failed))
        else:
            print("")
            print("Done. Verify with: ./scripts/doctor.sh")
    return EXIT_CONFIG if errors else (EXIT_ISSUES if failed else EXIT_OK)


# ---------------------------------------------------------------------------
# doctor — read-only health check (never modifies the environment)
# ---------------------------------------------------------------------------
def cmd_doctor(reg, args):
    checks = []

    def add(section, name, status, detail=""):
        checks.append({"section": section, "name": name, "status": status,
                       "detail": detail})

    scripts = os.path.join(reg.root, "scripts")
    rc, out, err = run_command(["bash", os.path.join(scripts, "validate.sh")], 120)
    add("registry", "manifest / lock / profiles", OK if rc == 0 else ERROR,
        "valid" if rc == 0 else (out + err).strip().splitlines()[-1] if (out + err).strip() else "invalid")
    rc, out, err = run_command(["bash", os.path.join(scripts, "sync.sh")], 120)
    if rc == 0:
        add("registry", "manifest <-> lock", OK, "in sync")
    elif rc == 1:
        add("registry", "manifest <-> lock", WARN, "drift — run scripts/sync.sh")
    else:
        add("registry", "manifest <-> lock", ERROR, (out + err).strip()[:200])

    for cid, cap in sorted(reg.caps.items()):
        section = "%s / %s" % (cid, cap.get("name"))
        hids = sorted((cap.get("harnesses") or {}).keys())
        try:
            res = resolve(reg, cid, hids)
        except Exception as exc:
            add(section, "resolve", ERROR, str(exc))
            continue
        if res.get("cli"):
            c = res["cli"]
            detail = c["detail"] or ("%s (%s)" % (c["version"] or "?", c["path"] or "no path"))
            add(section, "cli %s" % c["command"], c["status"], detail)
        for e in res["harnesses"]:
            if not e["present"]:
                add(section, "harness %s" % e["id"], WARN,
                    "config root not present: %s" % e["config_root"])
                continue
            for sk in e["skills"]:
                add(section, "skill %s @ %s" % (sk["id"], e["id"]), sk["status"],
                    sk["detail"] or sk["state"])
            if e.get("mcp"):
                m = e["mcp"]
                add(section, "mcp %s @ %s" % (m["server_name"], e["id"]), m["status"],
                    m["detail"] or m["state"])

    errors = [c for c in checks if c["status"] == ERROR]
    warns = [c for c in checks if c["status"] == WARN]

    if args.json:
        print(json.dumps({"checks": checks,
                          "summary": {"total": len(checks), "errors": len(errors),
                                      "warnings": len(warns)},
                          "healthy": not errors and (not args.strict or not warns)},
                         indent=2, ensure_ascii=False))
        return EXIT_CONFIG if not checks else (
            EXIT_ISSUES if (errors or (args.strict and warns)) else EXIT_OK)

    print("Agent Toolbox doctor — read-only, nothing is modified")
    print("")
    section = None
    for c in checks:
        if c["section"] != section:
            section = c["section"]
            print(section)
        print("  %s %-28s %s" % (STATE_ICON[c["status"]], c["name"],
                                 ("— " + c["detail"]) if c["detail"] else ""))
    print("")
    print("Summary: %d checks, %d error(s), %d warning(s)%s"
          % (len(checks), len(errors), len(warns),
             " [strict]" if args.strict else ""))
    if errors:
        print("Fix the errors above; doctor never changes anything by itself.")
    return EXIT_CONFIG if not checks else (
        EXIT_ISSUES if (errors or (args.strict and warns)) else EXIT_OK)


# ---------------------------------------------------------------------------
# update — tool update vs adapter update (see docs/lifecycle.md)
# ---------------------------------------------------------------------------
def load_npm_mock(root):
    path = os.path.join(root, "tests", "fixtures", "npm-versions.json")
    if os.path.exists(path):
        try:
            with open(path) as fh:
                return json.load(fh)
        except Exception:
            return {}
    return {}


def npm_latest(pkg, mock=False, cache=None):
    if not pkg:
        return None
    if mock:
        return load_npm_mock_cache(cache).get(pkg)
    try:
        proc = subprocess.run(["npm", "view", pkg, "version"], capture_output=True,
                              text=True, timeout=30)
        if proc.returncode == 0:
            return proc.stdout.strip() or None
    except Exception:
        pass
    return None


_MOCK_CACHE = {}


def load_npm_mock_cache(cache):
    if cache is not None:
        return cache
    return _MOCK_CACHE


def project_paths(reg):
    out = []
    for name, p in sorted((reg.profiles.get("projects") or {}).items()):
        path = expand(p.get("path") or "")
        if path and os.path.isdir(path):
            out.append((name, path))
    return out


def check_reindex(reg, only_projects=None):
    """Ask CodeGraph whether a full reindex is recommended. Read-only."""
    results = []
    if shutil.which("codegraph") is None:
        return results
    for name, path in project_paths(reg):
        if only_projects and name not in only_projects:
            continue
        if not os.path.isdir(os.path.join(path, ".codegraph")):
            continue
        try:
            proc = subprocess.run(["codegraph", "status", "-j"], capture_output=True,
                                  text=True, timeout=60, cwd=path)
            rc, out, err = proc.returncode, proc.stdout, proc.stderr
        except Exception as exc:
            results.append({"project": name, "path": path, "error": str(exc)})
            continue
        if rc != 0:
            results.append({"project": name, "path": path,
                            "error": (err or out).strip()[:200]})
            continue
        try:
            data = json.loads(out)
        except Exception:
            results.append({"project": name, "path": path, "error": "unparsable status -j"})
            continue
        recommended = False
        idx = data.get("index") if isinstance(data.get("index"), dict) else {}
        recommended = bool(idx.get("reindexRecommended")
                           or data.get("reindexRecommended"))
        results.append({"project": name, "path": path, "reindexRecommended": recommended,
                        "state": idx.get("state"), "pendingChanges": data.get("pendingChanges")})
    return results


def update_report(reg, mock=False):
    tool_updates = []
    adapters = []
    for cid, cap in sorted(reg.caps.items()):
        cli = cap.get("cli") or {}
        entry = {"capability": cid, "name": cap.get("name"), "command": cli.get("command"),
                 "resource": cli.get("resource"), "live": None, "declared": None,
                 "latest": None, "state": "no-cli", "updater": cli.get("updater")}
        if cli:
            live = probe_cli(cli.get("command"))
            res = reg.resources.get(cli.get("resource")) or {}
            entry["live"] = live.get("version")
            entry["declared"] = str(((res.get("resolution") or {}).get("version")) or "")
            src = res.get("source") or {}
            if src.get("type") == "npm":
                entry["latest"] = npm_latest(src.get("package"), mock=mock, cache=_MOCK_CACHE)
            if not live.get("path"):
                entry["state"] = "missing"
            elif entry["latest"] and entry["live"] != entry["latest"]:
                entry["state"] = "stale"
            elif entry["declared"] and entry["live"] != entry["declared"]:
                entry["state"] = "drift"
            else:
                entry["state"] = "current"
        tool_updates.append(entry)

        hids = sorted((cap.get("harnesses") or {}).keys())
        res = resolve(reg, cid, hids)
        bad = [w for w in res["warnings"]]
        adapters.append({"capability": cid, "name": cap.get("name"),
                         "healthy": not bad, "warnings": bad})
    return {"tools": tool_updates, "adapters": adapters}


def cmd_update(reg, args):
    _MOCK_CACHE.clear()
    _MOCK_CACHE.update(load_npm_mock(reg.root))
    rep = update_report(reg, mock=args.mock)
    tools = rep["tools"]
    pending_tools = [t for t in tools if t["state"] in ("stale", "drift")]
    missing_tools = [t for t in tools if t["state"] == "missing"]
    bad_adapters = [a for a in rep["adapters"] if not a["healthy"]]

    index = check_reindex(reg)
    need_reindex = [i for i in index if i.get("reindexRecommended")]

    if not args.json:
        print("Agent Toolbox update — %s" % ("APPLY" if args.apply else
                                             "dry-run (pass --apply)"))
        print("")
        print("Tool updates (the CLI binary itself)")
        if not tools:
            print("  (no capability CLIs declared)")
        for t in tools:
            if t["state"] == "current":
                print("  ✓ %-18s %s is current" % (t["command"] or t["capability"],
                                                   t["live"] or "?"))
            elif t["state"] == "missing":
                print("  ✗ %-18s missing on PATH — install it first" % (t["command"] or "?"))
            elif t["state"] == "stale":
                print("  ↑ %-18s %s -> %s  (%s)"
                      % (t["command"], t["live"], t["latest"], t["resource"]))
            elif t["state"] == "drift":
                print("  ~ %-18s installed %s != declared %s (registry will be reconciled)"
                      % (t["command"], t["live"], t["declared"]))
        print("")
        print("Adapter updates (skills / MCP wiring)")
        for a in rep["adapters"]:
            if a["healthy"]:
                print("  ✓ %-18s all wired adapters healthy" % a["capability"])
            else:
                print("  ⚠ %-18s %d issue(s)" % (a["capability"], len(a["warnings"])))
                for w in a["warnings"]:
                    print("      %s" % w)
        print("")
        print("CodeGraph index")
        if not index:
            print("  · no indexed project found (or codegraph CLI absent)")
        for i in index:
            if i.get("error"):
                print("  ? %s: %s" % (i["project"], i["error"]))
            elif i.get("reindexRecommended"):
                print("  ↑ %s: reindexRecommended=true" % i["project"])
            else:
                print("  ✓ %s: incremental sync is enough" % i["project"])
        if need_reindex and not args.apply:
            print("")
            print("  Full index runs ONLY when reindexRecommended=true:")
            print("    ./scripts/update.sh --apply --reindex")

    if not args.apply:
        return EXIT_OK if not (pending_tools or missing_tools or bad_adapters
                               or need_reindex) else EXIT_ISSUES

    # ---- apply ----------------------------------------------------------
    changed_manifest = False
    applied, failed = [], []
    for t in pending_tools:
        if not t.get("updater"):
            failed.append("%s: stale but no cli.updater declared" % t["capability"])
            continue
        cmd = [t["updater"]["command"]] + [str(a) for a in t["updater"]["args"]]
        print("")
        print("→ updating %s: %s" % (t["capability"], " ".join(cmd)))
        rc, out, err = run_command(cmd, 900)
        if rc != 0:
            failed.append("%s: updater failed (exit %s): %s"
                          % (t["capability"], rc, (err or out).strip()[:300]))
            continue
        new_live = probe_cli(t["command"]).get("version")
        expected = t["latest"] or t["live"]
        if new_live and new_live != expected:
            failed.append("%s: expected %s after update, got %s"
                          % (t["capability"], expected, new_live))
            continue
        applied.append("%s -> %s" % (t["capability"], new_live))
        t["live"] = new_live

    # reconcile the registry with what is actually installed now
    now = time.strftime("%Y-%m-%d")
    for t in tools:
        if not t.get("resource") or not t["live"]:
            continue
        if str(t["declared"]) == str(t["live"]):
            continue
        res = reg.resources.get(t["resource"])
        if res is None:
            continue
        res.setdefault("resolution", {})["version"] = t["live"]
        res["resolution"]["checked_at"] = now
        if (res.get("source") or {}).get("type") in ("npm", "github", "git"):
            res["source"]["ref"] = t["live"]
        changed_manifest = True
        applied.append("%s registry -> %s" % (t["resource"], t["live"]))

    # refresh adapters (idempotent: only pending actions execute)
    adapter_failures = []
    for cid in sorted(reg.caps):
        cap = reg.cap(cid)
        hids = sorted((cap.get("harnesses") or {}).keys())
        res = resolve(reg, cid, hids)
        actions = build_actions(reg, res, scope="shared")
        pend = [a for a in actions if a["state"] == "pending"]
        errs = [a for a in actions if a["state"] == "error"]
        for a in errs:
            adapter_failures.append("%s@%s: %s" % (cid, a["harness"], a["detail"]))
        if pend:
            results = apply_actions(reg, pend, apply=True, root=reg.root)
            for r in results:
                if r.get("outcome") == "failed":
                    adapter_failures.append("%s@%s: %s" % (cid, r["harness"], r["message"]))
                elif r.get("outcome") == "applied":
                    applied.append("adapter %s@%s %s" % (cid, r["harness"], r["kind"]))

    # index lifecycle: never auto-run a full reindex unless asked AND recommended
    reindexed = []
    if args.reindex:
        for i in need_reindex:
            print("")
            print("→ full reindex %s (%s)" % (i["project"], i["path"]))
            rc, out, err = run_command(["codegraph", "index", i["path"]], 1800)
            if rc != 0:
                failed.append("reindex %s failed: %s" % (i["project"], (err or out).strip()[:200]))
            else:
                reindexed.append(i["project"])

    if changed_manifest:
        with open(reg.manifest_path, "w") as fh:
            yaml.safe_dump(reg.m, fh, sort_keys=False, allow_unicode=True,
                           default_flow_style=False)
        run_command(["bash", os.path.join(reg.root, "scripts", "sync.sh"), "--write-lock"], 120)

    if applied or changed_manifest:
        log_event(reg.root, {"event": "update", "applied": applied,
                             "failed": failed, "reindexed": reindexed})

    if not args.json:
        print("")
        if applied:
            print("Applied:")
            for a in applied:
                print("  ✓ %s" % a)
        if failed:
            print("Failed:")
            for f in failed:
                print("  ✗ %s" % f)
        if applied or failed:
            print("")
            print("Next: restart the affected harness / MCP client so it loads the new")
            print("binary. Then re-run ./scripts/update.sh to confirm reindex state —")
            print("a full `codegraph index` is only needed when reindexRecommended=true.")
    else:
        print(json.dumps({"report": rep, "applied": applied, "failed": failed,
                          "index": index, "reindexed": reindexed}, indent=2,
                         ensure_ascii=False))

    if failed:
        return EXIT_ISSUES
    return EXIT_OK if not (applied or pending_tools or bad_adapters or need_reindex) \
        else EXIT_ISSUES


# ---------------------------------------------------------------------------
def main(argv=None):
    p = argparse.ArgumentParser(prog="capability.py",
                                description="capability / harness-adapter engine")
    sub = p.add_subparsers(dest="cmd")
    sub.required = True

    m = sub.add_parser("matrix", help="capability overview")
    m.add_argument("--json", action="store_true")
    m.add_argument("--grid", action="store_true")

    i = sub.add_parser("install", help="attach one capability to harnesses")
    i.add_argument("capability")
    i.add_argument("--harness", action="append", default=[], metavar="ID")
    i.add_argument("--all-harnesses", action="store_true")
    i.add_argument("--scope", choices=["shared", "project"], default="shared")
    i.add_argument("--project", default=None)
    i.add_argument("--target", default=None)
    i.add_argument("--apply", action="store_true")
    i.add_argument("--json", action="store_true")

    d = sub.add_parser("doctor", help="read-only health check")
    d.add_argument("--json", action="store_true")
    d.add_argument("--strict", action="store_true")

    u = sub.add_parser("update", help="tool + adapter update lifecycle")
    u.add_argument("--apply", action="store_true")
    u.add_argument("--json", action="store_true")
    u.add_argument("--mock", action="store_true")
    u.add_argument("--reindex", action="store_true")

    args = p.parse_args(argv)
    try:
        reg = Registry()
    except Exception as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return EXIT_CONFIG

    try:
        if args.cmd == "matrix":
            return cmd_matrix(reg, args)
        if args.cmd == "install":
            return cmd_install(reg, args)
        if args.cmd == "doctor":
            return cmd_doctor(reg, args)
        if args.cmd == "update":
            return cmd_update(reg, args)
    except KeyError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return EXIT_CONFIG
    except FileNotFoundError as exc:
        print("ERROR: %s" % exc, file=sys.stderr)
        return EXIT_CONFIG
    return EXIT_CONFIG


if __name__ == "__main__":
    sys.exit(main())



