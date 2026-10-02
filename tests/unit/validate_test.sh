#!/usr/bin/env bash
# =============================================================================
# validate_test.sh — tests for scripts/validate.sh
#   usage: bash tests/unit/validate_test.sh <WORK> <FHOME>
# =============================================================================
set -uo pipefail
WORK="${1:?WORK}"; FHOME="${2:?FHOME}"
source "$WORK/tests/lib/assert.sh"

t_begin "validate clean repo"
out="$(cd "$WORK" && bash scripts/validate.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" 'clean repo exits 0'
assert_contains "$out" "OK" 'reports OK'

t_begin "validate on broken manifest"
BTMP="$(mktemp -d)"
trap 'rm -rf "$BTMP"' RETURN
mkdir -p "$BTMP/scripts/lib" "$BTMP/profiles/global"
cp "$WORK/scripts/lib/common.sh" "$BTMP/scripts/lib/"
cp "$WORK/scripts/validate.sh" "$BTMP/scripts/"
cat > "$BTMP/manifest.yaml" <<'EOF'
schema_version: 1
resources:
  skills:
    - id: bad
      kind: mcp
      scope: global
      name: Bad_Name
      source: {type: npm}
      update: {policy: nope}
EOF
cat > "$BTMP/lock.yaml" <<'EOF'
schema_version: 1
resources: {}
EOF
out="$(cd "$BTMP" && bash scripts/validate.sh 2>&1)"; rc=$?
assert_eq "$rc" "2" 'broken manifest exits 2'
assert_contains "$out" "does not match group" 'kind/group mismatch flagged'
assert_contains "$out" "invalid update.policy" 'policy flagged'

t_begin "secret scan"
mkdir -p "$BTMP/profiles/global"
cat > "$BTMP/profiles/global/leak.json" <<'EOF'
{"token":"sk-abcdefghijklmnopqrstuvwxyz123456"}
EOF
out="$(cd "$BTMP" && bash scripts/validate.sh 2>&1)"; rc=$?
assert_eq "$rc" "2" 'secret detected -> exit 2'
assert_contains "$out" "potential secret" 'secret flagged'

t_begin "validate emits JSON"
out="$(cd "$WORK" && bash scripts/validate.sh --json 2>&1)"
assert_true python3 -c "import sys,json; d=json.load(sys.stdin); assert d['valid'] is True" <<<"$out" 'valid:true in json'

rm -rf "$BTMP"
t_summary