#!/usr/bin/env bash
# =============================================================================
# capability_test.sh — capability registry / matrix / doctor unit tests
#   usage: bash tests/unit/capability_test.sh <WORK> <FHOME>
#
# matrix and doctor are read-only, so this test runs them against its own
# throwaway $HOME and leaves the shared FHOME untouched.
# =============================================================================
set -uo pipefail
WORK="${1:?WORK}"; FHOME="${2:?FHOME}"
source "$WORK/tests/lib/assert.sh"
source "$WORK/tests/lib/stubs.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"
STUB="$TMP/bin"
MINBIN="$TMP/minbin"
BTMP="$TMP/broken"
mkdir -p "$H" "$STUB" "$MINBIN"
export HOME="$H"   # python assertions expand paths with the same fake HOME

make_cli "$STUB" bsk 0.3.0
make_cli "$STUB" ocr 1.12.12
make_cli "$STUB" codegraph 1.6.2
export PATH="$STUB:$PATH"

# prepared, healthy fake machine -------------------------------------------
for s in browser-skill open-code-review open-code-review-delegate; do
  mkdir -p "$H/.agents/skills/$s"
  printf '%s\n' "# $s" > "$H/.agents/skills/$s/SKILL.md"
done
mkdir -p "$H/.pi/agent" "$H/.codebuddy" "$H/.qoder-cn" "$H/.config/opencode"
# validate.sh checks that local manifest sources exist under the active $HOME
mkdir -p "$H/.pi/agent/extensions"
: > "$H/.pi/agent/extensions/rtk.ts"
cp "$WORK/profiles/shared/mcp.json" "$H/.agents/mcp.json"
mirror_hermes_config

run() { (cd "$WORK" && env HOME="$H" PATH="$PATH" bash scripts/doctor.sh "$@"); }

# ---------------------------------------------------------------------------
t_begin "matrix --json registry shape"
out="$(cd "$WORK" && env HOME="$H" bash scripts/capabilities.sh --json 2>&1)"; rc=$?
assert_eq "$rc" "0" 'matrix --json exits 0'
assert_true python3 -c "
import sys, json
d = json.load(sys.stdin)
caps = {c['id'] for c in d['capabilities']}
assert {'browser','code-review','code-intelligence'} <= caps, caps
assert {'exa','context7','searchcode'} <= caps, caps
h = {x['id']: x['status'] for x in d['harnesses']}
for k in ('pi','codebuddy','qoder-cn','opencode'): assert h.get(k) == 'active', h
assert h.get('claude-code') == 'planned', h
assert h.get('hermes') == 'verified', h
for c in d['capabilities']:
    assert 'cli' in c and 'skills_declared' in c and 'harnesses' in c, c['id']
" <<<"$out" 'capability + harness registry is complete'

t_begin "matrix --json: one shared source per skill"
out="$(cd "$WORK" && env HOME="$H" bash scripts/capabilities.sh --json 2>&1)"
assert_true python3 -c "
import sys, json, os
d = json.load(sys.stdin)
home = os.environ['HOME']
paths = []
for c in d['capabilities']:
    for h in c['harnesses']:
        for s in h['skills']:
            paths.append(s['shared_path'])
assert paths, 'no skill wiring declared'
assert all(p.startswith(os.path.join(home, '.agents', 'skills') + os.sep) for p in paths), paths
assert len(set(paths)) == len({os.path.basename(p) for p in paths}), sorted(set(paths))
" <<<"$out" 'every harness points at the single ~/.agents/skills source'

t_begin "matrix --grid renders the capability x harness matrix"
out="$(cd "$WORK" && env HOME="$H" bash scripts/capabilities.sh --grid 2>&1)"; rc=$?
assert_eq "$rc" "0" 'grid exits 0'
assert_contains "$out" "CAPABILITY x HARNESS" 'grid header'
assert_contains "$out" "browser" 'grid lists browser'
assert_contains "$out" "code-review" 'grid lists code-review'
assert_contains "$out" "code-intelligence" 'grid lists code-intelligence'

# ---------------------------------------------------------------------------
t_begin "matrix --grid separates harness lifecycle states"
out="$(cd "$WORK" && env HOME="$H" bash scripts/capabilities.sh --grid 2>&1)"; rc=$?
assert_eq "$rc" "0" 'lifecycle grid exits 0'
assert_contains "$out" "HARNESS LIFECYCLE" 'lifecycle section present'
assert_contains "$out" "claude-code  planned" 'planned listed as legal state'
assert_not_contains "$out" "hermes" 'hermes promoted out of the lifecycle section'
assert_true python3 -c "
import sys
grid = sys.stdin.read()
matrix, _, lifecycle = grid.partition('HARNESS LIFECYCLE')
assert 'Hermes' in matrix, 'hermes has a matrix column after promotion'
for h in ('Claude Code', 'Codex', 'Gemini', 'Cursor'):
    assert h not in matrix, h
" <<<"$out" 'only verified harnesses get a matrix column'
assert_true python3 -c "
import sys
grid = sys.stdin.read()
lifecycle = grid.split('HARNESS LIFECYCLE', 1)[1]
assert '✓' not in lifecycle and '✗' not in lifecycle
" <<<"$out" 'lifecycle section never shows ✓/✗ marks'

# ---------------------------------------------------------------------------
t_begin "doctor: healthy machine"
out="$(run --json 2>&1)"; rc=$?
assert_eq "$rc" "0" 'healthy doctor exits 0'
assert_true python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['healthy'] is True, d['summary']
assert d['summary']['errors'] == 0, d['summary']
assert d['summary']['warnings'] == 0, d['summary']
assert d['summary']['total'] >= 10, d['summary']
" <<<"$out" 'no errors, no warnings'
out="$(run 2>&1)"
assert_contains "$out" "read-only" 'human report states it is read-only'
assert_contains "$out" "Summary:" 'human summary line'

# ---------------------------------------------------------------------------
t_begin "doctor writes nothing"
snapshot_home() { (cd "$H" && find . -path './.stubver' -prune -o -printf '%p|%y|%T@\n' | sort); }
before="$(cd "$WORK" && cksum manifest.yaml lock.yaml)$(cd "$WORK" && [ -e state/install-log.jsonl ] && echo logged || echo nolog)"
before_home="$(snapshot_home)"
run --json >/dev/null 2>&1
run >/dev/null 2>&1
after="$(cd "$WORK" && cksum manifest.yaml lock.yaml)$(cd "$WORK" && [ -e state/install-log.jsonl ] && echo logged || echo nolog)"
after_home="$(snapshot_home)"
assert_eq "$after" "$before" 'registry files untouched by doctor'
assert_eq "$after_home" "$before_home" 'fake $HOME untouched by doctor'

# ---------------------------------------------------------------------------
t_begin "doctor: missing CLI is reported, not fatal"
for c in python3 jq bash sh env grep sed awk cat head tail sort uniq mkdir rm cp mv \
         ln ls chmod date stat dirname basename mktemp find sleep true; do
  p="$(command -v "$c" 2>/dev/null)" && ln -sf "$p" "$MINBIN/$c"
done
out="$(cd "$WORK" && env HOME="$H" PATH="$MINBIN" bash scripts/doctor.sh --json 2>&1)"; rc=$?
assert_eq "$rc" "0" 'missing CLI still exits 0'
assert_true python3 -c "
import sys, json
d = json.load(sys.stdin)
clis = [c for c in d['checks'] if c['name'].startswith('cli ')]
assert clis, d['checks']
assert all(c['status'] == 'missing' for c in clis), clis
" <<<"$out" 'cli checks marked missing'

# ---------------------------------------------------------------------------
t_begin "doctor: version drift warns and --strict fails"
printf '%s\n' "9.9.9" > "$H/.stubver/codegraph"
out="$(run --json 2>&1)"; rc=$?
assert_eq "$rc" "0" 'drift exits 0 without --strict'
assert_true python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['summary']['warnings'] >= 1, d['summary']
assert d['healthy'] is True, 'drift alone is not an error'
" <<<"$out" 'drift counted as warning'
out="$(run --strict 2>&1)"; rc=$?
assert_eq "$rc" "1" '--strict turns warnings into failure'
printf '%s\n' "1.6.2" > "$H/.stubver/codegraph"

# ---------------------------------------------------------------------------
t_begin "doctor: unprovenance skill copy is a foreign-copy warning"
mkdir -p "$H/.codebuddy/skills/open-code-review"
printf '%s\n' "copied" > "$H/.codebuddy/skills/open-code-review/SKILL.md"
out="$(run --json 2>&1)"; rc=$?
assert_eq "$rc" "0" 'foreign copy exits 0'
assert_contains "$out" "foreign-copy" 'copy without provenance is foreign-copy'
assert_contains "$out" "provenance" 'explains the missing provenance'
rm -rf "$H/.codebuddy/skills/open-code-review"

t_begin "doctor: installer-locked copy is managed-copy and healthy"
mkdir -p "$H/.codebuddy/skills/open-code-review" "$H/.codebuddy/skills/open-code-review-delegate"
printf '%s\n' "copied" > "$H/.codebuddy/skills/open-code-review/SKILL.md"
printf '%s\n' "copied" > "$H/.codebuddy/skills/open-code-review-delegate/SKILL.md"
cat > "$H/.agents/.skill-lock.json" <<'EOF'
{"version": 3, "skills": {
  "open-code-review": {"source": "alibaba/open-code-review", "sourceType": "github",
    "sourceUrl": "https://github.com/alibaba/open-code-review.git"},
  "open-code-review-delegate": {"source": "alibaba/open-code-review", "sourceType": "github",
    "sourceUrl": "https://github.com/alibaba/open-code-review.git"}
}}
EOF
out="$(run --json 2>&1)"; rc=$?
assert_eq "$rc" "0" 'managed copy exits 0'
assert_true python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['summary']['warnings'] == 0, d['checks']
mc = [c for c in d['checks'] if 'installer-managed copy' in c['detail']]
assert len(mc) == 2, d['checks']
assert all(c['status'] == 'ok' for c in mc), mc
" <<<"$out" 'lock-verified copies are healthy, no warnings'
rm -f "$H/.agents/.skill-lock.json"

t_begin "doctor: copy identical to shared source is managed-copy"
rm -rf "$H/.codebuddy/skills/open-code-review" "$H/.codebuddy/skills/open-code-review-delegate"
mkdir -p "$H/.codebuddy/skills/open-code-review" "$H/.codebuddy/skills/open-code-review-delegate"
cp -a "$H/.agents/skills/open-code-review/." "$H/.codebuddy/skills/open-code-review/"
cp -a "$H/.agents/skills/open-code-review-delegate/." "$H/.codebuddy/skills/open-code-review-delegate/"
out="$(run --json 2>&1)"; rc=$?
assert_true python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['summary']['warnings'] == 0, d['checks']
assert any('identical to the shared source' in c['detail'] for c in d['checks']), d['checks']
" <<<"$out" 'byte-identical copy counts as installer artifact'

t_begin "doctor: incomplete skill copy is broken"
rm -f "$H/.codebuddy/skills/open-code-review/SKILL.md"
out="$(run --json 2>&1)"; rc=$?
assert_contains "$out" "broken" 'copy without SKILL.md is broken'
assert_contains "$out" "no SKILL.md" 'broken explains the missing SKILL.md'
rm -rf "$H/.codebuddy/skills/open-code-review" "$H/.codebuddy/skills/open-code-review-delegate"

t_begin "doctor: dangling symlink is a warning"
mkdir -p "$H/.qoder-cn/skills"
ln -sfn "$H/.agents/skills/i-do-not-exist" "$H/.qoder-cn/skills/browser-skill"
out="$(run --json 2>&1)"; rc=$?
assert_eq "$rc" "0" 'dangling link exits 0'
assert_contains "$out" "dangling symlink" 'dangling symlink flagged'
rm -f "$H/.qoder-cn/skills/browser-skill"

t_begin "doctor: unparsable shared MCP config is an error"
printf '%s\n' '{ this is not json' > "$H/.agents/mcp.json"
out="$(run --json 2>&1)"; rc=$?
assert_eq "$rc" "1" 'error state exits 1'
assert_true python3 -c "
import sys, json
d = json.load(sys.stdin)
assert d['summary']['errors'] >= 1, d['summary']
assert d['healthy'] is False, d['healthy']
" <<<"$out" 'errors make doctor unhealthy'
cp "$WORK/profiles/shared/mcp.json" "$H/.agents/mcp.json"

# ---------------------------------------------------------------------------
t_begin "validate rejects bad capability cross-refs"
mkdir -p "$BTMP/scripts/lib" "$BTMP/profiles/shared"
cp "$WORK/scripts/lib/common.sh" "$BTMP/scripts/lib/"
cp "$WORK/scripts/validate.sh" "$BTMP/scripts/"
cat > "$BTMP/manifest.yaml" <<'EOF'
schema_version: 1
toolbox:
  model: capability
  shared_root: ~/.agents
harnesses:
  pi:
    id: pi
    name: Pi
    status: active
    config_root: ~/.pi/agent
    skill_dir: ~/.pi/agent/skills
    skill_scan_dirs: [~/.pi/agent/skills, ~/.agents/skills]
    skill_strategy: shared
    mcp_file: ~/.agents/mcp.json
    mcp_format: mcpServers
    mcp_strategy: shared
capabilities:
  cap1:
    id: cap1
    name: Cap
    description: a capability used by the test
    cli:
      resource: nope-cli
      command: nope
    skills:
    - resource: nope-skill
      shared_path: ~/.agents/skills/nope-skill
    harnesses:
      ghost: {}
      pi:
        skill_strategy: teleport
profiles:
  shared:
    path: ~/.agents
    config: {}
  global:
    path: ~/.pi/agent
    capabilities: [not-a-capability]
    config: {}
resources:
  clis: []
  skills: []
  mcp: []
  extensions: []
  packages: []
  prompts: []
  themes: []
EOF
cat > "$BTMP/lock.yaml" <<'EOF'
schema_version: 1
resources: {}
EOF
out="$(cd "$BTMP" && bash scripts/validate.sh 2>&1)"; rc=$?
assert_eq "$rc" "2" 'invalid capability registry exits 2'
assert_contains "$out" "is not in manifest resources" 'unknown cli resource flagged'
assert_contains "$out" "unknown harness 'ghost'" 'unknown harness reference flagged'
assert_contains "$out" "invalid skill_strategy 'teleport'" 'bad strategy flagged'
assert_contains "$out" "unknown capability 'not-a-capability'" 'profile capability ref flagged'

t_summary
