# Migration: Pi-centric → Capability-centric

## Why the old model stopped working

V1 described the environment as **Pi's resource set**: a `skills` group whose
entries carried `install.path: ~/.pi/agent/skills/...`, profiles rooted at
`~/.pi/agent`, a `codegraph` MCP scoped `project` that got written into each
repo's `.pi/mcp.json`, and a `primary_runtime: pi` header.

That was accurate when Pi was the only harness. It stopped being accurate after
the machine grew **CodeBuddy, Qoder CN and OpenCode**, and it actively hurt once
the local architecture was cleaned up:

- BrowserSkill, OpenCodeReview and CodeGraph had been **unbound** from Pi: one
  shared skill store (`~/.agents/skills/`) and one shared MCP definition
  (`~/.agents/mcp.json`), with each harness attaching through its own loader.
- Eight per-project `.pi/mcp.json` files had been deleted so CodeGraph stopped
  being re-declared per repo.
- `bsk`, `ocr` and `codegraph` were still not in the registry at all — only
  their skill attachments were, which made the *tool* invisible to
  version/update tracking.

V1 could not express any of that, because it had no notion of "capability" and
no notion of "harness".

## Old model → new model

| Concern | Pi-centric (V1) | Capability-centric (V2) |
| --- | --- | --- |
| Unit of management | a Pi resource (`kind: skill\|mcp\|…`) | a **capability** with CLI/MCP body + adapters |
| Who owns a tool | implicitly Pi | **nobody** — capability layer |
| Skill meaning | a thing installed into `~/.pi/agent/skills` | a thin adapter teaching a harness to call a CLI |
| CLI (`bsk`, `ocr`) | not tracked | `resources.clis`, probed + version-locked |
| Harness | the single assumption | first-class `harnesses:` registry |
| Adapter | none (one target) | strategy per (capability, harness) |
| Shared store | none | `~/.agents/skills/`, `~/.agents/mcp.json` → `profiles/shared/` |
| MCP default | write into each project's `.pi/mcp.json` | global/shared; project-local is `--scope project` |
| `codegraph` scope | `project` × 4 repos | `global` + shared definition, mirrored per harness |
| Profiles | `global` = Pi, `projects` = Pi | `shared` + `global` (Pi) + `projects`, each with a `capabilities:` list |
| Update | one bucket | **tool / adapter / MCP / index** (see [lifecycle.md](lifecycle.md)) |

## What was deliberately *not* rewritten

The V1 safety core is untouched, because it was already right:

- want / have / live three-way model (`manifest` / `lock` / machine)
- dry-run by default, `--apply` to write
- `<file>.atb-backup.<ts>` before every write
- add-only merges that preserve user-owned keys and differing servers
- `check-updates.sh` writes only this repo and is PR-gated
- CI never mutates a real machine
- tests run on an isolated copy with a fake `$HOME`

`capabilities:` and `harnesses:` are **additive top-level sections** that
reference `resources` by id. No resource, lock entry or script contract was
broken: all 28 pre-existing tests still pass unchanged.

## Concrete changes in this migration

### Registry

| File | Change |
| --- | --- |
| `manifest.yaml` | `toolbox.model: capability`, `toolbox.shared_root: ~/.agents`; new `harnesses:` (9), new `capabilities:` (6); new `resources.clis` group (`bsk`, `ocr`, `codegraph-cli`); 3 shared skills moved from `~/.pi/agent/skills` to `~/.agents/skills` with `method: official-installer`; `codegraph` MCP `project` → `global`, `install.path` `.pi/mcp.json` → `~/.agents/mcp.json`, source pinned (version owned by `codegraph-cli`); profiles gained `shared:` and `capabilities:` lists |
| `lock.yaml` | regenerated — **additive only** (3 CLI entries) |
| `profiles/shared/mcp.json` | **new** — canonical shared MCP definition |
| `catalog/clis.yaml` | **new**; `catalog/skills.yaml`, `catalog/mcp.yaml` point at the shared layer |

### Tooling

| File | Change |
| --- | --- |
| `scripts/lib/capability.py` | **new** — resolve / plan / apply / doctor / update engine |
| `scripts/lib/merge_config.py` | **new** — the V1 merge logic extracted verbatim so profiles and MCP adapters share one implementation |
| `scripts/capabilities.sh`, `doctor.sh`, `update.sh` | **new** — read-only views + update lifecycle |
| `scripts/install.sh` | gains `shared` mode and capability dispatch; profile behaviour unchanged |
| `scripts/status.sh` | gains the capability view; V1 counts/drift/JSON keys kept |
| `scripts/validate.sh` | gains harness registry, capability cross-refs, strategy/format and profile-capability checks |
| `scripts/check-updates.sh` | knows `kind: cli` |
| `bin/agent-toolbox` | **new** — thin dispatcher |

## Rules that follow from the new model

1. **Never re-bind an unbound capability to Pi.** No new
   `~/.pi/agent/skills/<capability>` copies, no new per-project `.pi/mcp.json`.
2. **Never re-implement an official installer.** Delegate to `bsk install-skill`
   / `npx skills add` / `codegraph upgrade`.
3. **Never duplicate a version.** One tool → one `resources` entry → one lock
   entry; the MCP dimension inherits the CLI's version.
4. **Shared by default, harness-specific only when the harness cannot reach the
   shared store.**
5. **Project-local is always an explicit opt-in.**

## Deprecations

| V1 pattern | Status |
| --- | --- |
| `./scripts/install.sh global` | **kept** (Pi harness profile) |
| `./scripts/install.sh project <name>` | **kept** (Pi project profile) |
| `codegraph` written into `<repo>/.pi/mcp.json` | **retired** — use the shared layer; `--scope project` is the explicit escape hatch |
| `install.path: ~/.pi/agent/skills/<shared skill>` | **retired** → `~/.agents/skills/<skill>` |
| `primary_runtime: pi` | kept as a legacy field; the model is `capability` |
