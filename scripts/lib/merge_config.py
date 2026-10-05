#!/usr/bin/env python3
# =============================================================================
# merge_config.py — add-only, backup-first JSON config merge (V1 semantics)
#
# CLI (used by scripts/install.sh):
#   merge_config.py <plan|apply> <profile.json> <target.json> <ctype> <label>
#     ctype: settings | mcp | mcp-opencode
#
# Library (used by scripts/lib/capability.py):
#   merge_mcp_servers(profile_dict, target_dict, fmt, only=None)
#       -> (added, preserved)
#   apply_mcp_servers(profile_dict, target_dict, fmt, added) -> new target dict
#   backup_file(path) -> backup path or None
#
# Invariants (never break these):
#   * ADD-ONLY. Existing entries that differ are preserved, never overwritten.
#   * Unknown existing keys/servers are preserved.
#   * Backup before any write: <file>.atb-backup.<ts>
#   * Output wording is stable — tests and humans parse it.
# =============================================================================
import json
import os
import shutil
import sys
import time

MCP_KEY = {"mcpServers": "mcpServers", "opencode-mcp": "mcp"}


def strip_json_comments(text):
    """Remove // and /* */ comments outside of strings (JSONC support)."""
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def load_json(path):
    """Load JSON, tolerating JSONC comments (opencode.jsonc)."""
    with open(path) as fh:
        raw = fh.read()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return json.loads(strip_json_comments(raw))


def backup_file(path):
    """Copy <path> to <path>.atb-backup.<ts>. Returns the backup path or None."""
    if not os.path.exists(path):
        return None
    ts = time.strftime("%Y%m%d-%H%M%S")
    bak = f"{path}.atb-backup.{ts}"
    shutil.copy2(path, bak)
    return bak


def to_format(canonical, fmt):
    """Map a canonical mcpServers entry onto a harness-specific shape."""
    if fmt == "mcpServers":
        return canonical
    if fmt == "opencode-mcp":
        if canonical.get("url"):
            return {"type": "remote", "url": canonical["url"], "enabled": True}
        cmd = canonical.get("command", "")
        args = list(canonical.get("args") or [])
        return {"type": "local", "command": [cmd] + args, "enabled": True}
    raise ValueError(f"unknown mcp format: {fmt}")


def _profile_servers(profile, only):
    servers = profile.get("mcpServers", {}) or {}
    if only is not None:
        servers = {k: v for k, v in servers.items() if k == only}
    return servers


def merge_mcp_servers(profile, target, fmt, only=None):
    """Add-only merge plan for MCP servers. Returns (added, preserved)."""
    key = MCP_KEY[fmt]
    prof = _profile_servers(profile, only)
    tgt = target.get(key, {}) or {}
    added, preserved = [], []
    for sid in prof:
        if sid not in tgt:
            added.append(sid)
        elif tgt[sid] != to_format(prof[sid], fmt):
            preserved.append(f"{sid} (existing differs, preserved)")
        else:
            preserved.append(sid)
    for sid in tgt:
        if sid not in prof:
            preserved.append(f"{sid} (unknown existing server, preserved)")
    return added, preserved


def apply_mcp_servers(profile, target, fmt, added):
    """Return a new target dict with `added` servers merged in (add-only)."""
    key = MCP_KEY[fmt]
    new = dict(target)
    new.setdefault(key, {})
    for sid, cfg in _profile_servers(profile, None).items():
        if sid in added and sid not in new[key]:
            new[key][sid] = to_format(cfg, fmt)
    return new


def merge_settings(profile, target):
    """Add-only merge for a Pi settings.json. Returns (added, preserved)."""
    prof_pkgs = profile.get("packages", [])
    tgt_pkgs = target.get("packages", [])
    added, preserved = [], []
    for p in prof_pkgs:
        if p not in tgt_pkgs:
            added.append(p)
        else:
            preserved.append(p)
    if "theme" in profile and "theme" not in target:
        added.append(f"theme={profile['theme']}")
    elif "theme" in profile:
        preserved.append(f"theme={target.get('theme', '')}")
    for e in profile.get("extensions", []):
        if e not in target.get("extensions", []):
            added.append(f"extension:{e}")
        else:
            preserved.append(f"extension:{e}")
    for k in target:
        if k not in ("packages", "theme", "extensions"):
            preserved.append(f"key:{k} (user-owned, preserved)")
    return added, preserved


def apply_settings(profile, target, added):
    new = dict(target)
    new.setdefault("packages", [])
    for p in added:
        if p not in new["packages"] and not p.startswith("theme="):
            new["packages"].append(p)
    if "theme" in profile and "theme" not in new:
        new["theme"] = profile["theme"]
    if "extensions" in profile and "extensions" not in new:
        new["extensions"] = profile["extensions"]
    return new


def write_json(path, data):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as fh:
        fh.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def main(argv):
    if len(argv) != 5:
        print("usage: merge_config.py <plan|apply> <profile> <target> <ctype> <label>",
              file=sys.stderr)
        return 2
    mode, prof_path, target_path, ctype, label = argv
    if not os.path.exists(prof_path):
        print(f"ERROR: {label}: profile does not exist: {prof_path}", file=sys.stderr)
        return 2
    try:
        profile = load_json(prof_path)
    except Exception as e:
        print(f"ERROR: {label}: profile does not parse: {e}", file=sys.stderr)
        return 2

    target_data = {}
    if os.path.exists(target_path):
        try:
            target_data = load_json(target_path)
        except Exception as e:
            print(f"ERROR: {label}: target does not parse: {e}", file=sys.stderr)
            return 2

    modified = False
    if ctype == "settings":
        added, preserved = merge_settings(profile, target_data)
        modified = bool(added)
        new_data = apply_settings(profile, target_data, added) if mode == "apply" else None
    elif ctype in ("mcp", "mcp-opencode"):
        fmt = "mcpServers" if ctype == "mcp" else "opencode-mcp"
        added, preserved = merge_mcp_servers(profile, target_data, fmt)
        modified = bool(added)
        new_data = apply_mcp_servers(profile, target_data, fmt, added) if mode == "apply" else None
    else:
        print(f"ERROR: unknown ctype '{ctype}'", file=sys.stderr)
        return 2

    if mode == "apply":
        if modified:
            backup_file(target_path)
            write_json(target_path, new_data)
        for a in added:
            print(f"  + {a}")
        if modified:
            print(f"  wrote {target_path}")
    else:
        if added:
            print(f"Would modify: {target_path}")
            for a in added:
                print(f"  + {a}")
        else:
            print(f"Would leave unchanged: {target_path}")
        for p in preserved:
            print(f"  ~ preserve: {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
