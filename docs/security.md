# Security

The toolbox manages **executables and remote endpoints**, so it treats secrets
and untrusted resources seriously. The stance is: **graph, review, and verify —
never trust implicitly.**

## What the toolbox never does

- It never stores or writes secrets.
- It never auto-applies config on a schedule; `install.sh --apply` is the only
  writer to `~/.pi/agent` / project dirs and is explicit.
- CI never touches your live environment. The update workflow only probes
  upstream and opens a PR.
- It never bypasses Pi's project-trust model; a project-scoped skill/extension
  loads only after you trust the project in Pi.

## Secrets

`~/.pi/agent/auth.json`, `.env`, and any file containing real tokens live outside
the toolbox and are **never committed** (see `.gitignore` and `docs/adding-resources.md`).

`scripts/validate.sh` scans every `*,yaml`/`*.json` in the repo for
secret-shaped strings and fails the build if one is found. Patterns include:

- `sk-[A-Za-z0-9_-]{16,}` (API keys)
- `ghp_[A-Za-z0-9]{20,}` / `github_pat_[A-Za-z0-9_]{20,}` (GitHub tokens)
- `AKIA[0-9A-Z]{16}` (AWS access keys)
- `-----BEGIN ... PRIVATE KEY-----` (private keys)
- `eyJ...` (JWT-like tokens)
- `Bearer <token>`, `token=...`, `password=...` assignments

If a resource genuinely needs a token at runtime, reference it via an
environment variable or Pi's auth store (`~/.pi/agent/auth.json`) — never paste
the value into a profile in this repo. `install.sh` and the profiles use
placeholder references only.

## Trust levels (`security.trust`)

| `trust`   | Meaning                                              |
| --------- | ---------------------------------------------------- |
| `review`  | You (or a reviewer) looked at it; flagged `review_required` where the resource is executable. |
| `open`    | vetted and auto-approved for low-risk resources.     |
| `restricted` | Not installed on untrusted machines; always gated. |

`security.executable` and `security.review_required` feed directly into
`check-updates.sh`'s `security_review_required` flag and the update PR warning.

## MCP servers are remote code

An MCP server is an executable that runs locally against your files and data. The
toolbox records where it comes from (`source.url` / `source.package`) and its
`runtime`. Before adding one:

1. Confirm the source is trusted (official repo or a pinned version).
2. Review what filesystem/network access it needs (`runtime.args`).
3. Prefer `stdio` servers from a pinned npm version over arbitrary `url`
   endpoints you don't control.

`validate.sh` requires every MCP entry to declare either `runtime.url` or
`runtime.command` + `transport: stdio`, so an MCP is never a silent guess.

## Repo hygiene / supply chain

- Pin versions in `source.ref` for `npm` and `git`/`github` sources.
- `lock.yaml` records the resolved commit/version so a change is diffable.
- Every update flows through a reviewable PR (`.github/workflows/check-updates.yml`)
  with the security flag surfaced in the body.
- `docs/update-policy.md` explains the review gate.

If you find a secret or an untrusted resource, remove it from the manifest, run
`./scripts/validate.sh`, and rotate the credential at the source.
