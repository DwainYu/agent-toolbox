#!/usr/bin/env bash
# =============================================================================
# hermes_adapter_test.sh — hermes embedded-YAML MCP adapter
#   usage: bash tests/unit/hermes_adapter_test.sh <WORK> <FHOME>
#
# The adapter rewrites ONE block inside ~/.hermes/config.yaml, so every test
# here runs on its own throwaway $HOME (install --apply writes are real).
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

make_cli "$S" bsk 0.3.0
make_cli "$S" ocr 1.12.12
make_cli "$S" codegraph 1.6.2
export PATH="$S:$PATH"

mkdir -p "$H/.agents/skills" "$H/.hermes"
CFG="$H/.hermes/config.yaml"
export CFG

install_cap() {  # install_cap <capability> [--apply]
  (cd "$W" && bash bin/agent-toolbox install "$1" --harness hermes ${2+"$2"})
}

assert_rc_nonzero() { # assert_rc_nonzero <rc> <msg>
  [[ "$1" != "0" ]] && t_pass "$2" || t_fail "$2 (rc was 0)"
}

py_check() {  # py_check <label> — python program (assert-based) on stdin
  if python3 - >/dev/null 2>&1; then t_pass "$1"; else t_fail "$1 (python check failed)"; fi
}

reset_cfg() {  # fixture: user keys + comments + one custom server + trailing keys
  rm -f "$H"/.hermes/config.yaml.atb-backup.*
  cat > "$CFG" <<'EOF'
# Hermes user config — comments must survive
model: user-model
providers:
  agnes:
    enabled: true
permissions:
  foo: bar
mcp_servers:
  my-custom:
    command: my-custom-bin
    args: ["--stdio"]
    enabled: true
telemetry:
  shared_metrics:
    enabled: false
EOF
}

# prepend a codegraph definition with arbitrary text before the custom server
inject_server() {  # inject_server <yaml-lines>
  CFG="$CFG" PY="$1" python3 - <<'PY'
import os
p = os.environ["CFG"]
s = open(p).read().replace("  my-custom:", os.environ["PY"] + "  my-custom:", 1)
open(p, "w").write(s)
PY
}

bak_count() { find "$H/.hermes" -maxdepth 1 -name "config.yaml.atb-backup.*" | wc -l; }

# ---------------------------------------------------------------------------
t_begin "hermes dry-run writes nothing"
reset_cfg
before="$(cat "$CFG")"
out="$(install_cap code-intelligence)"; rc=$?
assert_eq "$rc" "0" 'dry-run exits 0'
assert_contains "$out" "mcp-mirror" 'plan shows the mirror action'
assert_eq "$(cat "$CFG")" "$before" 'dry-run left config.yaml untouched'
assert_eq "$(bak_count)" "0" 'dry-run created no backup'

# ---------------------------------------------------------------------------
t_begin "hermes apply: add-only merge, user config untouched"
reset_cfg
out="$(install_cap code-intelligence --apply)"; rc=$?
assert_eq "$rc" "0" 'first apply exits 0'
assert_contains "$out" "merged codegraph" 'codegraph merged'
py_check 'user keys + custom server + comments preserved' <<'PY'
import os, yaml
after = yaml.safe_load(open(os.environ["CFG"]))
assert after["model"] == "user-model", "model"
assert after["providers"] == {"agnes": {"enabled": True}}, "providers"
assert after["permissions"] == {"foo": "bar"}, "permissions"
assert after["telemetry"] == {"shared_metrics": {"enabled": False}}, "telemetry"
assert after["mcp_servers"]["my-custom"] == {
    "command": "my-custom-bin", "args": ["--stdio"], "enabled": True}, "custom server"
assert "codegraph" in after["mcp_servers"], "codegraph added"
raw = open(os.environ["CFG"]).read()
assert "#" in raw, "comments survive"
assert raw.index("mcp_servers:") < raw.index("telemetry:"), "block order kept"
PY
assert_eq "$(bak_count)" "1" 'exactly one backup after a real change'

# ---------------------------------------------------------------------------
t_begin "hermes apply is idempotent"
out="$(install_cap code-intelligence --apply)"; rc=$?
assert_eq "$rc" "0" 'second apply exits 0'
assert_contains "$out" "Already in sync" 'second apply reports no-op'
assert_eq "$(bak_count)" "1" 'no new backup on no-op'

# ---------------------------------------------------------------------------
t_begin "hermes mirrors all four shared servers"
for c in exa context7 searchcode; do
  out="$(install_cap $c --apply)"; rc=$?
  assert_eq "$rc" "0" "$c apply exits 0"
done
py_check 'four servers mirrored in hermes-native shape' <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["CFG"]))
want = {"codegraph", "exa", "context7", "searchcode", "my-custom"}
assert set(d["mcp_servers"]) == want, sorted(d["mcp_servers"])
cg = d["mcp_servers"]["codegraph"]
assert cg == {"command": "codegraph", "args": ["serve", "--mcp"], "enabled": True}, cg
ex = d["mcp_servers"]["exa"]
assert ex == {"url": "https://mcp.exa.ai/mcp", "enabled": True}, ex
PY

# ---------------------------------------------------------------------------
t_begin "hermes drift refuses to overwrite"
reset_cfg
inject_server '  codegraph:
    command: someone-elses-codegraph
    args: ["weird"]
    enabled: true
'
out="$(install_cap code-intelligence --apply)"; rc=$?
assert_rc_nonzero "$rc" 'drift is refused (exit != 0)'
assert_contains "$out" "drift" 'drift is named'
assert_contains "$(cat "$CFG")" "someone-elses-codegraph" 'user definition kept'
assert_eq "$(bak_count)" "0" 'refused write leaves no backup'

# ---------------------------------------------------------------------------
t_begin "hermes equivalent definition counts as in-sync"
reset_cfg
inject_server '  codegraph:
    command: codegraph
    args: [serve, --mcp]
    enabled: true
    timeout: 60
'
out="$(install_cap code-intelligence --apply)"; rc=$?
assert_eq "$rc" "0" 'equivalent-with-extra-keys exits 0'
assert_contains "$out" "Already in sync" 'launch-identical is a no-op'
assert_contains "$(cat "$CFG")" "timeout: 60" 'extra user keys kept'

# ---------------------------------------------------------------------------
t_begin "hermes missing mcp_servers block gets one appended"
printf 'model: user-model\npermissions:\n  foo: bar\n' > "$CFG"
out="$(install_cap exa --apply)"; rc=$?
assert_eq "$rc" "0" 'apply with no mcp_servers exits 0'
py_check 'block created at EOF, user keys intact' <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["CFG"]))
assert d["model"] == "user-model" and d["permissions"] == {"foo": "bar"}
assert "exa" in d["mcp_servers"], sorted(d)
PY

# ---------------------------------------------------------------------------
t_begin "hermes empty mcp_servers block is filled"
printf 'model: user-model\nmcp_servers:\ntelemetry:\n  x: 1\n' > "$CFG"
out="$(install_cap context7 --apply)"; rc=$?
assert_eq "$rc" "0" 'apply into empty block exits 0'
py_check 'server inserted inside the empty block' <<'PY'
import os, yaml
d = yaml.safe_load(open(os.environ["CFG"]))
assert "context7" in d["mcp_servers"], d.get("mcp_servers")
assert d["telemetry"] == {"x": 1}, "next top-level key not swallowed"
PY

# ---------------------------------------------------------------------------
t_begin "hermes invalid YAML: error, no write, no backup"
reset_cfg
printf '\tbroken: yes\n' >> "$CFG"
before="$(cat "$CFG")"
out="$(install_cap code-intelligence --apply)"; rc=$?
assert_eq "$rc" "2" 'invalid YAML is refused (exit 2 = config error)'
assert_eq "$(cat "$CFG")" "$before" 'invalid YAML left file untouched'
assert_eq "$(bak_count)" "0" 'invalid YAML created no backup'

# ---------------------------------------------------------------------------
t_begin "hermes duplicate server keys are refused"
reset_cfg
inject_server '  codegraph:
    command: a
  codegraph:
    command: b
'
out="$(install_cap code-intelligence --apply)"; rc=$?
assert_eq "$rc" "2" 'duplicate keys are refused (exit 2 = config error)'
assert_contains "$out" "duplicate" 'duplicate is named'
assert_eq "$(bak_count)" "0" 'duplicate refusal leaves no backup'

# ---------------------------------------------------------------------------
t_begin "hermes adapter never writes back the shared source"
reset_cfg
shared_src="$W/profiles/shared/mcp.json"
before="$(cat "$shared_src")"
install_cap code-intelligence --apply >/dev/null
install_cap searchcode --apply >/dev/null
assert_eq "$(cat "$shared_src")" "$before" 'shared definition file byte-identical'

t_summary
