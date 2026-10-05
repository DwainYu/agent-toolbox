# The manifest

`manifest.yaml` is the single source of truth: **everything you want**.

```yaml
schema_version: 1
toolbox:
  name: agent-toolbox
  model: capability          # capability-first (V2); primary_runtime is legacy
  shared_root: ~/.agents     # tool-agnostic shared layer
harnesses:                   # adapter registry: how a harness attaches things
  <harness-id>: { ... }
capabilities:                # capability registry: what an agent can do
  <capability-id>: { ... }
resources:                   # single source of truth for sources + versions
  clis: [ ... ]              # kind: cli   (capability bodies)
  skills: [ ... ]            # kind: skill (adapters)
  mcp: [ ... ]               # kind: mcp   (capability bodies / hosted servers)
  extensions: [ ... ]        # kind: extension
  packages: [ ... ]          # kind: package
  prompts: [ ... ]           # kind: prompt    (reserved)
  themes: [ ... ]            # kind: theme     (reserved)
profiles:
  shared:                    # -> ~/.agents        tool-agnostic layer
    path: ~/.agents
    config: {mcp: profiles/shared/mcp.json, skills: ~/.agents/skills}
  global:                    # -> ~/.pi/agent      Pi harness profile
    path: ~/.pi/agent
    capabilities: [browser, code-review, code-intelligence, ...]
    config: {settings: ..., mcp: ...}
  projects:
    <project-name>:
      path: ~/projects/<name>
      capabilities: [code-intelligence, code-review]
      config: {settings: ..., mcp: ...}
```

`capabilities` and `harnesses` are **additive**: they reference `resources` and
each other by id and never repeat an upstream URL or version, so the V1
lock/sync/update machinery keeps working as-is.

## Resource schema

Every resource shares this shape:

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | ✔ | Unique, lowercase, hyphenated. |
| `name` | string | ✔ | Skill/extension names must match `^[a-z0-9][a-z0-9-]*[a-z0-9]$` (≤ 64 chars). |
| `kind` | enum | ✔ | `cli\|skill\|mcp\|extension\|package\|prompt\|theme`; must equal its group. |
| `scope` | enum | ✔ | `global` or `project`. |
| `description` | string | | One-line purpose. |
| `source` | map | ✔ | `type`, `url`/`package`/`path`, `ref`. |
| `resolution` | map | | Resolved `version`/`commit`/`checked_at`. Written by check-updates. |
| `update` | map | | `policy` (`manual\|daily\|weekly\|monthly\|pin`), `channel`. |
| `security` | map | | `trust`, `executable`, `review_required`. |
| `install` | map | | `method`, `path`. How/where it lands. |
| `runtime` | map | | MCP only: `transport`, `url` or `command`+`args`. |
| `projects` | list | if project | Which projects this applies to. |
| `tags` / `notes` | | | Classification and operational notes. |

### Source types

| `source.type` | Required fields | Managed / updated by |
| --- | --- | --- |
| `manual` | — | Its own tooling (e.g. `bsk update`). Never probed. |
| `builtin` | — | Ships with the harness. |
| `pin`-policy | — | `check-updates` never proposes a change. |
| `local` | `path` | Local path that must exist (validated). |
| `git` / `github` | `url` (+ `ref`) | `check-updates` diffs tags when `ref` is set. |
| `npm` | `package` (+ `ref`) | `check-updates` probes `npm view`. |
| `url` | `url` | Hosted endpoint; no local version. |

## The `clis` group (`kind: cli`)

Capability bodies live here so they get full resource treatment:

```yaml
resources:
  clis:
    - id: codegraph-cli
      name: codegraph
      kind: cli
      scope: global
      source: {type: npm, package: '@colbymchenry/codegraph', ref: 1.6.0}
      resolution: {version: 1.6.0, commit: '', checked_at: '2026-10-04'}
      update: {policy: weekly, channel: stable}
      security: {trust: review, executable: true, review_required: true}
      install: {method: official-cli, path: ~/.hermes/node/bin/codegraph}
```

**One tool, one source record.** If a CLI and an MCP server are the same binary,
the MCP entry is `update.policy: pin` with a `manual` source and an empty
`resolution.version` — the CLI owns the version, so upstream is probed once.

## Harness schema (`harnesses:`)

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | string | ✔ | Must equal its key. |
| `name` | string | ✔ | Display name. |
| `status` | enum | ✔ | `active` (adopted) or `planned` (declared only). |
| `config_root` | path | ✔ | e.g. `~/.codebuddy`. |
| `skill_dir` | path | if link | Where this harness keeps its own skill entries. |
| `skill_scan_dirs` | list<path> | | Every dir the harness loads skills from. |
| `skill_strategy` | enum | ✔ | `shared \| symlink \| installer`. |
| `mcp_file` | path | if native | Target config file for MCP mirroring. |
| `mcp_format` | enum | ✔ | `mcpServers \| opencode-mcp`. |
| `mcp_strategy` | enum | ✔ | `shared \| native \| profile`. |
| `installer_ids` | map | | Installer key → this harness's id (`bsk: CodeBuddy`). |

See [harnesses.md](harnesses.md).

## Capability schema (`capabilities:`)

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` / `name` / `provider` / `description` | string | id, name, desc | Identity. |
| `cli` | map | | `resource` (→ `clis`), `command`, `required`, `updater{command,args}`. |
| `skills` | list | | `{resource, shared_path}` per skill adapter. |
| `mcp` | map | | `enabled`, `server_name`, `transport`, `definition` (`shared` — the shared source of truth; `profile-global` is V1 legacy and unused), `reindex_check`. |
| `installer` | map | | `id`, `command`, `args` — must contain the `{id}` placeholder. |
| `harnesses` | map | ✔ | `<harness-id>: {skill_strategy?, mcp_strategy?}` overrides. |

At least one of `cli` / `skills` / `mcp` must be present.
See [capabilities.md](capabilities.md) and [adapters.md](adapters.md).

## Resolution & lock

`resolution` is *derived*, not hand-edited — `check-updates.sh --apply` writes
`version`, `commit` and `checked_at`. `lock.yaml` is regenerated from the
manifest by `sync.sh --write-lock`, and the update workflow rewrites both
together so they never drift.

`lock.yaml` records **declared** state only. Facts that can be read live (the
installed CLI version, whether a skill is linked, whether an MCP entry is wired,
index freshness) are never duplicated there — see [lifecycle.md](lifecycle.md).

## Rules enforced by `scripts/validate.sh`

1. `schema_version` is `1`; manifest and lock parse as YAML.
2. Resource ids are unique across all groups (including `clis`).
3. `kind` matches its group; `scope` ∈ {global, project}; project-scoped
   resources list their `projects`.
4. Skill names are valid (lowercase + hyphens, ≤ 64, no edge/twin hyphens).
5. `source.type` is allowed; npm packages carry `package`, git/github carry `url`.
6. MCP entries have `runtime.url` or `runtime.command` + `transport: stdio`.
7. Local source paths exist.
8. **Harness registry**: ids match keys, `config_root` present, strategies and
   `mcp_format` are from the allowed set, `native` implies `mcp_file`, link
   strategies imply `skill_dir`, `installer_ids` is a mapping.
9. **Capability registry**: ids match keys, `name`/`description` present, at
   least one dimension, `cli.resource` ∈ `clis`, `skills[].resource` ∈ `skills`,
   every skill has a `shared_path`, `mcp.definition` ∈ {shared, profile-global},
   installer has `command` + `args` containing `{id}`, every `harnesses` key
   exists in `harnesses:` with a resolvable strategy.
10. **Profiles**: every `profiles.*.capabilities` id exists; every referenced
    profile config file exists.
11. No secret-looking strings anywhere in tracked YAML/JSON
    (see [security.md](security.md)).
