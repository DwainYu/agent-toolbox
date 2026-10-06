# The Capability Registry

`manifest.yaml` → `capabilities:` declares **what an agent can do**, independent
of any agent. Each entry is a capability: a body (CLI and/or MCP), the optional
skill adapters that document it, and how it attaches to each harness.

```yaml
capabilities:
  code-intelligence:
    id: code-intelligence          # must equal its key
    name: CodeGraph
    provider: codegraph
    description: Code navigation as a CLI plus a stdio MCP server.
    cli:
      resource: codegraph-cli      # -> resources.clis  (single source of truth)
      command: codegraph
      required: true
      updater:                     # official updater, run ONLY by update --apply
        command: codegraph
        args: [upgrade]
    skills:                        # optional; adapters only
      - resource: open-code-review
        shared_path: ~/.agents/skills/open-code-review
    mcp:
      enabled: true
      server_name: codegraph
      transport: stdio
      definition: shared           # shared | profile-global
    installer:                     # optional; official installer template
      id: skills                   # key into harnesses.<id>.installer_ids
      command: npx
      args: [skills, add, alibaba/open-code-review, --skill, "*",
             --global, --agent, "{id}", --yes]
    harnesses:                     # per-harness strategy overrides
      pi:      {skill_strategy: shared}
      codebuddy: {skill_strategy: installer}
```

## Dimensions

| Dimension | Meaning | Required |
| --- | --- | --- |
| `cli` | The capability has a CLI body. Probed live with `<command> --version`; `resource` points at `resources.clis` for the declared version + updater. | no |
| `skills` | One or more skill adapters. Each `resource` points at `resources.skills`, each `shared_path` names the **single** shared copy. | no |
| `mcp` | The capability exposes an MCP server. `definition` says where the canonical config lives. | no |
| `installer` | The official installer template used when a harness resolves to `strategy: installer`. `{id}` expands to the harness's installer id. | no |
| `harnesses` | Strategy overrides per harness. Anything not overridden falls back to the harness default. | yes |

A capability must declare at least one of `cli` / `skills` / `mcp`.

## `mcp.definition`

| Value | Canonical file | Used by |
| --- | --- | --- |
| `shared` | `profiles/shared/mcp.json` → `~/.agents/mcp.json` | every MCP capability — the tool-agnostic shared MCP source of truth |
| `profile-global` | `profiles/global/mcp.json` → `~/.pi/agent/mcp.json` | nobody (V1 legacy placement, kept schema-compatible) |

`definition` is *where the truth lives*; `harnesses.<id>.mcp_strategy` is *how a
given harness consumes it*. See [adapters.md](adapters.md).

## Reference capabilities

| id | name | provider | body | adapters |
| --- | --- | --- | --- | --- |
| `browser` | BrowserSkill | tencent | `bsk` CLI | skill `browser-skill` |
| `code-review` | OpenCodeReview | alibaba | `ocr` CLI | skills `open-code-review`, `open-code-review-delegate` |
| `code-intelligence` | CodeGraph | codegraph | `codegraph` CLI **+** stdio MCP | MCP only |
| `exa` / `context7` / `searchcode` | hosted MCPs | — | MCP only (URL transport) | shared MCP, mirrored per harness |

Read as:

- **CodeBuddy + BrowserSkill** → CodeBuddy → `browser` adapter → shared
  `~/.agents/skills/browser-skill` → `bsk`
- **CodeBuddy + OpenCodeReview** → CodeBuddy → `code-review` adapter → official
  `npx skills add … --agent codebuddy` → shared skill → `ocr`
- **CodeBuddy + CodeGraph** → CodeBuddy → `code-intelligence` MCP adapter →
  shared `~/.agents/mcp.json` mirrored into `~/.codebuddy/mcp.json` →
  `codegraph serve --mcp`

## CLI: the capability body

CLIs live in `resources.clis` (`kind: cli`), so they get the same treatment as
every other resource: `source`, `resolution`, `update.policy`, `lock.yaml`,
upstream probing.

| id | command | source | declared version |
| --- | --- | --- | --- |
| `bsk` | `bsk` | manual (self-updating binary) | 0.3.0 |
| `ocr` | `ocr` | npm `@alibaba-group/open-code-review` | 1.12.12 |
| `codegraph-cli` | `codegraph` | npm `@colbymchenry/codegraph` | 1.6.2 |

Two rules keep this honest:

1. **One tool, one source record.** The `codegraph` MCP entry is `update.policy:
   pin` with a `manual` source — the binary's version is owned by
   `codegraph-cli`, never probed twice.
2. **Declared vs live.** `manifest.resolution.version` is what the registry
   recorded; `doctor`/`update` probe the real `--version` output and report
   `installed != declared` as drift instead of trusting the file.

## Adding a capability

1. Add the body to `resources.clis` and/or `resources.mcp`.
2. Add each skill adapter to `resources.skills` with `install.path` under
   `~/.agents/skills/`.
3. Add the `capabilities.<id>` entry referencing them.
4. Wire `harnesses` (override only where the harness default is wrong).
5. If the project should have it, add the id to `profiles.global.capabilities`
   and/or `profiles.projects.<name>.capabilities`.
6. `bash scripts/validate.sh` — cross-references, strategies, placeholder and
   profile ids are all enforced.
