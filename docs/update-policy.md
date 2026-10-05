# Update policy

The toolbox knows how to find newer versions, but **who decides to apply them is
deliberately human-mediated**, except for the low-touch case of opening an update
PR.

## Per-resource policy (`update.policy`)

Each resource declares how aggressively it should be updated:

| Policy     | Meaning                                                                 |
| ---------- | ----------------------------------------------------------------------- |
| `manual`   | Never updated automatically. Only checked when *you* run `check-updates.sh`. Default. |
| `daily`    | Checked on the daily schedule (only if you add a daily cron).           |
| `weekly`   | Checked by the weekly `.github/workflows/check-updates.yml` job.        |
| `monthly`  | Checked monthly.                                                       |
| `pin`      | Frozen. `check-updates` never proposes a change, even if upstream moved. |

Policy applies to the resource's **kind**, which decides *what* gets updated:

- `kind: cli` — a **tool update**: `check-updates.sh` probes npm (or leaves
  `source.type: manual` alone), `update.sh --apply` upgrades the binary via its
  official installer (`npm i -g`, `codegraph upgrade`, ...).
- `kind: skill` / `kind: mcp` — an **adapter/config update**: usually pinned or
  manual, and applied by re-running `install.sh --apply` (re-mirroring shared
  config), never by re-downloading the tool itself.

One version record per tool: the CLI record owns the version; the MCP/skill
adapters that wrap the same tool don't carry a competing `resolution.version`
(see `docs/lifecycle.md`).

The default workflow ships a **weekly** cron (`.github/workflows/check-updates.yml`).
Bump a resource to `daily` or `monthly` only if you genuinely want that cadence.

## Who does what

| Step                        | Tool / actor                | Touches your live machine? |
| --------------------------- | --------------------------- | -------------------------- |
| Probe upstream for newer    | `check-updates.sh`          | No — reads `npm view` / `git ls-remote` only. |
| Record new resolution       | `check-updates.sh --apply`  | No — writes `manifest.yaml`, `lock.yaml`, `update-report.json` in the repo. |
| Open a reviewable change    | `.github/workflows/check-updates.yml` (weekly) | No — opens a PR. |
| Promote to main             | You, after reviewing + merging | No — merge only updates the repo. |
| Install to the machine      | `install.sh --apply`        | **Yes** — only when you run it. |
| Upgrade a tool / re-sync adapters | `update.sh --apply`    | **Yes** — only when you run it; never in CI. |

Key property: **CI never modifies your real environment.** The weekly workflow
only probes upstream, applies the resolution to the repo, and opens a PR. You
review the PR, and if happy, merge. Then, *when you want*, you run
`install.sh --apply` on the machine to actually install.

## Security gate on updates

`scripts/check-updates.sh` marks each update with `security_review_required`.
It is `true` for:

- any **executable** resource (`extension`, `package`, `mcp`);
- anything whose manifest `security.review_required` is `true`.

The update PR body explicitly warns which updates need a manual security review
before merge. This is the point at which you should read the upstream release
notes before approving.

## Why not `pi update` here?

Pi's native `pi update -l` is the *installer* path — it updates what's already
installed on this machine. The toolbox is the *registry* path — it records what
you *want* and how to reproduce it. These are complementary:

- To keep a machine current, use `pi update -l` (native) or `install.sh --apply`.
- To keep the *toolbox* (the registry) current and reproducible, use this
  repo's `check-updates.sh` → PR → merge flow.

The toolbox never rewrites the repo from a machine's state and never rewrites a
machine's state from the repo implicitly — both are explicit.

## Dependabot is for the toolbox, not its managed resources

`.github/dependabot.yml` only watches the **building blocks of the toolbox
itself** (GitHub Actions versions, `requirements-dev.txt`). The resources the
toolbox manages are driven by `check-updates.yml` so every resource change passes
the same review gate. See `.github/dependabot.yml` for the comment explaining
this.
