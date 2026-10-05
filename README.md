# agent-toolbox

> **Capability & Harness-Adapter registry** for a multi-agent environment.
> It manages *capabilities and their adapter relationships* — not a Pi skill set.

`agent-toolbox` records the **capabilities** you own (`BrowserSkill`,
`OpenCodeReview`, `CodeGraph`, …), the **agent harnesses** you run (`Pi`,
`CodeBuddy`, `Qoder CN`, `OpenCode`, …), and the **adapters** that wire one to
the other — as declarative YAML, with dry-run-by-default tooling that never
copies a tool twice and never clobbers your config.

```
             Agent Harnesses
      ┌──────┬──────────┬───────┬──────────┐
      │  Pi  │ CodeBuddy│ Qoder │ OpenCode │
      └──┬───┴────┬─────┴───┬───┴────┬─────┘
         └────────┴─────────┴────────┘
                     │
                Adapters           skill link / official installer
                     │             mcp mirror / shared definition
          Capability Registry      CLI probe / version + lock
      ┌──────────────┼──────────────────┐
      │              │                  │
  Browser        CodeReview         CodeGraph
    │              │                  │
   bsk            ocr           codegraph CLI + MCP
    │              │                  │
 ~/.agents/skills (single shared source)   ~/.agents/mcp.json
```

## Core concepts

| Term | Meaning | Where it lives |
| --- | --- | --- |
| **Capability** | An independent ability owned by a tool: a CLI and/or an MCP server. Not owned by any agent. | `manifest.yaml` → `capabilities:` |
| **CLI / MCP** | The capability *body*. `bsk`, `ocr`, `codegraph … serve --mcp`. | `manifest.yaml` → `resources.clis`, `resources.mcp` |
| **Skill** | Only an *adapter*: it teaches one harness how to discover and call the capability. Never the tool itself. | `manifest.yaml` → `resources.skills` |
| **Harness** | An agent runtime (Pi, CodeBuddy, Qoder CN, OpenCode, …). | `manifest.yaml` → `harnesses:` |
| **Adapter** | The per-harness wiring strategy: `shared` / `symlink` / `installer` for skills, `shared` / `native` / `profile` for MCP. | `capabilities.<cap>.harnesses` + `harnesses.<id>` |
| **Profile** | A concrete config snapshot: shared, global (Pi), per-project. | `profiles/**` |
| **Lock** | Resolved versions/commits — the *have* side of the registry. | `lock.yaml` |

Single source of truth: **one CLI, one capability definition, one shared skill
copy, one shared MCP definition — many harness adapters.**

```
~/.agents/skills/browser-skill   ← exactly one copy
        ├── Pi            (scans the shared dir)
        ├── CodeBuddy     symlink / official installer
        ├── Qoder CN      symlink
        └── OpenCode      symlink / scans the shared dir

~/.agents/mcp.json               ← shared MCP source of truth
        │   (codegraph · exa · context7 · searchcode)
        ├── Pi            reads it directly
        ├── CodeBuddy     mirrored into ~/.codebuddy/mcp.json
        ├── Qoder CN      mirrored into ~/.qoder-cn/settings.json
        └── OpenCode      mirrored into ~/.config/opencode/opencode.jsonc
```

A skill adapter in a harness directory is in exactly one of six states —
`shared` (the shared source itself), `symlink` (link into the shared source),
`managed-copy` (an official installer's copy, provenance verified via
`~/.agents/.skill-lock.json` or byte-equality), `foreign-copy` (provenance not
establishable), `broken`, `absent`. Only `foreign-copy`/`broken` warn; a copy
is never a duplicated capability — the CLI/MCP bodies (`bsk`, `ocr`,
`codegraph`) exist exactly once on PATH.

## Quickstart

```bash
# 0. single entrypoint (optional; every subcommand also works on its own)
./bin/agent-toolbox --help

# 1. environment readiness + validation + drift — all read-only
./scripts/bootstrap.sh
./scripts/validate.sh
./scripts/sync.sh

# 2. what can do what, where — read-only
./bin/agent-toolbox capabilities          # per-capability adapter status
./bin/agent-toolbox capabilities --grid   # capability x harness matrix
./bin/agent-toolbox status                # capability view + V1 counts + drift
./bin/agent-toolbox doctor                # CLI / skill / MCP / adapter health

# 3. attach a capability to a harness — dry-run by default
./bin/agent-toolbox install browser --harness codebuddy
./bin/agent-toolbox install code-review --harness pi
./bin/agent-toolbox install code-intelligence --all-harnesses
./bin/agent-toolbox install browser --harness codebuddy --apply   # actually do it

# 4. profiles (V1, unchanged) + shared layer
./scripts/install.sh global --apply      # Pi profile -> ~/.pi/agent
./scripts/install.sh shared --apply      # shared MCP -> ~/.agents/mcp.json

# 5. updates — read-only report, explicit apply
./bin/agent-toolbox update
./bin/agent-toolbox update --apply

# 6. tests (isolated copy + fake $HOME)
bash tests/run-tests.sh
```

## What install actually does

`install <capability> --harness <id>` **never downloads a tool**. It:

1. prints the plan (dry-run unless `--apply`);
2. checks the capability CLI exists (`bsk`, `ocr`, `codegraph`);
3. checks the target harness is present;
4. attaches the adapter — *official installer* (`bsk install-skill …`,
   `npx skills add …`) or a *symlink* into `~/.agents/skills`;
5. mirrors the shared MCP definition into the harness's native config,
   add-only, with a backup (`<file>.atb-backup.<ts>`);
6. verifies, then appends to `state/install-log.jsonl`;
7. rolls back the file it wrote if verification fails.

It is **idempotent**: a second run reports "already in sync" and touches nothing.
It **never creates a project-local `.pi/mcp.json`** unless you pass
`--scope project --project <name>` explicitly.

## Everyday loop

| I want to… | Command |
| --- | --- |
| Know the machine is ready | `./scripts/bootstrap.sh` |
| Make sure the registry is well-formed | `./scripts/validate.sh` |
| See want vs have drift | `./scripts/sync.sh` |
| See the capability/harness picture | `./bin/agent-toolbox capabilities` |
| Health-check CLIs, skills, MCP, adapters | `./bin/agent-toolbox doctor` |
| See live vs want drift (V1) | `./scripts/status.sh` |
| Attach a capability to a harness | `./bin/agent-toolbox install <cap> --harness <id> --apply` |
| Find newer versions | `./scripts/check-updates.sh` |
| Upgrade tools + refresh adapters | `./bin/agent-toolbox update --apply` |
| Add a resource / capability | `docs/adding-resources.md` |

## Repo layout

```
manifest.yaml            want — capabilities, harnesses, resources, profiles
lock.yaml                have — resolved versions (regenerated, never hand-edited)
profiles/shared/         tool-agnostic shared layer   -> ~/.agents/
profiles/global/         Pi harness profile           -> ~/.pi/agent/
profiles/projects/*/     per-project profile          -> <repo>/.pi/
catalog/                 human indexes by kind (skills, mcp, clis, ...)
scripts/
  capabilities.sh        capability overview (read-only)
  doctor.sh              health check (read-only)
  status.sh              capability view + V1 counts + drift (read-only)
  sync.sh                want vs have drift + --write-lock
  validate.sh            schema, cross-refs, secrets (read-only)
  check-updates.sh       upstream probe + --apply (writes the repo only)
  update.sh              tool + adapter update lifecycle (+ --reindex)
  install.sh             profiles AND capability adapters (dry-run default)
  bootstrap.sh           machine readiness (read-only)
  lib/common.sh          YAML engine, jq helpers, flags, exit codes
  lib/merge_config.py    the ONE add-only/backup-first JSON merge implementation
  lib/capability.py      capability/adapter engine (resolve, plan, apply, doctor)
bin/agent-toolbox        thin dispatcher -> scripts/*.sh
state/                   machine-local install/update log (git-ignored)
.github/workflows/       validate.yml (gate), check-updates.yml (weekly PR)
docs/                    architecture, capabilities, harnesses, adapters,
                         lifecycle, migration-pi-centric, manifest, scopes, ...
tests/                   unit + integration, always on an isolated copy
```

## Core principles

1. **Capability first.** Tools belong to the capability layer, never to an
   agent. Skills and configs are thin, disposable adapters.
2. **CLI / MCP is the body; Skill is the map.** The toolbox never becomes the
   distribution channel for a tool.
3. **Single source of truth.** One capability definition, one shared skill copy,
   one shared MCP definition — many adapters. No per-harness tool copies.
4. **Official installers win.** Where a capability ships its own installer, the
   toolbox delegates to it instead of re-implementing downloads.
5. **Safe by default.** Dry-run unless `--apply`; backup before every write;
   add-only merges that preserve anything you already configured; verify and
   roll back on failure; every mutation is logged.
6. **Never re-create project MCP.** Global shared MCP is the default;
   project-local isolation is an explicit `--scope project`.
7. **CI never touches your machine.** Workflows only read, and (in
   `check-updates.yml`) write this repo and open a PR.
8. **Lightweight on purpose.** Shell + YAML + JSON + one Python engine — no
   database, RPC, daemon, plugin host or UI.

See `docs/`:
[architecture](docs/architecture.md) ·
[capabilities](docs/capabilities.md) ·
[harnesses](docs/harnesses.md) ·
[adapters](docs/adapters.md) ·
[lifecycle](docs/lifecycle.md) ·
[migration-pi-centric](docs/migration-pi-centric.md) ·
[manifest](docs/manifest.md) ·
[scopes](docs/scopes.md) ·
[update-policy](docs/update-policy.md) ·
[security](docs/security.md) ·
[adding-resources](docs/adding-resources.md)

## Development

```bash
bash tests/run-tests.sh      # full suite on an isolated copy + fake HOME
bash scripts/validate.sh     # gate used by CI
bash scripts/sync.sh         # no drift
```

`AGENTS.md` documents the conventions for working on the toolbox itself.

## License

MIT — see [LICENSE](LICENSE).
