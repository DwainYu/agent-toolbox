# Lifecycle — four updates that are not the same thing

The most common source of confusion is treating "updating" as one action. It is
four, with four different triggers, four different tools and four different
rollback stories.

| # | Update | Trigger | Who does it | Command |
| --- | --- | --- | --- | --- |
| A | **Tool update** | upstream released a new CLI | the capability's own updater | `./bin/agent-toolbox update --apply` |
| B | **Adapter update** | skill content or wiring changed | official installers / link repair | `./bin/agent-toolbox update --apply` |
| C | **MCP update** | shared definition changed | add-only mirror | `./bin/agent-toolbox install <cap> --harness <id> --apply` |
| D | **Index update** | *code* changed / engine version changed | CodeGraph itself | watcher (auto) / `codegraph index` (only when recommended) |

## A. Tool update — the binary

```
bsk 0.3.0          -> bsk update
ocr 1.12.12        -> npm install -g @alibaba-group/open-code-review
codegraph 1.6.2    -> codegraph upgrade
```

`update.sh` probes upstream (`npm view`), compares with the **live**
`<command> --version`, runs the declared `cli.updater`, re-probes, then
reconciles `manifest.resolution.version` + `source.ref` + `lock.yaml`.

Report only (`./bin/agent-toolbox update`) — exit `1` when anything is pending.

```
Tool updates (the CLI binary itself)
  ✓ bsk                0.3.0 is current
  ↑ codegraph          1.6.2 -> 1.7.0  (codegraph-cli)
  ✓ ocr                1.12.12 is current
```

## B. Adapter update — the skills

Skill adapters are versioned by their *source*, not by the CLI:

```yaml
lock.yaml
  open-code-review:
    requested: {source: github, url: https://github.com/alibaba/open-code-review}
    resolved: {version: '', commit: ''}
```

Refresh = re-run the official installer (it is skipped when the adapter is
already healthy, so a no-op update costs nothing):

```bash
./bin/agent-toolbox update --apply     # refreshes every non-healthy adapter
```

Skill adapter health is what `doctor` reports — `shared` / `symlink` /
`managed-copy` (official installer artifact with verified provenance) are
healthy, `foreign-copy` / `broken` are warnings, `absent` is an action to take.

## C. MCP update — the wiring

The canonical definition lives in `profiles/shared/mcp.json` (repo) →
`~/.agents/mcp.json` (machine). Changing it and re-running the adapter install
mirrors it into each harness's native file, add-only, with a backup — including
the Hermes `mcp_servers:` YAML block (one-way; the adapter never writes back).

Changing *what the server serves* is a tool update (A), not this. The **harness
itself is never a managed tool**: `update` has no hermes entry and must not
upgrade, reinstall or reconfigure any harness as a side effect.

## D. CodeGraph index — deliberately separate

### D1. Your code changed → nothing to do

```
edit src/foo.ts
  -> codegraph watcher catches it
  -> debounce (default 2000ms)
  -> incremental sync (only changed files re-parsed)
  -> next query hits the fresh graph
```

**`agent-toolbox` never triggers this.** No cron, no hook, no `sync` after every
edit. Manual `codegraph sync` is only for sandboxes / `--no-watch` / scripted
pre-flight. Manual `codegraph index` is a **full rebuild** (slow) and is not part
of normal development.

### D2. The CLI was upgraded → restart, then ask

```
./bin/agent-toolbox update --apply     # upgrades the codegraph binary
  -> restart the harness / MCP client  # old process still runs old binary
  -> codegraph status -j               # index.reindexRecommended ?
       false -> nothing to do, incremental sync continues
       true  -> codegraph index <path> # full rebuild, only now
```

`update.sh` performs exactly these steps: it prints the restart reminder and
runs `codegraph status -j` in every indexed project. A full index runs **only**
with `--reindex` **and** `reindexRecommended == true`:

```bash
./bin/agent-toolbox update --apply --reindex
```

Unconditional `codegraph index --full` is never issued — that is the difference
between "the program changed" and "the graph is wrong".

## Tool vs adapter state in the registry

```yaml
# lock.yaml — what the registry resolved (regenerated, never hand-edited)
resources:
  codegraph-cli:   # the tool
    requested:  {source: npm, package: '@colbymchenry/codegraph', ref: 1.6.2}
    resolved:   {version: 1.6.2}
  codegraph:       # the MCP wiring — pinned; version is owned by the CLI
    requested:  {source: manual}
    resolved:   {version: ''}
```

What is *not* stored, because it can be read directly:

| Fact | Where it is read from |
| --- | --- |
| installed CLI version | live `--version` probe |
| skill attached / healthy | filesystem (link → shared source) |
| MCP wired | the harness config file |
| index freshness | `codegraph status -j` |
| install history | `state/install-log.jsonl` (append-only, git-ignored) |

`manifest.resolution.version` = *what the registry recorded*;
`doctor`/`update` compare it with *what is installed* and report the difference
as drift instead of trusting a file.

## Update policies

Unchanged from V1 — see [update-policy.md](update-policy.md): `manual | daily |
weekly | monthly | pin`, probed by `check-updates.sh` (repo-only, PR-gated) and
never applied to a machine by CI.
