# agent-toolbox

> Personal **Agent resource registry + configuration + update manager**, with
> Pi coding agent as the core runtime.

`agent-toolbox` is a single, versioned home for everything your coding agent
uses: Skills, MCP servers, Pi Extensions, Pi Packages, prompt templates
(reserved), plus global and per-project configuration. It records **what you
want** (`manifest.yaml`), what was **resolved** (`lock.yaml`), what's **live**
on each machine (`~/.pi/agent/`, project `.pi/`), and how to get from any one to
the others — without ever silently modifying your environment.

## Why

Multiple installers (Pi, bsk, orca, npm, GitHub) scatter resources across
several files and locations. This toolbox gives you:

- **One manifest** declaring every skill / MCP server / extension / package.
- **Version & commit tracking** with `lock.yaml`.
- **Update checks** against upstream (`npm view`, `git ls-remote`) that open a
  reviewable **PR** — never an automatic install.
- **Drift detection** between manifest, lock, and the live environment.
- **Explicit, reversible, idempotent** installs (`--apply`, backups first,
  add-only merges that never clobber existing config).

## Quickstart

```bash
# 1. Environment readiness (read-only)
./scripts/bootstrap.sh

# 2. Validate the registry (schema, ids, scopes, secrets) — read-only
./scripts/validate.sh

# 3. Check manifest <-> lock (want vs have) — read-only
./scripts/sync.sh

# 4. See what's actually installed vs declared (read-only)
./scripts/status.sh

# 5. Preview what would change — dry-run by default
./scripts/install.sh global
./scripts/install.sh project agent-engineering-lab --target /path/to/repo

# 6. Apply a profile (backup first, add-only) — explicit
./scripts/install.sh global --apply

# 7. Check upstream for newer versions (network, read-only)
./scripts/check-updates.sh

# 8. Run the whole test suite (on an isolated copy)
bash tests/run-tests.sh
```

## Everyday loop

| I want to…                                  | Command / workflow                          |
| ------------------------------------------- | ------------------------------------------- |
| Know my environment is ready                 | `./scripts/bootstrap.sh`                    |
| Make sure the registry is well-formed        | `./scripts/validate.sh`                     |
| See drift between manifest vs lock           | `./scripts/sync.sh`                         |
| See drift between live machine vs manifest   | `./scripts/status.sh`                       |
| Install/add config on a machine              | `./scripts/install.sh global --apply`       |
| Find newer versions                          | `./scripts/check-updates.sh`                |
| Get a reviewable update PR                   | weekly `.github/workflows/check-updates.yml` |
| Add a resource                               | `docs/adding-resources.md`                  |

## Repo layout

```
manifest.yaml          want  — every declared resource + profiles
lock.yaml              have  — resolved versions/commits (regenerated)
catalog/               local resource catalogs by kind
profiles/global/       settings.json + mcp.json for ~/.pi/agent
profiles/projects/*/   per-project settings.json + mcp.json
scripts/               bootstrap/validate/status/sync/check-updates/install
.lib/common.sh          YAML engine, jq helpers, flag parsing, exit codes
resources/             local resource files (skills, extensions, ...) — optional
.github/workflows/     validate.yml (gate), check-updates.yml (weekly PR)
docs/                  architecture, manifest, scopes, update-policy, security, adding-resources
tests/                 unit + integration, always run on an isolated copy
```

## Core principles

1. **Not another installer.** Packages are installed with Pi's native
   `pi install` / `pi update -l`. The toolbox declares, checks, reports, and
   applies config explicitly.
2. **Safe by default.** `install.sh` and `sync.sh` are dry-run unless `--apply`;
   every write is backed up; merges are add-only and preserve your existing
   config.
3. **CI never touches your machine.** The update workflow only probes upstream
   and opens a PR. Merging updates the repo; installing is your explicit call.
4. **Trust is gated.** Project-scoped resources load only through Pi's project
   trust; executable resources are flagged for security review in PRs.
5. **Everything is diffable.** `lock.yaml`, `resolution`, and the update report
   make every bump auditable.

See `docs/`:
[architecture](docs/architecture.md) · [manifest](docs/manifest.md) ·
[scopes](docs/scopes.md) · [update-policy](docs/update-policy.md) ·
[security](docs/security.md) · [adding-resources](docs/adding-resources.md)

## Development

```bash
bash tests/run-tests.sh      # full suite on an isolated copy + fake HOME
bash scripts/validate.sh     # gate used by CI
```

`AGENTS.md` documents the conventions for working on the toolbox itself.

## License

MIT — see [LICENSE](LICENSE).