# Global profile

Target path: `~/.pi/agent/`

This profile declares the **global** (user-level) resources managed by the
toolbox. These apply to every project.

## What it manages

| File        | Purpose                                             |
|-------------|-----------------------------------------------------|
| `settings.json` | Declares global Pi packages (`packages`), `theme`, and `extensions` |
| `mcp.json`      | Declares global MCP servers (HTTP/URL endpoints)    |

## Notes / safety

- **`profiles/global/settings.json` is not a full mirror of
  `~/.pi/agent/settings.json`.** It only carries the resource keys the toolbox
  manages (`packages`, `theme`, `extensions`). Personal runtime choices
  (`defaultProvider`, `defaultModel`, `defaultThinkingLevel`, `npmCommand`, …)
  are intentionally excluded so that `install.sh` never overwrites them.
- **No secrets are stored.** Any MCP server that needs a credential records
  only the **environment-variable name** (e.g. `$EXA_API_KEY`), never the value.
  See [docs/security.md](../security.md).
- Global MCP servers here are HTTP/URL endpoints. There is no version ref to
  diff, so `check-updates.sh` reports them only when their URL/config changes.

## Apply

```bash
./scripts/install.sh global --dry-run   # preview
./scripts/install.sh global --apply     # actually write into ~/.pi/agent/
```
