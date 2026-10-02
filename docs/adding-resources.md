# Adding resources

To register a new skill, MCP server, Pi extension, package, or (reserved) prompt
template, add an entry to `manifest.yaml` under the matching resource group, and
(optionally) a matching profile in `catalog/` and `profiles/`. Then validate and,
if you want it installed, `install.sh`.

## Steps

1. **Pick the group.** Go to the right list in `manifest.yaml`:
   `resources.skills`, `resources.mcp`, `resources.extensions`,
   `resources.packages`, `resources.prompts` (reserved), or
   `resources.themes` (reserved). The resource's `kind` must equal the group.

2. **Choose a scope.** `global` if it applies everywhere; `project` + `projects`
   list if it only applies to specific repos.

3. **Fill the resource.** Use the schema in `docs/manifest.md`. Minimal example:

   ```yaml
   - id: my-tool
     name: my-tool
     kind: extension
     scope: global
     description: Helps with ...
     source:
       type: npm
       package: my-tool
       ref: 1.2.3
     resolution:
       version: 1.2.3
       commit: ''
       checked_at: 2026-10-02
     update:
       policy: weekly
       channel: stable
     security:
       trust: review
       executable: true
       review_required: true
     install:
       method: npm
       path: ~/.pi/agent
     tags: [tool]
   ```

   For a git skill:

   ```yaml
   - id: my-skill
     name: my-skill
     kind: skill
     scope: project
     projects: [agent-engineering-lab]
     source:
       type: github
       url: https://github.com/me/my-skill
       ref: v1.0.0
     update:
       policy: manual
     security:
       trust: review
       executable: false
       review_required: true
     install:
       method: git
       path: ~/projects/agent-engineering-lab/.pi/skills/my-skill
   ```

4. **Validate.** `./scripts/validate.sh`. It checks schema, ids, scopes, skill
   names, source types, local paths, MCP runtime, and secret-shaped strings.

5. **Lock it.** `./scripts/sync.sh --write-lock` regenerates `lock.yaml` from the
   manifest resolutions, so *want* and *have* stay in agreement:
   `./scripts/sync.sh` should report "No drift".

6. **(optional) Add a profile.** If the resource needs concrete config (e.g. it
   is registered in `settings.json` packages or `mcp.json` servers), edit
   `profiles/global/*` or `profiles/projects/<name>/*`. `install.sh --apply`
   will merge it (add-only, never clobbers).

7. **Install (only when you want it).**
   `./scripts/install.sh global --apply` or
   `./scripts/install.sh project <name> --apply`.

## MCP servers

MCP entries must declare a `runtime`. Either:

```yaml
runtime:
  url: https://example.com/mcp
```
or
```yaml
runtime:
  command: npx
  args: ["-y", "@scope/pkg", "stdio"]
  transport: stdio
```

Never paste API tokens into the runtime. Reference environment variables or Pi's
auth store instead (see `docs/security.md`).

## Remote manifest feed (optional)

If you maintain a shared catalog, you can set a `manifest-feed` URL (e.g. in the
toolbox config) and the resources it declares get merged with the local
`catalog/*.yaml` at check time. This is **not used by default**; the local
`catalog/` files are the baseline. Validate against the merged view so a feed
can't smuggle in an invalid or secret-bearing entry.

## Verification checklist

Before committing a new resource:

- [x] `./scripts/validate.sh` → `OK`
- [x] `./scripts/sync.sh` → `No drift`
- [x] `./scripts/status.sh --json` → the new id appears under the right scope
- [x] `./scripts/check-updates.sh --mock` runs clean
- [x] `bash tests/run-tests.sh` → `ALL TESTS PASSED`
- [x] If it is executable (extension/package/mcp) or security-sensitive, note
      that in the manifest `security` block so the update gate flags it.
