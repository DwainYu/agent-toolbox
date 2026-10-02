#!/usr/bin/env bash
# =============================================================================
# workflow_test.sh — end-to-end test of the toolbox scripts against a copy
#   usage: bash tests/integration/workflow_test.sh <WORK> <FHOME>
#
# WORK  = a copy of the repo (tests never mutate the real checkout)
# FHOME = fake $HOME used for install.sh (never touches ~/.pi/agent)
# =============================================================================
set -uo pipefail
WORK="${1:?WORK}"; FHOME="${2:?FHOME}"
source "$WORK/tests/lib/assert.sh"

export WORK FHOME

# ---------------------------------------------------------------------------
t_begin "bootstrap"
out="$(cd "$WORK" && bash scripts/bootstrap.sh --json 2>&1)"
assert_true python3 -c "import sys,json; d=json.load(sys.stdin); assert d['healthy'] is True" <<<"$out" 'bootstrap reports healthy'

# ---------------------------------------------------------------------------
t_begin "validate"
out="$(cd "$WORK" && bash scripts/validate.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" 'validate passes'
assert_contains "$out" "OK" 'validate OK text'

# ---------------------------------------------------------------------------
t_begin "status --json"
out="$(cd "$WORK" && bash scripts/status.sh --json 2>&1)"
assert_true python3 -c "import sys,json; d=json.load(sys.stdin); assert 'global' in d and 'projects' in d and 'drift' in d" <<<"$out" 'status json has global/projects/drift'

# ---------------------------------------------------------------------------
t_begin "sync (no drift)"
out="$(cd "$WORK" && bash scripts/sync.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" 'sync exit 0'
assert_contains "$out" "No drift" 'sync reports in-sync'

t_begin "sync --write-lock keeps sync"
(cd "$WORK" && bash scripts/sync.sh --write-lock >/dev/null 2>&1)
out="$(cd "$WORK" && bash scripts/sync.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" 'sync still in sync after write-lock'

# ---------------------------------------------------------------------------
t_begin "install.sh global dry-run writes nothing"
F="$FHOME/.pi/agent/settings.json"
mkdir -p "$FHOME/.pi/agent"
printf '%s\n' '{"packages":["npm:pi-web-access"],"theme":"tokyo-night","customFlag":true}' > "$F"
printf '%s\n' '{"mcpServers":{"exa":{"url":"https://exa.example"}}}' > "$FHOME/.pi/agent/mcp.json"
before="$(cat "$F")"
env HOME="$FHOME" bash "$WORK/scripts/install.sh" global --dry-run >/dev/null 2>&1
mtime_before="$(stat -c %Y "$F")"
env HOME="$FHOME" bash "$WORK/scripts/install.sh" global >/dev/null 2>&1
mtime_after="$(stat -c %Y "$F")"
assert_eq "$mtime_before" "$mtime_after" 'no write on dry-run default'
assert_eq "$(cat "$F")" "$before" 'settings unchanged by dry-run'

t_begin "install.sh global --apply adds, preserves, backs up"
out="$(env HOME="$FHOME" bash "$WORK/scripts/install.sh" global --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'apply exits 0'
s="$(cat "$F")"
assert_true python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert 'npm:pi-hashline' in d['packages']" <<<"$s" 'missing package added'
assert_true python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert 'npm:pi-web-access' in d['packages']" <<<"$s" 'existing package preserved'
assert_true python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert d.get('customFlag') is True" <<<"$s" 'user-owned key preserved'
assert_eq "$(echo "$s" | grep -o 'pi-hashline' | wc -l)" "1" 'no duplicate package'
m="$(cat "$FHOME/.pi/agent/mcp.json")"
assert_true python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert 'context7' in d['mcpServers'] and 'searchcode' in d['mcpServers'] and 'exa' in d['mcpServers']" <<<"$m" 'mcp servers merged'
backups="$(ls "$FHOME/.pi/agent/"*.atb-backup.* 2>/dev/null | wc -l)"
assert_eq "$backups" "2" 'two backups written (settings + mcp)'

t_begin "install.sh global --apply is idempotent"
env HOME="$FHOME" bash "$WORK/scripts/install.sh" global --apply >/dev/null 2>&1
s="$(cat "$F")"
assert_eq "$(echo "$s" | grep -o '"npm:' | wc -l)" "$(python3 -c "import json;print(len(json.loads('''$s''')['packages']))")" 'no dupes after second apply'

# ---------------------------------------------------------------------------
t_begin "install.sh project --apply on target"
TDIR="$FHOME/proj"
mkdir -p "$TDIR/.pi"
printf '%s\n' '{"mcpServers":{"codegraph":{"command":"npx","args":["-y","@colbymchenry/codegraph","stdio"],"transport":"stdio"}}}' > "$TDIR/.pi/mcp.json"
out="$(env HOME="$FHOME" bash "$WORK/scripts/install.sh" project agent-engineering-lab --target "$TDIR" --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'project apply exits 0'
m="$(cat "$TDIR/.pi/mcp.json")"
assert_true python3 -c "import sys,json; d=json.loads(sys.stdin.read()); assert len(d['mcpServers'])==1 and 'codegraph' in d['mcpServers']" <<<"$m" 'codegraph preserved, no dup'

# ---------------------------------------------------------------------------
t_begin "check-updates --mock finds updates"
(cd "$WORK" && bash scripts/check-updates.sh --mock >/dev/null 2>&1); rc=$?
assert_eq "$rc" "1" 'updates found -> exit 1'

t_begin "check-updates --mock --apply bumps manifest+lock+report"
out="$(cd "$WORK" && bash scripts/check-updates.sh --mock --apply 2>&1)"; rc=$?
assert_eq "$rc" "1" 'apply exits 1 (updates applied -> PR needed)'
manifest="$(cat "$WORK/manifest.yaml")"
assert_contains "$manifest" "0.36.0" 'manifest bumped to mock latest'
assert_true python3 -c "import yaml; d=yaml.safe_load(open('$WORK/manifest.yaml')); assert [r['source']['ref'] for r in d['resources']['packages'] if r['id']=='pi-web-access']==['0.36.0']" 'ref bumped'
assert_exists "$WORK/CHANGELOG/update-report.json" 'update report written'
assert_true python3 -c "import json; d=json.load(open('$WORK/CHANGELOG/update-report.json')); assert d['updates'] and all('security_review_required' in u for u in d['updates'])" 'report schema'
out="$(cd "$WORK" && bash scripts/validate.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" 'repo still valid after bump'

t_begin "check-updates --mock (now up to date)"
(cd "$WORK" && bash scripts/check-updates.sh --mock >/dev/null 2>&1); rc=$?
assert_eq "$rc" "0" 'no more updates -> exit 0'

# ---------------------------------------------------------------------------
t_begin "sync after bump (in sync)"
out="$(cd "$WORK" && bash scripts/sync.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" 'in sync after bump'

t_summary