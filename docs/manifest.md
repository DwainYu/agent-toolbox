# The manifest

`manifest.yaml` is the single source of truth: **everything you want**.

```yaml
schema_version: 1
toolbox:
  name: agent-toolbox
  owner: DwainYu
  primary_runtime: pi
resources:
  skills: [ ... ]        # kind: skill
  mcp: [ ... ]           # kind: mcp
  extensions: [ ... ]    # kind: extension
  packages: [ ... ]      # kind: package
  prompts: [ ... ]       # kind: prompt      (reserved)
  themes: [ ... ]        # kind: theme       (reserved)
profiles:
  global:
    path: ~/.pi/agent
  projects:
    <project-name>:
      path: ~/projects/<project-name>
      description: ...
```

## Resource schema

Every resource shares this shape:

| Field                | Type               | Required | Meaning                                                    |
| -------------------- | ------------------ | -------- | ---------------------------------------------------------- |
| `id`                 | string             | ✔        | Unique, lowercase, hyphenated.                              |
| `name`               | string             | ✔        | Skill/extension names must match `^[a-z0-9][a-z0-9-]*[a-z0-9]$` (≤ 64 chars). |
| `kind`               | enum               | ✔        | `skill\|mcp\|extension\|package\|prompt\|theme`; must equal the group you put it in. |
| `scope`              | enum               | ✔        | `global` or `project`.                                     |
| `description`        | string             |          | One-line purpose.                                          |
| `source`             | map                | ✔        | Where it comes from (`type`, `url`, `package`, `path`, `ref`). |
| `resolution`         | map                |          | Resolved version/commit, `checked_at`. Updated by check-updates. |
| `update`             | map                |          | `policy` (`manual\|daily\|weekly\|monthly\|pin`), `channel`. |
| `security`           | map                |          | `trust`, `executable` (bool), `review_required` (bool).    |
| `install`            | map                |          | `method`, `path`. How/where it lands.                      |
| `projects`           | list<string>       | if project | Which projects this applies to.                           |
| `tags`               | list<string>       |          | Classification tags.                                       |
| `notes`              | string             |          | Free-form operational notes.                               |

## Source types

| `source.type` | Required fields            | How it is managed / updated                            |
| ------------- | -------------------------- | ------------------------------------------------------ |
| `manual`      | —                          | Installed by its own tooling (e.g. `bsk`). Reference-only. |
| `builtin`     | `name`                     | Ships with Pi; never updated by the toolbox.           |
| `local`       | `path`                     | A local path that must exist (validated).              |
| `git` / `github` | `url` (+ `ref`)         | Git repo; `check-updates` diffs tags when `ref` is set. |
| `npm`         | `package` (+ `ref`)        | npm package; `check-updates` probes `npm view`.        |
| `url`         | `url`                      | Hosted endpoint (e.g. remote MCP); no local version checked. |

## Resolution

`resolution` is *derived*, not hand-edited — `scripts/check-updates.sh --apply`
writes `version`, `commit`, and `checked_at`. Hand-edit it only to correct a
mistaken probe. `lock.yaml` is regenerated from the manifest by
`scripts/sync.sh --write-lock`, and the update workflow always regenerates both
together so they never drift apart.

## Lock

`lock.yaml` is the *could-have* artifact CI consumes to detect drift. It is
committed, so anyone can diff "what was resolved last time" with "what the
manifest now wants" (`scripts/sync.sh`). It is deliberately **not** the source of
truth — the manifest is — but any update PR must update both.

## Rules enforced by `scripts/validate.sh`

1. `schema_version` is `1`.
2. manifest and lock parse as YAML.
3. Resource ids are unique.
4. `scope` ∈ {global, project}.
5. Project-scoped resources list their `projects`.
6. Skill/extension names are valid (lowercase a-z0-9 + hyphens, no edge/twin
   hyphens, ≤ 64 chars).
7. `source.type` is one of the allowed set.
8. No secret-looking strings anywhere in tracked YAML/JSON (see docs/security.md).
9. Local source paths exist.
10. npm packages carry `source.package`; git/github carry `source.url`.
11. MCP entries have a `runtime.url` or `runtime.command` + `transport: stdio`.