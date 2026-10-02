# Scopes and how configuration is applied

A resource's `scope` says **where it lives**. Pi loads configuration from three
places; the toolbox mirrors them with a `global` scope and per-project scopes.

## Two scopes

| Scope     | Lives in                                   | Loaded by Pi         |
| --------- | ------------------------------------------ | -------------------- |
| `global`  | `profiles/global/` → `~/.pi/agent/`        | whenever Pi runs    |
| `project` | `profiles/projects/<name>/` → `<repo>/.pi/`| when the project is trusted |

A project-scoped MCP server (like the `codegraph` static-analysis server) is
installed into each project's `.pi/mcp.json`. A global skill (like
`browser-skill`) is installed into `~/.pi/agent/skills/`.

## The golden rule: never clobber existing config

The toolbox **adds** to the live environment; it does not overwrite. Concretely,
`scripts/install.sh --apply`:

- Merges `packages` by **union** — declares the missing ones, keeps existing
  ones, never removes.
- Sets `theme` only when the target has no theme. If you already chose a theme,
  the toolbox preserves yours.
- Adds missing MCP servers, and **preserves** any existing server whose config
  differs (it never silently replaces a server you configured).
- Leaves every unknown key you added untouched.

Before writing, `install.sh` backs up the target to `<file>.atb-backup.<ts>`.

## Explicit, reversible, safe

`install.sh` and `sync.sh` default to **dry-run**. To actually change a machine:

```bash
./scripts/install.sh global --apply
./scripts/install.sh project <name> --target /path --apply
```

`install.sh` is idempotent: running `--apply` twice is a no-op when already in
sync. Nothing is ever auto-applied by CI — see `docs/update-policy.md`.

## Trust boundary

Pi only loads project configuration for projects you **trust**. The toolbox
records the profile, but a project-scoped skill/extension loads only after you
accept it in Pi's project-trust dialog. This is intentional: the toolbox cannot
and must not bypass Pi's trust model.

## Live vs declared

`scripts/status.sh` computes `drift` by comparing the live environment
(`~/.pi/agent`, each project's `.pi/`) against the manifest. It tells you which
declared resources are missing/mismatched on **this** machine — useful when you
set up a new machine or clone the toolbox to a new host.
