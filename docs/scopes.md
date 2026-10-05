# Scopes and how configuration is applied

A resource's `scope` says **where it lives**; a capability's adapter says **which
harness consumes it**. Those are different axes, so V2 has three layers instead
of V1's two.

## Three layers

| Layer | Lives in | Written by | Consumed by |
| --- | --- | --- | --- |
| **Shared** (default) | `~/.agents/` — `skills/`, `mcp.json` | official installers (skills), `install.sh shared` / capability adapter (MCP) | every harness, directly or via links |
| **Harness** | `~/.pi/agent/`, `~/.codebuddy/`, `~/.qoder-cn/`, `~/.config/opencode/` | `install.sh global` (Pi profile) or the MCP mirror | exactly one harness |
| **Project** (opt-in) | `<repo>/.pi/` | `install.sh project <name>` / `install … --scope project` | only that repo, after it is trusted |

The direction of truth:

```
profiles/shared/mcp.json   ->  ~/.agents/mcp.json        (shared MCP source of truth)
profiles/global/*          ->  ~/.pi/agent/*             (Pi harness profile; its mcp.json is
                                                          legacy-empty — servers live in shared)
profiles/projects/<n>/*    ->  <repo>/.pi/*              (explicit project opt-in)
```

## Global shared MCP is the default

Every MCP capability defaults to the shared layer, **not** to a project file:

```
~/.agents/mcp.json
   ├── Pi          reads it directly (pi-mcp-adapter auto-discovers it)
   ├── CodeBuddy   mirrored into ~/.codebuddy/mcp.json
   ├── Qoder CN    mirrored into ~/.qoder-cn/settings.json
   └── OpenCode    mirrored into ~/.config/opencode/opencode.jsonc
```

**Project-local MCP is never created by default.** The eight per-project
`.pi/mcp.json` files of the old layout were removed for exactly this reason: a
project-scoped server needs per-project trust, gets shadowed when a global
definition exists, and multiplies one server into N files.

It is available only as an explicit opt-in:

```bash
./bin/agent-toolbox install code-intelligence \
    --scope project --project <name> --apply
```

## Scopes in the profiles

```yaml
profiles:
  global:
    capabilities: [browser, code-review, code-intelligence, exa, context7, searchcode]
  projects:
    agent-engineering-lab:
      capabilities: [code-intelligence, code-review]   # Browser OFF here
```

- **Global profile capabilities** — what this machine offers through Pi's
  harness profile.
- **Project capabilities** — what *this repository* wants enabled. Another repo
  can turn Browser on and CodeReview off; the capability itself is unchanged,
  only its per-project declaration differs.

Project capability lists are declarative: they are validated and shown by
`status`, but they do not by themselves write anything into the repo.

## The golden rule: never clobber existing config

`install.sh` and the capability installer **add**; they never overwrite:

- `packages` merged by union — missing ones added, existing ones kept, none removed.
- `theme` set only if the target has none.
- MCP servers added only when absent; a server you configured differently is
  reported as `preserved`.
- Unknown keys you added are left untouched.
- An existing path (symlink/copy) is never clobbered — a conflict is reported
  with a hint instead.
- Every write is preceded by `<file>.atb-backup.<ts>`.

## Explicit, reversible, safe

```bash
./scripts/install.sh global --apply           # Pi harness profile
./scripts/install.sh shared --apply           # shared MCP layer
./scripts/install.sh project <name> --apply   # project profile
./bin/agent-toolbox install <cap> --harness <id> --apply   # one adapter
```

All default to **dry-run**. After a write the target is verified; if
verification fails the backup is restored. Every mutation is appended to
`state/install-log.jsonl` (machine-local, git-ignored).

## Trust boundary

Pi only loads project configuration for projects you **trust**. The toolbox
records the profile but cannot and must not bypass that dialog — same as V1.
