# agent-toolbox architecture

`agent-toolbox` is a **capability & harness-adapter registry**. It describes the
capabilities you own (BrowserSkill, OpenCodeReview, CodeGraph, …), the agent
harnesses you run (Pi, CodeBuddy, Qoder CN, OpenCode, …), and the thin adapters
that connect them — and it applies those adapters explicitly, reversibly and
idempotently.

It does **not** redistribute tools. A capability's CLI is installed by its own
upstream (`bsk update`, `npm install -g`, `codegraph upgrade`); a shared skill
is created by its official installer (`bsk install-skill`, `npx skills add`);
the toolbox only checks, links, mirrors, verifies and records.

## The model

```
Capability ──(CLI / MCP)──> Adapter ──> Harness
   what to attach           how to attach   where it is consumed
```

| Layer | Question it answers | Declared in |
| --- | --- | --- |
| **Capability** | *What* can my agents do? | `manifest.yaml` → `capabilities:` |
| **CLI / MCP** | *What body* implements it, which version? | `resources.clis`, `resources.mcp` + `lock.yaml` |
| **Skill** | *How does a harness discover it?* | `resources.skills` |
| **Harness** | *Where does it run, and what file layout does it use?* | `manifest.yaml` → `harnesses:` |
| **Adapter** | *Which strategy joins this capability to this harness?* | `capabilities.<cap>.harnesses.<hid>` |
| **Profile** | *Which config snapshot lands on disk?* | `profiles/**` |

A Skill is deliberately **not** the tool. `browser-skill` teaches a harness to
call `bsk`; delete every skill and the capability still works from a shell.
`bsk`, `ocr` and `codegraph` are the capability bodies.

## Want vs have vs live

| Concept | File / source | Meaning |
| --- | --- | --- |
| **Want** | `manifest.yaml` | Declared capabilities, harnesses, resources, profiles. |
| **Have** | `lock.yaml` | Resolved versions/commits the registry last recorded. |
| **Live** | `~/.agents/`, `~/.pi/agent/`, `~/.codebuddy/`, `~/.qoder-cn/`, `~/.config/opencode/` | What is actually wired on this machine. |

Distance between them is **drift**:

- `scripts/sync.sh` — want vs have (manifest ↔ lock)
- `scripts/doctor.sh` — want vs live (CLI / skills / MCP / adapters)
- `scripts/status.sh` — the combined view
- `scripts/check-updates.sh` — have vs upstream (npm / git)
- `scripts/update.sh` — live vs upstream + adapter refresh

## The shared layer is the pivot

```
                       ~/.agents/                     (tool-agnostic)
                 ┌──────────────────────┐
                 │  skills/             │  one copy of every shared skill
                 │   browser-skill      │
                 │   open-code-review   │
                 │   open-code-review-  │
                 │     delegate         │
                 │  mcp.json            │  shared MCP source of truth,
                 │                      │  one definition per server
                 └──────────────────────┘
                        ▲       │
        official        │       │  read / mirrored add-only
        installers      │       ▼
   bsk install-skill    │    harness native config
   npx skills add       │    ~/.pi/agent/mcp.json            (legacy V1, emptied — Pi reads shared directly)
                        │    ~/.codebuddy/mcp.json
                        │    ~/.qoder-cn/settings.json
                        │    ~/.config/opencode/opencode.jsonc
                        │
                 harness skill dirs hold only links
                 (~/.codebuddy/skills/x -> ~/.agents/skills/x)
```

Rule: **the harness never owns a second copy of a capability.** A skill
directory inside a harness may legally be a `symlink`, or a `managed-copy` the
official installer produced (provenance verified via `~/.agents/.skill-lock.json`
or byte-equality with the shared source — see
[adapters.md](adapters.md#the-six-adapter-states)). Anything else —
`foreign-copy` / `broken` — `doctor` reports as a warning and the fix is the
official installer; the toolbox does not silently delete your files.

## Layout of the registry

```yaml
toolbox:      # name, shared_root (~/.agents), model: capability
harnesses:    # adapter registry: paths + default strategies per harness
capabilities: # capability registry: cli / skills / mcp / installer / harness wiring
resources:    # single source of truth for sources + versions
  clis/ skills/ mcp/ extensions/ packages/ prompts/ themes
profiles:     # shared -> ~/.agents | global -> ~/.pi/agent | projects -> <repo>/.pi
```

`capabilities` and `harnesses` are **additive** sections: they reference
`resources` by id and never duplicate an upstream URL or version, so V1's
lock/sync/update machinery keeps working unchanged.

## Scripts contract

| Code | Meaning |
| --- | --- |
| `0` | OK / in sync / nothing to do / healthy |
| `1` | updates or issues found / drift / actions reported |
| `2` | configuration or validation failure |

| Script | Reads | Writes | Default mode |
| --- | --- | --- | --- |
| `bootstrap.sh` | machine | — | read-only |
| `validate.sh` | manifest, lock, profiles | — | read-only |
| `sync.sh` | manifest, lock | `lock.yaml` only with `--write-lock` | read-only |
| `capabilities.sh` | manifest + live probe | — | read-only |
| `doctor.sh` | everything | — | read-only, never fixes |
| `status.sh` | manifest, lock, live | — | read-only |
| `check-updates.sh` | upstream (npm/git) | `manifest.yaml`, `lock.yaml`, `CHANGELOG/update-report.json` with `--apply` | repo only |
| `update.sh` | upstream + live | machine **and** repo with `--apply` | dry-run |
| `install.sh` | manifest + profiles | machine with `--apply` | dry-run |

Implementation split:

- `scripts/lib/common.sh` — YAML engine, jq helpers, flag parsing, exit codes.
- `scripts/lib/merge_config.py` — **the one** add-only / backup-first JSON merge
  used by both profile installs and MCP adapter mirrors.
- `scripts/lib/capability.py` — resolve → plan → apply → verify for
  `matrix / install / doctor / update`.

## Safety invariants

1. Dry-run by default; `--apply` is the only thing that writes.
2. Back up before every write: `<file>.atb-backup.<ts>`.
3. Add-only merges: anything you configured that differs is preserved.
4. Verify after writing; restore the backup if verification fails.
5. Never clobber an existing path (symlinks, copies, configs).
6. Never create `project/.pi/mcp.json` without an explicit `--scope project`.
7. Every mutation is appended to `state/install-log.jsonl` (git-ignored).
8. CI only reads this repo (and opens a PR); it never runs `install.sh
   --apply` or `update.sh --apply` against a real machine.

## Isolation & reproducibility

- Tests copy the repo to a temp dir and use a fake `$HOME`, so `install.sh
  --apply` and `update.sh --apply` exercise throwaway data.
- `AGENTS.md` holds the conventions for working on the toolbox itself.
