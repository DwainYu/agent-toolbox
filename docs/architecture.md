# agent-toolbox architecture

`agent-toolbox` is a **personal Agent resource registry + configuration + update
manager**. It treats the user's Pi coding-agent environment as a set of declared,
versioned resources: skills, MCP servers, Pi extensions, Pi packages, prompt
templates (reserved), plus global and per-project configuration. Everything the
user wants is recorded in one place (`manifest.yaml`); what is actually resolved
is recorded in `lock.yaml`; and the machine state is derived from both.

The toolbox does **not** reimplement Pi's installers. It declares, checks,
reports, and (only when asked) applies configuration — and it hands package
installation to Pi's own native `pi install` / `pi update`.

## Core idea: want vs have vs resolved

| Concept   | File / source              | Meaning                                             |
| --------- | -------------------------- | --------------------------------------------------- |
| **Want**  | `manifest.yaml`            | Declared resources + profiles the user wants.       |
| **Have**  | `lock.yaml`                | Resolved versions / commits actually available.     |
| **Live**  | `~/.pi/agent/`, project `.pi/` | What's installed on a given machine.            |

The distance between these three is **drift**. `scripts/sync.sh` compares
*want vs have* and reports drift; `scripts/status.sh` compares *live vs want* and
reports what is missing/mismatched; `scripts/check-updates.sh` compares *have vs
upstream* and proposes updates.

## Layers

```
manifest.yaml  (want)                      lock.yaml (have)
  resources:
    skills / mcp / extensions / packages / prompts / themes
  profiles:
    global / project:<name>
      profiles/global/settings.json, mcp.json
      profiles/projects/<name>/settings.json, mcp.json
        |
        v  (declare / resolve / check)
   scripts/
     bootstrap.sh   machine readiness check (read-only)
     validate.sh    schema + secret validation (read-only)
     status.sh      live vs want summary (read-only)
     sync.sh        want vs have drift + --write-lock (read-only / lock only)
     check-updates.sh  upstream probe + --apply (network; writes manifest+lock+report)
     install.sh     apply a profile to a machine (default dry-run; --apply writes)
   lib/common.sh    YAML->JSON engine, jq helpers, flag parser, exit codes
        |
        v
   .github/workflows/
     validate.yml        PR / push gate
     check-updates.yml   weekly upstream probe -> update PR
   docs/                architecture, manifest, scopes, update-policy, security, adding-resources
   tests/               unit + integration (always run on an isolated copy)
```

## Data model

- **resource** — one entry in `manifest.yaml` under a resource group. Has an
  `id`, `kind`, `scope`, `source`, `resolution`, `update`, `security`, `install`,
  `tags`, `notes`. See `docs/manifest.md`.
- **group** — `skills`, `mcp`, `extensions`, `packages`, `prompts` (reserved),
  `themes` (reserved). A group entry's `kind` must match the group.
- **manifest-feed** — optional remote URL that supplies declared resources; the
  toolbox can pull a catalog from a remote feed in addition to the local
  `catalog/`. (Reserved / optional in v1; see `docs/adding-resources.md`.)
- **profile** — a concrete config snapshot. `profiles/global/` and
  `profiles/projects/<name>/` contain the `settings.json` and `mcp.json` Pi
  loads.

## Scripts contract

Every script in `scripts/` uses a common exit-code convention:

| Code | Meaning                                          |
| ---- | ------------------------------------------------ |
| `0`  | OK / no updates / in sync                        |
| `1`  | Updates available (or applied) / drift found     |
| `2`  | Configuration / validation failure               |

Default mode is **safe**: `install.sh` and `check-updates.sh --apply` only change
the machine or write the repo when explicitly requested. The only script that
writes to this repo directly is `check-updates.sh --apply`; the only one that
writes to `~/.pi/agent` or a project dir is `install.sh --apply`.

## Isolation & reproducibility

- Tests never mutate the real checkout: `tests/run-tests.sh` copies the repo to a
  temp dir and uses a fake `$HOME`.
- GitHub Actions only ever reads the repo and (in the update workflow) commits the
  resolved `manifest.yaml` / `lock.yaml` / `update-report.json` into a PR. The
  actions never run `pi install` on any managed machine, so your live environment
  is never changed by CI.
- Driven by `AGENTS.md` conventions for how the toolbox itself should be worked on.
