#!/usr/bin/env bash
# =============================================================================
# update_test.sh — tool update vs adapter update lifecycle
#   usage: bash tests/integration/update_test.sh <WORK> <FHOME>
#
# `update.sh --apply` rewrites manifest.yaml/lock.yaml, so this test runs on
# its OWN copy of WORK (repo rule: mutating tests bring their own copy) and
# its OWN fake $HOME. Upstream versions come from tests/fixtures/npm-versions.json
# via --mock, so no network is touched; the CLIs themselves are stubs.
# =============================================================================
set -uo pipefail
WORK="${1:?WORK}"; FHOME="${2:?FHOME}"
source "$WORK/tests/lib/assert.sh"
source "$WORK/tests/lib/stubs.sh"

MY="$(mktemp -d)"
trap 'rm -rf "$MY"' EXIT
W="$MY/work"
H="$MY/home"
S="$MY/bin"
cp -a "$WORK"/. "$W"/
rm -rf "$W/.git"
mkdir -p "$H/.stubver" "$S"
export HOME="$H"
export W

# stub CLIs: versions match manifest resolution, stubs bump to the fixture
# versions on update (codegraph 1.7.0 / ocr 1.13.0 — see npm-versions.json)
make_bsk "$S" 0.3.0
make_cli "$S" ocr 1.12.12
make_codegraph "$S" 1.6.2
make_npx "$S"
make_npm "$S"
export PATH="$S:$PATH"

# --- prepared machine ------------------------------------------------------
for s in browser-skill open-code-review open-code-review-delegate; do
  mkdir -p "$H/.agents/skills/$s"
  printf '%s\n' "# $s" > "$H/.agents/skills/$s/SKILL.md"
done
mkdir -p "$H/.pi/agent/extensions" "$H/.codebuddy" "$H/.qoder-cn" "$H/.config/opencode"
: > "$H/.pi/agent/extensions/rtk.ts"
cp "$W/profiles/shared/mcp.json" "$H/.agents/mcp.json"
# one indexed project, so the CodeGraph index section is exercised
mkdir -p "$H/projects/agent-engineering-lab/.codegraph"

upd() { (cd "$W" && env HOME="$H" PATH="$PATH" bash scripts/update.sh "$@"); }
ck_manifest() { (cd "$W" && cksum manifest.yaml lock.yaml); }

# ---------------------------------------------------------------------------
t_begin "update report separates tool updates from adapter updates"
before="$(ck_manifest)"
out="$(upd --mock 2>&1)"; rc=$?
assert_eq "$rc" "1" 'stale tools -> exit 1'
assert_contains "$out" "Tool updates" 'tool update section'
assert_contains "$out" "Adapter updates" 'adapter update section'
assert_contains "$out" "1.6.2 -> 1.7.0" 'codegraph has a newer release (mock)'
assert_contains "$out" "1.12.12 -> 1.13.0" 'ocr has a newer release (mock)'
assert_contains "$out" "incremental sync is enough" 'codegraph says no reindex needed'
assert_not_contains "$out" "reindexRecommended=true" 'no reindex recommended'
assert_eq "$(ck_manifest)" "$before" 'report is read-only'
assert_not_contains "$(cat "$H/.stubver/codegraph.calls" 2>/dev/null || true)" "upgrade" \
  'dry-run never invokes an updater'

t_begin "update --apply runs official updaters only (no index rebuild)"
out="$(upd --apply --mock 2>&1)"; rc=$?
assert_eq "$rc" "1" 'applied updates -> exit 1'
assert_contains "$out" "codegraph upgrade" 'delegates to codegraph upgrade'
assert_contains "$out" "npm install -g @alibaba-group/open-code-review" \
  'delegates to npm for ocr'
assert_contains "$out" "code-intelligence -> 1.7.0" 'tool version applied'
assert_contains "$out" "code-review -> 1.13.0" 'tool version applied'
assert_contains "$(cat "$H/.stubver/codegraph.calls")" "upgrade" 'codegraph updater invoked'
assert_contains "$(cat "$H/.stubver/npm.calls")" "install -g @alibaba-group/open-code-review" \
  'npm updater invoked'
assert_false bash -c 'grep -q "^codegraph index" "$1"' _ "$H/.stubver/codegraph.calls" \
  'never invokes `codegraph index` implicitly'

t_begin "registry reconciled to the installed versions"
assert_true python3 -c "
import os, yaml
m = yaml.safe_load(open(os.path.join(os.environ['W'], 'manifest.yaml')))
clis = {r['id']: r for r in m['resources']['clis']}
assert str(clis['codegraph-cli']['resolution']['version']) == '1.7.0', clis['codegraph-cli']
assert str(clis['codegraph-cli']['source']['ref']) == '1.7.0', clis['codegraph-cli']
assert str(clis['ocr']['resolution']['version']) == '1.13.0', clis['ocr']
assert str(clis['bsk']['resolution']['version']) == '0.3.0', 'untouched CLI moved'
" 'manifest versions updated in place'
out="$(cd "$W" && bash scripts/sync.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" 'lock regenerated in sync'
assert_contains "$out" "No drift" 'no drift after update'

t_begin "adapter refresh rewires skills and MCP (idempotent)"
assert_eq "$(readlink -f "$H/.codebuddy/skills/browser-skill")" \
  "$(readlink -f "$H/.agents/skills/browser-skill")" 'installer wired codebuddy browser'
assert_eq "$(readlink -f "$H/.qoder-cn/skills/browser-skill")" \
  "$(readlink -f "$H/.agents/skills/browser-skill")" 'symlink wired qoder browser'
assert_true python3 -c "
import os, sys
sys.path.insert(0, os.path.join(os.environ['W'], 'scripts', 'lib'))
from merge_config import load_json
home = os.environ['HOME']
for path, key in [('.codebuddy/mcp.json', 'mcpServers'),
                  ('.qoder-cn/settings.json', 'mcpServers'),
                  ('.config/opencode/opencode.jsonc', 'mcp')]:
    d = load_json(os.path.join(home, path))
    assert 'codegraph' in d.get(key, {}), (path, d)
" 'MCP mirrored into every native harness config'
assert_eq "$(find "$H" -name browser-skill -type d | wc -l)" "1" 'still one shared source'
assert_not_exists "$H/projects/agent-engineering-lab/.pi/mcp.json" \
  'project MCP still not created'

t_begin "state log records the update"
assert_contains "$(cat "$W/state/install-log.jsonl")" '"event": "update"' 'update logged'

t_begin "second report is clean (idempotent, no pending work)"
out="$(upd --mock 2>&1)"; rc=$?
assert_eq "$rc" "0" 'nothing left to do -> exit 0'
assert_not_contains "$out" "-> " 'no version transitions pending'
assert_contains "$out" "all wired adapters healthy" 'adapters healthy'

t_begin "--reindex only ever runs when recommended"
out="$(upd --apply --reindex --mock 2>&1)"; rc=$?
assert_eq "$rc" "0" 'no updates, no reindex needed -> exit 0'
assert_false bash -c 'grep -q "^codegraph index" "$1"' _ "$H/.stubver/codegraph.calls" \
  'no codegraph index when reindexRecommended=false'

t_begin "--reindex runs a full index only when codegraph recommends it"
: > "$H/.stubver/reindex-recommended"
out="$(upd --mock 2>&1)"; rc=$?
assert_eq "$rc" "1" 'recommended reindex -> pending work'
assert_contains "$out" "reindexRecommended=true" 'report surfaces the recommendation'
assert_contains "$out" "./scripts/update.sh --apply --reindex" 'tells the user the exact command'
out="$(upd --apply --reindex --mock 2>&1)"; rc=$?
assert_eq "$rc" "1" 'reindex requested -> reported as pending'
assert_contains "$out" "full reindex agent-engineering-lab" 'full index ran for the project'
assert_contains "$(cat "$H/.stubver/codegraph.calls")" "index" 'codegraph index invoked once'
rm -f "$H/.stubver/reindex-recommended"

t_begin "update --apply is never allowed in CI"
assert_false bash -c 'grep -rn "update.sh" "$1" | grep -q -- "--apply"' _ "$W/.github/workflows" \
  'no workflow runs update.sh --apply'
assert_false bash -c 'grep -rn "pi install" "$1" >/dev/null' _ "$W/.github/workflows" \
  'no workflow runs pi install'

t_summary
