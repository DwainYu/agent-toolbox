# agent-toolbox conventions

This file is for coding agents working **on** the toolbox itself. It's in the
repo so a fresh clone session knows the rules.

## What this repo is

A declarative registry + config manager for the user's Pi-based agent
environment. It is **not** a package installer: it declares, checks, reports,
and applies config, and delegates the actual install to Pi's native commands.

## Language & style

- Reply in Chinese when chatting; keep code comments in English for portability.
- Shell: `bash`, `set -euo pipefail`. Prefer helper functions over inline
  duplication. Every script sources `scripts/lib/common.sh` for the YAML engine,
  jq helpers, flag parsing (`parse_flags`), and the exit-code constants.
- Use the shared exit codes: `0` ok / no updates, `1` updates or drift found,
  `2` config/validation failure.

## Safety invariants (do not break)

1. `install.sh` and `sync.sh` are **dry-run by default**; only `--apply` writes.
2. `install.sh` must **never clobber existing config** — add-only merges, backup
   before write (`<file>.atb-backup.<ts>`), preserve user-owned keys/differing
   servers.
3. `check-updates.sh --apply` writes only *inside this repo*
   (`manifest.yaml`, `lock.yaml`, `CHANGELOG/update-report.json`). It must
   **never** run `pi install` or modify `~/.pi/agent`.
4. CI must never modify the user's real machine. Workflows only read + (in
   `check-updates.yml`) write the repo and open a PR.
5. `validate.sh` must fail (exit 2) on: invalid schema, duplicate ids, bad
   scopes, bad skill names, missing source fields, bad MCP runtime, and
   **secret-shaped strings** anywhere in tracked YAML/JSON.
6. YAML dates: `common.sh` converts PyYAML `datetime.date` to ISO strings before
   jq, so `checked_at: 2026-10-02` never breaks JSON consumers.

## Adding functionality

- Resource schema lives in `manifest.yaml`; document every field in
  `docs/manifest.md`. Keep the schema and the doc in sync.
- Update policies and the review gate are in `docs/update-policy.md`.
- Any new resource type must be covered by `validate.sh` (schema + security) and
  `check-updates.sh` (probe + apply), plus a unit/integration test.
- Tests must run on an **isolated copy** with a **fake `$HOME`** so they never
  touch the real checkout or `~/.pi/agent`. `tests/run-tests.sh` enforces this.

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
