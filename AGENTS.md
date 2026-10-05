# agent-toolbox conventions

This file is for coding agents working **on** the toolbox itself. It's in the
repo so a fresh clone session knows the rules.

## What this repo is

A declarative registry + config manager for the user's **cross-harness
capability environment**. It is *not* a package installer: it declares,
checks, reports, and applies config, and delegates the actual install to the
capability's official installer (`bsk`, `npx skills`, `npm i -g`, `codegraph`).

The model is **capability first**: a capability (browser, code-review,
code-intelligence) owns its CLI/MCP body; a Skill is only an adapter that
presents that capability to a specific harness. One capability, one CLI/one
MCP definition, one version record, many harness adapters — never a copy per
harness.

## Language & style

- Reply in Chinese when chatting; keep code comments in English for portability.
- Shell: `bash`, `set -euo pipefail`. Prefer helper functions over inline
  duplication. Every script sources `scripts/lib/common.sh` for the YAML engine,
  jq helpers, flag parsing (`parse_flags`), and the exit-code constants.
- Python lives only in `scripts/lib/` (`merge_config.py`, `capability.py`) and
  is invoked **as a subprocess** from shell with JSON on stdin/stdout. Shell
  owns flow control; Python owns JSON/merging/probing logic. No new runtime.
- Use the shared exit codes: `0` ok / no updates, `1` updates or drift found,
  `2` config/validation failure.

## Safety invariants (do not break)

1. `install.sh` and `sync.sh` are **dry-run by default**; only `--apply` writes.
2. `install.sh` must **never clobber existing config** — add-only merges, backup
   before write (`<file>.atb-backup.<ts>`), preserve user-owned keys/differing
   servers.
3. `install.sh` must **never re-create project MCP** (`project/.pi/mcp.json`).
   Default target is the shared `~/.agents/mcp.json`; project scope only via
   explicit `--scope project` (which requires a `profiles/<id>/mcp.json`).
4. `install.sh` must **never re-bind an unbound capability to Pi**. BrowserSkill /
   OpenCodeReview / CodeGraph were deliberately unbound from Pi; binding them
   back is a regression even if it "works".
5. `install.sh` must **never duplicate a capability**: shared skills live once in
   `~/.agents/skills/`; per-harness copies are link/adapter states only.
6. Installs **delegate to official installers** (`bsk install-skill`,
   `npx skills add`, `npm i -g`, `codegraph upgrade`). Never re-implement
   downloading/patching a third-party tool inside this repo.
7. `check-updates.sh --apply` writes only *inside this repo*
   (`manifest.yaml`, `lock.yaml`, `CHANGELOG/update-report.json`). It must
   **never** run `pi install` or modify `~/.pi/agent`.
8. `update.sh --apply` may touch shared skills/CLIs/`~/.agents/mcp.json` but
   **never** harness-local configs, project files, or `.codegraph` indexes.
   Index rebuild is opt-in (`--reindex`), never implicit.
9. CI must never modify the user's real machine. Workflows only read + (in
   `check-updates.yml`) write the repo and open a PR. `update.sh --apply` must
   never appear in CI.
10. `validate.sh` must fail (exit 2) on: invalid schema, duplicate ids, bad
    scopes, bad skill names, missing source fields, bad MCP runtime,
    unknown harness ids, capability references pointing at nothing, bad skill
    strategies / MCP strategies / formats, profile `capabilities:` entries that
    don't exist, missing `profiles/<id>/mcp.json|settings.json|opencode.jsonc`,
    and **secret-shaped strings** anywhere in tracked YAML/JSON.
11. `doctor` is **read-only** — it may read anything, write nothing (no
    backups, no logs, no state files). Fixes belong to `install --apply`.
12. YAML dates: `common.sh` converts PyYAML `datetime.date` to ISO strings before
    jq, so `checked_at: 2026-10-02` never breaks JSON consumers.

## Adding functionality

- Resource schema lives in `manifest.yaml`; document every field in
  `docs/manifest.md`. Keep the schema and the doc in sync.
- Capability model → `docs/capabilities.md`; harness registry →
  `docs/harnesses.md`; adapter strategies → `docs/adapters.md`; update kinds →
  `docs/lifecycle.md`. Update policies and the review gate are in
  `docs/update-policy.md`.
- Adding a resource usually means: entry under `resources.<kind>` (or a new
  group), a catalog file in `catalog/<kind>.yaml`, probes/filters in
  `check-updates.sh`, coverage in `sync.sh`/`validate.sh`, a doc section, and
  a test. Adding a *capability* additionally means a `capabilities:` entry
  (body + adapters) and, if it brings a new binary, a `resources.clis` record.
- Tests must run on an **isolated copy** with a **fake `$HOME`** so they never
  touch the real checkout or `~/.pi/agent`. `tests/run-tests.sh` enforces this.
- Tests that mutate the repo (checkpoint/rollback, check-updates apply) must
  make their **own** copy of `$WORK`; the harness `$WORK` stays pristine for
  every other test.

## Before you claim done

Run, and confirm **all** pass:

```bash
bash scripts/validate.sh
bash scripts/sync.sh            # no drift
bash tests/run-tests.sh         # ALL TESTS PASSED
```

Evidence over assertion: show the output, not just "should be fine".

## Secrets

Never commit real tokens. Profiles reference secrets via env vars or Pi's auth
store; `validate.sh` scans for secret-shaped strings and will fail the build.
See `docs/security.md`.
