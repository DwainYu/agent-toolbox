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

t_begin "validate accepts the harness lifecycle statuses"
BTMP2="$(mktemp -d)"
mkdir -p "$BTMP2/scripts/lib" "$BTMP2/profiles"
cp "$WORK/scripts/lib/common.sh" "$BTMP2/scripts/lib/"
cp "$WORK/scripts/validate.sh" "$BTMP2/scripts/"
cat > "$BTMP2/lock.yaml" <<'EOF'
schema_version: 1
resources: {}
EOF
cat > "$BTMP2/manifest.yaml" <<'EOF'
schema_version: 1
harnesses:
  h-active:
    id: h-active
    name: H
    status: active
    config_root: ~/.h
    skill_dir: ~/.h/skills
    skill_strategy: symlink
    mcp_strategy: native
    mcp_format: mcpServers
    mcp_file: ~/.h/mcp.json
  h-planned:
    id: h-planned
    name: H
    status: planned
    config_root: ~/.h
    skill_dir: ~/.h/skills
    skill_strategy: symlink
    mcp_strategy: native
    mcp_format: mcpServers
    mcp_file: ~/.h/mcp.json
  h-installed-unverified:
    id: h-installed-unverified
    name: H
    status: installed-unverified
    config_root: ~/.h
    skill_dir: ~/.h/skills
    skill_strategy: symlink
    mcp_strategy: native
    mcp_format: mcpServers
    mcp_file: ~/.h/mcp.json
  h-verified:
    id: h-verified
    name: H
    status: verified
    config_root: ~/.h
    skill_dir: ~/.h/skills
    skill_strategy: symlink
    mcp_strategy: native
    mcp_format: mcpServers
    mcp_file: ~/.h/mcp.json
  h-unsupported:
    id: h-unsupported
    name: H
    status: unsupported
    config_root: ~/.h
    skill_dir: ~/.h/skills
    skill_strategy: symlink
    mcp_strategy: native
    mcp_format: mcpServers
    mcp_file: ~/.h/mcp.json
EOF
out="$(cd "$BTMP2" && bash scripts/validate.sh 2>&1)"; rc=$?
assert_eq "$rc" "0" "all five lifecycle statuses accepted"

cat >> "$BTMP2/manifest.yaml" <<'EOF'
  h-bad:
    id: h-bad
    name: H
    status: beta
    config_root: ~/.h
    skill_dir: ~/.h/skills
    skill_strategy: symlink
    mcp_strategy: native
    mcp_format: mcpServers
    mcp_file: ~/.h/mcp.json
EOF
out="$(cd "$BTMP2" && bash scripts/validate.sh 2>&1)"; rc=$?
assert_eq "$rc" "2" 'unknown status rejected'
assert_contains "$out" "invalid status" 'invalid status flagged'
rm -rf "$BTMP2"

t_begin "validate emits JSON"
out="$(cd "$WORK" && bash scripts/validate.sh --json 2>&1)"
assert_true python3 -c "import sys,json; d=json.load(sys.stdin); assert d['valid'] is True" <<<"$out" 'valid:true in json'

rm -rf "$BTMP"
t_summary