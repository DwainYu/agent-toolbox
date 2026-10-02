#!/usr/bin/env bash
# =============================================================================
# common_test.sh — unit tests for scripts/lib/common.sh
#   usage: bash tests/unit/common_test.sh <WORK> <FHOME>
# =============================================================================
set -uo pipefail
WORK="${1:?WORK}"; FHOME="${2:?FHOME}"
source "$WORK/tests/lib/assert.sh"
source "$WORK/scripts/lib/common.sh"

t_begin "yaml engine"
command -v python3 >/dev/null 2>&1 || { t_skip "no python3"; t_summary; exit 0; }
assert_true _yaml_engine_check 'python'

t_begin "yaml_to_json produces parseable JSON + date strings"
out="$(yaml_to_json "$WORK/manifest.yaml")"
assert_true python3 -c "import sys,json; d=json.load(sys.stdin); assert isinstance(d,dict)" <<<"$out" 'manifest parses'
f="$WORK/.tmp-date.yaml"; printf 'a: 2026-10-02\n' > "$f"
outd="$(yaml_to_json "$f")"
assert_true python3 -c "import sys,json; d=json.load(sys.stdin); assert d['a']=='2026-10-02'" <<<"$outd" 'date -> ISO string'
rm -f "$f"

t_begin "yqjson / yqdata"
v="$(yqdata "$WORK/manifest.yaml" '.schema_version')"
assert_eq "$v" "1" 'schema_version is 1'
ids="$(yqjson "$WORK/manifest.yaml" '[.resources.skills[].id] | length')"
assert_eq "$ids" "5" '5 skills declared'
names="$(yqdata "$WORK/manifest.yaml" '[.resources.packages[].scope] | unique | join(",")')"
assert_eq "$names" "global" 'packages are global'

t_begin "is_potential_secret"
assert_true is_potential_secret 'sk-abcdefghijklmnopqrstuvwxyz'
assert_true is_potential_secret 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij'
assert_true is_potential_secret 'AKIAABCDEFGHIJKLMNOP'
assert_true is_potential_secret '-----BEGIN RSA PRIVATE KEY-----'
assert_false is_potential_secret 'just-a-normal-string'

t_begin "parse_flags"
ATB_APPLY=0; ATB_JSON=0; ATB_TARGET=""
parse_flags global --apply --json --target /tmp/x
assert_eq "${ATB_POS[0]}" "global" 'positional preserved'
assert_eq "$ATB_APPLY" "1" '--apply set'
assert_eq "$ATB_JSON" "1" '--json set'
assert_eq "$ATB_TARGET" "/tmp/x" '--target set'
parse_flags project foo --target=/y
assert_eq "$ATB_TARGET" "/y" '--target= form'

t_begin "exit codes"
assert_eq "$EXIT_OK" "0" 'EXIT_OK'
assert_eq "$EXIT_UPDATES" "1" 'EXIT_UPDATES'
assert_eq "$EXIT_CONFIG" "2" 'EXIT_CONFIG'

t_summary