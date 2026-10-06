# Adapters

An **adapter** is the thin wiring between one capability and one harness. It
carries no logic and no copy of the tool — if every adapter were deleted, the
capability would still work from a shell.

```
Capability  ──>  Adapter (strategy)  ──>  Harness
 code-review      skill: installer         CodeBuddy
                  mcp: native
```

Resolution order (later wins only if the earlier is absent):

1. `capabilities.<cap>.harnesses.<hid>.<kind>_strategy` — explicit override
2. `harnesses.<hid>.<kind>_strategy` — harness default
3. not resolvable → `validate.sh` fails

## Skill strategies

| Strategy | What the adapter does | When |
| --- | --- | --- |
| `shared` | **Nothing.** The harness already scans `~/.agents/skills` (it is in `skill_scan_dirs`). | Pi, OpenCode (shared dirs), Codex |
| `symlink` | `ln -s ~/.agents/skills/<id> <skill_dir>/<id>` — only if the path is free. | Harness with its own skill dir |
| `installer` | Run the capability's official installer with this harness's id. | When upstream ships a multi-harness installer |

### `installer` in practice

```bash
# browser @ codebuddy  (installer id bsk -> CodeBuddy)
bsk install-skill --harness CodeBuddy -y

# code-review @ qoder-cn  (installer id skills -> qoder-cn)
npx skills add alibaba/open-code-review --skill '*' --global --agent qoder-cn --yes
```

The template lives on the capability, the id lives on the harness:

```yaml
capabilities.browser.installer = {id: bsk,  command: bsk,  args: [install-skill, --harness, '{id}', -y]}
harnesses.codebuddy.installer_ids = {bsk: CodeBuddy, skills: codebuddy}
```

**Skip-if-present.** If the skill is already correctly attached, no installer
runs — that is what makes `install … --apply` idempotent and keeps repeat runs
off the network.

### The six adapter states

A copy is **not** a duplicated capability: the CLI/MCP body always lives once.
These states only describe how the adapter folder physically presents itself
to one harness.

| Observed state | Meaning | Toolbox behaviour |
| --- | --- | --- |
| `shared` | harness scans the shared source directly | ✅ ok, no action |
| `symlink` | symlink resolves to the shared source | ✅ ok, no action |
| `managed-copy` | real-directory copy produced by the official installer, **provenance verified** | ✅ ok, no action, no warning |
| `foreign-copy` | copy/link whose provenance cannot be proven | ⚠ warning; plan shows a *conflict* |
| `broken` | dangling symlink, or a copy without `SKILL.md` | ⚠ warning; plan shows a *conflict* |
| `absent` | not attached | → install action |

A copy counts as `managed-copy` only on machine-verifiable evidence — never on
the directory name:

1. `~/.agents/.skill-lock.json` (written by the official `skills` installer)
   records this skill **and its source matches the upstream the registry
   declares**, or
2. the copy is **byte-identical** to the shared source it derives from
   (file tree + content hashes).

Anything else is `foreign-copy`. When in doubt we under-claim: an unknown copy
warns, it does not get a free pass.

For `foreign-copy`/`broken` the plan prints a *conflict* with a hint, and
`--apply` still refuses to touch it. Removing an unmanaged adapter is your
call (`npx skills remove …`, then re-run the install) — the toolbox does not
delete files it did not create.

## MCP strategies

| Strategy | What the adapter does |
| --- | --- |
| `shared` | Nothing to write — the harness reads `~/.agents/mcp.json` directly (Pi, Codex). |
| `native` | Mirror the shared definition into the harness's native config file, **add-only + backup**. |
| `profile` | Legacy V1 placement, kept only for schema compatibility — **no capability uses it**; every global MCP server now lives in the shared layer. |

`~/.agents/mcp.json` is the **tool-agnostic shared MCP source of truth**.
Harness-native configs are mirrors or references only; they must never become
independent sources again — edit `profiles/shared/mcp.json`, re-run
`install.sh shared --apply`, then the per-harness mirror installs.

### Formats

`mcp_format` decides the target shape:

| Format | Target key | Produced entry |
| --- | --- | --- |
| `mcpServers` | `mcpServers` | `{"command": "codegraph", "args": ["serve","--mcp"], "lifecycle": "eager"}` |
| `opencode-mcp` | `mcp` | `{"type":"local","command":["codegraph","serve","--mcp"],"enabled":true}` |
| `hermes-config-yaml` | `mcp_servers` (YAML) | `{"command":"codegraph","args":["serve","--mcp"],"enabled":true}` or `{"url":"https://mcp.exa.ai/mcp","enabled":true}` |

Mirrored targets today:

```
~/.agents/mcp.json                        <- source of truth (Pi reads it directly)
~/.codebuddy/mcp.json                     mcpServers   (native mirror)
~/.qoder-cn/settings.json                 mcpServers   (inside settings.json; native mirror)
~/.config/opencode/opencode.jsonc         opencode-mcp (JSONC tolerated; native mirror)
~/.hermes/config.yaml                     hermes-config-yaml (one block inside the user's YAML; native mirror)
```

### The Hermes YAML adapter

Hermes keeps MCP servers embedded in its user config, so the adapter is
text-surgical rather than a YAML round-trip:

- Parse with `safe_load` first; **invalid YAML → error, no write, no backup**.
- Duplicate `mcp_servers:` keys are refused before anything is touched (PyYAML
  would silently keep the last one).
- A new server is inserted into the `mcp_servers:` block by line surgery, so
  comments, key order, anchors and every key outside the block survive
  byte-exact. A missing block is appended at EOF; an empty one is filled.
- The mirror is strictly **one-way**: `~/.agents/mcp.json` is the source, and
  nothing in this repo ever writes back to it from Hermes state. A Hermes
  adapter is not an MCP source.
- Post-write the file is re-parsed and re-checked; on any mismatch the backup
  is restored.

### Equivalent vs equal

`doctor` asks *"does this launch the same server?"* — `command` + `args` (+ `url`
for remote) must match. Extra optional keys (`type`, `lifecycle`, `enabled`) do
not change what gets launched, so they are reported as **equivalent**, not drift.

The **merge** asks a stricter question — exact JSON equality — so it preserves a
config that differs at all and never overwrites yours. The two checks are
deliberately different: one avoids false alarms, the other avoids data loss.

## Project-local adapters (explicit opt-in)

By default every MCP definition is global/shared. To isolate a single project:

```bash
./bin/agent-toolbox install code-intelligence \
    --scope project --project agent-engineering-lab --apply
```

That is the **only** path that writes `<repo>/.pi/mcp.json`. Nothing else in the
toolbox creates it — the eight per-project `.pi/mcp.json` files of the old
Pi-centric layout were removed precisely to stop that spread. See
[scopes.md](scopes.md).

## Safety properties every adapter shares

1. Plan first — dry-run prints the exact command or file write.
2. Backup `<file>.atb-backup.<ts>` before touching an existing file.
3. Add-only: missing entries are added, differing entries preserved.
4. Verify after writing; restore the backup if verification fails.
5. Refuse to clobber an existing path.
6. Log to `state/install-log.jsonl`.
