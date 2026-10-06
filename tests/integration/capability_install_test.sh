#!/usr/bin/env bash
# =============================================================================
# capability_install_test.sh — capability installs against a throwaway machine
#   usage: bash tests/integration/capability_install_test.sh <WORK> <FHOME>
#
# This test mutates the repo copy (state/install-log.jsonl), so it makes its
# OWN copy of WORK and its OWN fake $HOME; the harness copy stays pristine.
#
# Official installers are stubbed on PATH (tests/lib/stubs.sh): the toolbox
# must delegate, never re-implement a download.
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
mkdir -p "$H" "$S"
export HOME="$H"
export W

make_bsk "$S" 0.3.0
make_cli "$S" ocr 1.12.12
make_cli "$S" codegraph 1.6.2
make_npx "$S"
export PATH="$S:$PATH"

# --- prepared machine ------------------------------------------------------
for s in browser-skill open-code-review open-code-review-delegate; do
  mkdir -p "$H/.agents/skills/$s"
  printf '%s\n' "# $s" > "$H/.agents/skills/$s/SKILL.md"
done
mkdir -p "$H/.pi/agent/extensions" "$H/.codebuddy" "$H/.qoder-cn" "$H/.config/opencode"
mkdir -p "$H/.stubver"                 # stubs' state dir: keep root mtime stable
: > "$H/.pi/agent/extensions/rtk.ts"     # local manifest source (validate.sh)
mkdir -p "$H/projects/agent-engineering-lab"
# user-owned config that must survive every merge
printf '%s\n' '{"mcpServers":{"my-private":{"url":"https://private.example"}}}' \
  > "$H/.agents/mcp.json"
printf '%s\n' '{"mcpServers":{"my-codebuddy":{"command":"echo"}}}' \
  > "$H/.codebuddy/mcp.json"

snap() { (cd "$H" && find . -path './.stubver' -prune -o -printf '%p|%T@\n' | sort); }
cap()  { (cd "$W" && env HOME="$H" PATH="$PATH" bash scripts/install.sh "$@"); }
backups() { find "$H" -name '*.atb-backup.*' | sort; }

# ---------------------------------------------------------------------------
t_begin "capability install is dry-run by default"
before="$(snap)"
out="$(cap code-intelligence --harness pi 2>&1)"; rc=$?
assert_eq "$rc" "0" 'dry-run exits 0'
assert_contains "$out" "dry-run" 'dry-run is the default mode'
assert_contains "$out" "code-intelligence" 'names the capability'
assert_eq "$(snap)" "$before" 'dry-run writes nothing'

t_begin "bin/agent-toolbox dispatches capability installs"
out="$(cd "$W" && env HOME="$H" PATH="$PATH" bash bin/agent-toolbox install code-intelligence --harness pi 2>&1)"; rc=$?
assert_eq "$rc" "0" 'dispatcher exits 0'
assert_contains "$out" "dry-run" 'dispatcher reaches capability install'
out="$(cd "$W" && env HOME="$H" PATH="$PATH" bash bin/agent-toolbox capabilities --grid 2>&1)"; rc=$?
assert_eq "$rc" "0" 'dispatcher capabilities --grid'
assert_contains "$out" "CAPABILITY x HARNESS" 'grid via dispatcher'

t_begin "V1 shared mirror is add-only with backup"
out="$(cap shared --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'install.sh shared --apply exits 0'
assert_true python3 -c "
import os, sys, glob
sys.path.insert(0, os.path.join(os.environ['W'], 'scripts', 'lib'))
from merge_config import load_json
d = load_json(os.path.join(os.environ['HOME'], '.agents', 'mcp.json'))
assert 'codegraph' in d['mcpServers'], d
assert 'my-private' in d['mcpServers'], 'user-owned server lost!'
" 'codegraph added, my-private preserved'
assert_contains "$(backups)" "mcp.json.atb-backup" 'backup created before write'

t_begin "capability install idempotent (second run: already in sync)"
out="$(cap code-intelligence --harness pi --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'apply exits 0'
assert_contains "$out" "Already in sync" 'nothing left to do'
n1="$(backups | wc -l)"
out="$(cap code-intelligence --harness pi --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'second apply exits 0'
assert_contains "$out" "Already in sync" 'still in sync'
assert_eq "$(backups | wc -l)" "$n1" 'no extra backup on re-run'

t_begin "native MCP formats per harness"
out="$(cap code-intelligence --harness codebuddy --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'codebuddy apply'
assert_true python3 -c "
import os, sys
sys.path.insert(0, os.path.join(os.environ['W'], 'scripts', 'lib'))
from merge_config import load_json
d = load_json(os.path.join(os.environ['HOME'], '.codebuddy', 'mcp.json'))
assert 'codegraph' in d['mcpServers'], d
assert 'my-codebuddy' in d['mcpServers'], 'user-owned server lost!'
" 'codebuddy mcpServers merged add-only'

out="$(cap code-intelligence --harness opencode --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'opencode apply'
assert_true python3 -c "
import os, sys
sys.path.insert(0, os.path.join(os.environ['W'], 'scripts', 'lib'))
from merge_config import load_json
d = load_json(os.path.join(os.environ['HOME'], '.config', 'opencode', 'opencode.jsonc'))
e = d['mcp']['codegraph']
assert e['type'] == 'local', e
assert e['command'] == ['codegraph', 'serve', '--mcp'], e
" 'opencode mcp key with command array'

t_begin "MCP mirror: equivalent entry is a no-op, drift is preserved not clobbered"
# equivalent: a cosmetic extra key must count as satisfied, with no rewrite
python3 -c "
import os, json
p = os.path.join(os.environ['HOME'], '.codebuddy', 'mcp.json')
d = json.load(open(p)); d['mcpServers']['codegraph']['type'] = 'stdio'
json.dump(d, open(p, 'w'), indent=2)
"
n1="$(backups | wc -l)"
out="$(cap code-intelligence --harness codebuddy --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'equivalent mirror apply exits 0'
assert_contains "$out" "equivalent" 'launch-identical entry recognized as satisfied'
assert_eq "$(backups | wc -l)" "$n1" 'equivalent mirror not rewritten'
# drift: a different command must be preserved (add-only), never overwritten
python3 -c "
import os, json
p = os.path.join(os.environ['HOME'], '.codebuddy', 'mcp.json')
d = json.load(open(p)); d['mcpServers']['codegraph']['command'] = 'echo'
json.dump(d, open(p, 'w'), indent=2)
"
out="$(cap code-intelligence --harness codebuddy --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'drift apply exits 0'
assert_contains "$out" "already present" 'drift reported, not clobbered'
assert_contains "$(cat "$H/.codebuddy/mcp.json")" '"command": "echo"' 'drifted entry preserved'
rm -f "$H/.codebuddy/mcp.json"
out="$(cap code-intelligence --harness codebuddy --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'clean mirror re-created'
assert_true python3 -c "
import os, sys
sys.path.insert(0, os.path.join(os.environ['W'], 'scripts', 'lib'))
from merge_config import load_json
d = load_json(os.path.join(os.environ['HOME'], '.codebuddy', 'mcp.json'))
assert d['mcpServers']['codegraph']['command'] == 'codegraph', d
" 'mirror back to the shared definition'

t_begin "symlink adapter: one shared source, many harness links"
out="$(cap browser --harness qoder-cn --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'qoder symlink apply'
link="$H/.qoder-cn/skills/browser-skill"
assert_exists "$link" 'link created'
assert_eq "$(readlink -f "$link")" "$(readlink -f "$H/.agents/skills/browser-skill")" \
  'link points at the shared source'
assert_eq "$(find "$H" -name browser-skill -type d | wc -l)" "1" \
  'exactly one real browser-skill directory'
linktime="$(stat -c %Y "$link")"
out="$(cap browser --harness qoder-cn --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'second apply exits 0'
assert_contains "$out" "Already in sync" 'link state is stable'
assert_eq "$(stat -c %Y "$link")" "$linktime" 'link not re-created'

t_begin "installer strategy delegates to the official installer"
out="$(cap browser --harness codebuddy --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'codebuddy apply'
assert_contains "$out" "bsk install-skill" 'official installer command shown'
assert_contains "$(cat "$H/.stubver/bsk.calls")" "install-skill --harness CodeBuddy -y" \
  'bsk invoked with the harness id'
assert_eq "$(readlink -f "$H/.codebuddy/skills/browser-skill")" \
  "$(readlink -f "$H/.agents/skills/browser-skill")" 'installer wired an adapter link'
n="$(grep -c "install-skill" "$H/.stubver/bsk.calls")"
out="$(cap browser --harness codebuddy --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'second apply exits 0'
assert_contains "$out" "Already in sync" 'adapter satisfied'
assert_eq "$(grep -c "install-skill" "$H/.stubver/bsk.calls")" "$n" \
  'installer not re-run when already wired'

t_begin 'code-review installer uses npx skills add'
out="$(cap code-review --harness qoder-cn --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'qoder code-review apply'
assert_contains "$out" "npx skills add" 'npx skills add shown'
assert_contains "$(cat "$H/.stubver/npx.calls")" "--agent qoder-cn" 'agent id passed to skills CLI'
assert_exists "$H/.qoder-cn/skills/open-code-review" 'first skill adapter wired'
assert_exists "$H/.qoder-cn/skills/open-code-review-delegate" 'second skill adapter wired'

t_begin "foreign copy is a conflict, never clobbered"
rm -f "$H/.qoder-cn/skills/browser-skill"
mkdir -p "$H/.qoder-cn/skills/browser-skill"
printf '%s\n' "user-edited copy" > "$H/.qoder-cn/skills/browser-skill/SKILL.md"
printf '%s\n' "keep me" > "$H/.qoder-cn/skills/browser-skill/KEEP.md"
out="$(cap browser --harness qoder-cn --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'conflict exits 0 (reported, not fatal)'
assert_contains "$out" "conflict" 'conflict reported'
assert_contains "$out" "foreign-copy" 'explains the unmanaged copy'
assert_exists "$H/.qoder-cn/skills/browser-skill/KEEP.md" 'existing copy untouched'

t_begin "planned harnesses are never touched"
out="$(cap browser --all-harnesses --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" '--all-harnesses exits 0'
assert_contains "$out" "pi" 'active harness in target list'
assert_not_contains "$out" "claude-code" 'planned harness not targeted'
assert_not_exists "$H/.claude" 'no config written for planned harness'

t_begin "project MCP only via explicit --scope project"
proj="$(find "$H" -path '*/.pi/mcp.json' | wc -l)"
assert_eq "$proj" "0" 'no project .pi/mcp.json created by default'
out="$(cap code-intelligence --scope project --harness pi 2>&1)"; rc=$?
assert_eq "$rc" "2" 'project scope without --target/--project fails'
assert_contains "$out" "--project" 'explains what is missing'
out="$(cap code-intelligence --scope project --project agent-engineering-lab \
        --target "$H/projects/agent-engineering-lab" --apply 2>&1)"; rc=$?
assert_eq "$rc" "0" 'explicit project scope applies'
assert_exists "$H/projects/agent-engineering-lab/.pi/mcp.json" 'explicit project MCP written'
assert_eq "$(find "$H" -path '*/.pi/mcp.json' | wc -l)" "1" 'exactly one, written on demand'

t_begin "mutations are logged, state is git-ignored"
assert_exists "$W/state/install-log.jsonl" 'install log written'
assert_contains "$(cat "$W/state/install-log.jsonl")" '"event": "install"' 'log entries recorded'
assert_contains "$(cat "$W/.gitignore")" "state/" 'state/ is git-ignored'

t_begin "doctor agrees with the final machine state"
out="$(cd "$W" && env HOME="$H" PATH="$PATH" bash scripts/doctor.sh --json 2>&1)"; rc=$?
assert_eq "$rc" "0" 'doctor exits 0'
assert_true python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['summary']['errors'] == 0, d['summary']
assert d['summary']['warnings'] >= 1, d['summary']
" <<<"$out" 'no errors; the deliberate duplicate copy is still flagged'
rm -rf "$H/.qoder-cn/skills/browser-skill"
out="$(cap browser --harness qoder-cn --apply 2>&1)"
out="$(cd "$W" && env HOME="$H" PATH="$PATH" bash scripts/doctor.sh --strict 2>&1)"; rc=$?
assert_eq "$rc" "0" 'doctor --strict clean after re-wiring'

t_summary
