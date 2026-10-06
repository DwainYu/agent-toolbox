# Harnesses

A **harness** is an agent runtime that consumes capabilities. The harness
registry (`manifest.yaml` → `harnesses:`) describes *where a harness keeps its
config* and *how it attaches things by default* — never what a capability is.

Pi is **not** the capability owner — it is one harness among the active ones
(`pi`, `codebuddy`, `qoder-cn`, `opencode`). Every body (CLI, MCP definition,
shared skill) lives in the tool-agnostic layer; Pi merely scans and reads it.

```yaml
harnesses:
  codebuddy:
    id: codebuddy                # must equal its key
    name: CodeBuddy
    status: active               # active | planned | installed-unverified | verified | unsupported
    config_root: ~/.codebuddy
    skill_dir: ~/.codebuddy/skills
    skill_scan_dirs: [~/.codebuddy/skills]
    skill_strategy: symlink      # default for skills
    mcp_file: ~/.codebuddy/mcp.json
    mcp_format: mcpServers       # mcpServers | opencode-mcp
    mcp_strategy: native         # default for MCP
    installer_ids:               # this harness's id for each official installer
      bsk: CodeBuddy
      skills: codebuddy
```

## Supported harnesses

| Harness | status | config root | skill dir | shared scan | MCP file | MCP format |
| --- | --- | --- | --- | --- | --- | --- |
| **Pi** | active | `~/.pi/agent` | `~/.pi/agent/skills` | ✔ `~/.agents/skills` | `~/.agents/mcp.json` | `mcpServers` |
| **CodeBuddy** | active | `~/.codebuddy` | `~/.codebuddy/skills` | — | `~/.codebuddy/mcp.json` | `mcpServers` |
| **Qoder CN** | active | `~/.qoder-cn` | `~/.qoder-cn/skills` | — | `~/.qoder-cn/settings.json` | `mcpServers` |
| **OpenCode** | active | `~/.config/opencode` | `~/.config/opencode/skills` | ✔ `~/.agents/skills` | `~/.config/opencode/opencode.jsonc` | `opencode-mcp` |
| Claude Code | planned | `~/.claude` | `~/.claude/skills` | — | `~/.claude.json` | `mcpServers` |
| Codex | planned | `~/.codex` | `~/.agents/skills` | ✔ `~/.agents/skills` | `~/.agents/mcp.json` | `mcpServers` |
| Gemini CLI | planned | `~/.gemini` | `~/.gemini/skills` | — | `~/.gemini/settings.json` | `mcpServers` |
| Hermes | installed-unverified | `~/.hermes` | `~/.hermes/skills` | — | `~/.hermes/config.yaml` (`mcp_servers:`) | YAML-embedded |
| Cursor | planned | `~/.cursor` | `~/.cursor/skills` | — | `~/.cursor/mcp.json` | `mcpServers` |

`status: active` = adopted and safe to touch by default.
`status: planned` = "official support exists, not installed here" is a legal,
stable state — declared to prove the schema extends; **only ever written
when you name it explicitly** with `--harness <id>`. Never a local install
requirement, never an error.

## Harness lifecycle

| status | meaning | in matrix | auto-touched |
| --- | --- | --- | --- |
| `active` | wired on this machine and verified by doctor | yes | yes |
| `planned` | official attach path exists; local install not required | no | no |
| `installed-unverified` | present here; capability Level 1-4 smoke test not finished | no | no |
| `verified` | real smoke test passed; operationally equals `active` | yes | yes |
| `unsupported` | no usable adapter or official capability path | no | no |

Promotion rules:
- A harness enters `installed-unverified` only through a human audit that
  confirms the CLI actually runs — a config directory appearing or
  `command -v` succeeding never promotes status by itself.
- Only a completed Level 1-4 smoke test (CLI reachable, skill attachable,
  MCP attachable, real capability call works) earns `verified`, and with it
  the right to a ✓ in the grid.
- Demotion to `planned`/`unsupported` is done by editing `manifest.yaml`,
  never implied by uninstalling software.
- The machine lives in mainland China; nothing in this toolbox may install,
  download, or reconfigure a harness as a side effect of
  `doctor` / `validate` / `status` / `capabilities` / `update`.

## `skill_scan_dirs` vs `skill_dir`

- `skill_dir` — where this harness keeps *its own* skill entries (the place a
  link would go).
- `skill_scan_dirs` — every directory this harness actually loads skills from.

If `~/.agents/skills` is in `skill_scan_dirs`, a capability's skill is already
visible to that harness and **no adapter action is needed** (`strategy:
shared`). Pi and OpenCode/Codex work that way; CodeBuddy and Qoder CN do not,
so they get links.

## Default strategies

| Harness | `skill_strategy` | `mcp_strategy` | Why |
| --- | --- | --- | --- |
| Pi | `shared` | `shared` | Pi scans `~/.agents/skills` and pi-mcp-adapter auto-reads `~/.agents/mcp.json` |
| CodeBuddy | `symlink` | `native` | own skill dir; native `mcp.json` |
| Qoder CN | `symlink` | `native` | own skill dir; MCP lives inside `settings.json` |
| OpenCode | `symlink` | `native` | own skill dir (plus shared scan); `opencode.jsonc` |

A capability can override either per harness (`capabilities.<cap>.harnesses.<id>`),
which is how `browser` uses the official installer on CodeBuddy but a plain
symlink on Qoder CN — `bsk install-skill` does not know a `qoder-cn` id.

## Adoption checklist for a new harness

1. Capability bodies work first: `bsk --version`, `ocr --version`,
   `codegraph explore "x"` — if these fail the problem is not the adapter.
2. Add a `harnesses.<id>` entry with the real paths (find them with the
   capability's own `--list` if it has one: `bsk install-skill --list`).
3. Wire `capabilities.<cap>.harnesses.<id>` only where the default is wrong.
4. `bash scripts/validate.sh` → `./bin/agent-toolbox doctor`.
5. Attach: `./bin/agent-toolbox install <cap> --harness <id> --apply`.
6. Verify the harness can actually use it (its own doctor / `mcp list`), then
   flip `status: active`.
