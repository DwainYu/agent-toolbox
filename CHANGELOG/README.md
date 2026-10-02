# CHANGELOG

This directory holds **generated** update reports, produced by
`scripts/check-updates.sh --apply` and committed by the weekly
`.github/workflows/check-updates.yml` workflow.

| File                 | Purpose                                                            |
| -------------------- | ------------------------------------------------------------------ |
| `update-report.json` | Machine-readable list of the updates just applied (current → latest, source, kind, scope, `security_review_required`, `command_changed`). Used as the input when rendering the update PR body. |

These files are **generated**, not hand-authored. Do not edit them directly; run
`./scripts/check-updates.sh --apply` (or the workflow) and it will be rewritten.

Human-readable release notes for the managed resources live in the manifest and
each resource's own upstream project; this directory intentionally holds only
the structured report needed to open and review an update PR.
