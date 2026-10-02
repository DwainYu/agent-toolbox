# Project profile: agent-engineering-lab

- Repo: `DwainYu/agent-engineering-lab`
- Local path: `~/projects/agent-engineering-lab`
- Toolbox managed target: `<repo>/.pi/`

## Resources

| Kind   | Id                        | Source                          | Status        |
|--------|---------------------------|---------------------------------|---------------|
| MCP    | `codegraph`               | npm `@colbymchenry/codegraph`   | managed       |
| Skill  | `bilingual-learning`      | this repo (owned)               | reference-only |

## Notes

- **`bilingual-learning`** is authored and versioned inside this repository
  (`.pi/skills/bilingual-learning`). It is **not** a third-party resource, so
  the toolbox records it as **reference-only** in `catalog/skills.yaml` and does
  not copy or vendor it.
- **MCP** here is the `codegraph` stdio server (command `codegraph serve --mcp`).
  It is declared per-project because codegraph indexes this repo's codebase.

> Project-scoped skills/extensions only load after Pi trusts the project. See
> [docs/scopes.md](../../scopes.md) and the Pi docs on `trust.json`.
