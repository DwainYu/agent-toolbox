#!/usr/bin/env bash
# =============================================================================
# stubs.sh — fake CLIs / official installers for capability tests
#
# The toolbox must DELEGATE to official installers, so tests replace those
# binaries with stubs on PATH and assert that the right command was invoked.
# Stubs never download anything: they log their argv and, like a real
# installer would, wire the adapter (shared source + symlink into the harness
# skill dir) — one shared source, never a second copy.
#
# All stubs keep their state under $HOME/.stubver/ so a fake $HOME keeps the
# whole test hermetic.
# =============================================================================
set -uo pipefail

# harness_skill_dir <installer-agent-id>
# Same mapping the manifest declares as `harnesses.<id>.installer_ids`.
harness_skill_dir() {
  case "$1" in
    Pi|pi)          echo "$HOME/.pi/agent/skills" ;;
    CodeBuddy|codebuddy) echo "$HOME/.codebuddy/skills" ;;
    qoder-cn)       echo "$HOME/.qoder-cn/skills" ;;
    opencode)       echo "$HOME/.config/opencode/skills" ;;
    *)              echo "$HOME/.stubver/skills.d/$1" ;;
  esac
}

# make_cli <bindir> <name> <version>
# A CLI that answers `--version` and logs every call to $HOME/.stubver/<name>.calls
make_cli() {
  local dir="$1" name="$2" ver="$3"
  mkdir -p "$dir"
  cat > "$dir/$name" <<EOF
#!/usr/bin/env bash
d="\$HOME/.stubver"
mkdir -p "\$d"
[ -f "\$d/$name" ] || printf '%s\n' "$ver" > "\$d/$name"
printf '%s\n' "$name \$*" >> "\$d/$name.calls"
case "\${1:-}" in
  --version|version) printf '%s %s\n' "$name" "\$(cat "\$d/$name")"; exit 0 ;;
esac
exit 0
EOF
  chmod +x "$dir/$name"
}

# make_bsk <bindir> [version] — BrowserSkill's official installer
make_bsk() {
  local dir="$1" ver="${2:-0.3.0}"
  mkdir -p "$dir"
  cat > "$dir/bsk" <<EOF
#!/usr/bin/env bash
d="\$HOME/.stubver"
mkdir -p "\$d"
[ -f "\$d/bsk" ] || printf '%s\n' "$ver" > "\$d/bsk"
printf '%s\n' "bsk \$*" >> "\$d/bsk.calls"
sdir_for() {
  case "\$1" in
    Pi|pi) echo "\$HOME/.pi/agent/skills" ;;
    CodeBuddy|codebuddy) echo "\$HOME/.codebuddy/skills" ;;
    qoder-cn) echo "\$HOME/.qoder-cn/skills" ;;
    opencode) echo "\$HOME/.config/opencode/skills" ;;
    *) echo "\$HOME/.stubver/skills.d/\$1" ;;
  esac
}
case "\${1:-}" in
  --version|version) printf 'bsk %s\n' "\$(cat "\$d/bsk")"; exit 0 ;;
  install-skill)
    h=""; prev=""
    for a in "\$@"; do [ "\$prev" = "--harness" ] && h="\$a"; prev="\$a"; done
    [ -n "\$h" ] || { echo "install-skill: --harness required" >&2; exit 2; }
    mkdir -p "\$HOME/.agents/skills/browser-skill"
    [ -f "\$HOME/.agents/skills/browser-skill/SKILL.md" ] ||
      printf '%s\n' "# browser-skill (shared source)" > "\$HOME/.agents/skills/browser-skill/SKILL.md"
    sdir="\$(sdir_for "\$h")"
    mkdir -p "\$sdir"
    ln -sfn "\$HOME/.agents/skills/browser-skill" "\$sdir/browser-skill"
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$dir/bsk"
}

# make_npx <bindir> — `npx skills add <repo> ... --agent <id>` (code-review skills)
make_npx() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/npx" <<'EOF'
#!/usr/bin/env bash
d="$HOME/.stubver"
mkdir -p "$d"
printf '%s\n' "npx $*" >> "$d/npx.calls"
sdir_for() {
  case "$1" in
    Pi|pi) echo "$HOME/.pi/agent/skills" ;;
    CodeBuddy|codebuddy) echo "$HOME/.codebuddy/skills" ;;
    qoder-cn) echo "$HOME/.qoder-cn/skills" ;;
    opencode) echo "$HOME/.config/opencode/skills" ;;
    *) echo "$HOME/.stubver/skills.d/$1" ;;
  esac
}
case "${1:-} ${2:-}" in
  "skills add")
    agent=""; prev=""
    for a in "$@"; do [ "$prev" = "--agent" ] && agent="$a"; prev="$a"; done
    [ -n "$agent" ] || { echo "skills add: --agent required" >&2; exit 2; }
    sdir="$(sdir_for "$agent")"
    mkdir -p "$sdir"
    for s in open-code-review open-code-review-delegate; do
      mkdir -p "$HOME/.agents/skills/$s"
      [ -f "$HOME/.agents/skills/$s/SKILL.md" ] ||
        printf '%s\n' "# $s (shared source)" > "$HOME/.agents/skills/$s/SKILL.md"
      ln -sfn "$HOME/.agents/skills/$s" "$sdir/$s"
    done
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$dir/npx"
}

# make_npm <bindir> — the npm the capability updaters shell out to
make_npm() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/npm" <<'EOF'
#!/usr/bin/env bash
d="$HOME/.stubver"
mkdir -p "$d"
printf '%s\n' "npm $*" >> "$d/npm.calls"
if [ "${1:-}" = "install" ] && [ "${2:-}" = "-g" ]; then
  case "${3:-}" in
    '@alibaba-group/open-code-review') printf '%s\n' "1.13.0" > "$d/ocr" ;;
    '@colbymchenry/codegraph')         printf '%s\n' "1.7.0" > "$d/codegraph" ;;
    *) printf '%s\n' "0.0.0" > "$d/${3##*/}" ;;
  esac
  exit 0
fi
if [ "${1:-}" = "view" ]; then
  # never used with --mock, but keep it honest for non-mock runs
  echo "0.0.0"; exit 0
fi
exit 0
EOF
  chmod +x "$dir/npm"
}

# make_codegraph <bindir> [version] — CodeGraph CLI; `upgrade` bumps the version
make_codegraph() {
  local dir="$1" ver="${2:-1.6.0}"
  mkdir -p "$dir"
  cat > "$dir/codegraph" <<EOF
#!/usr/bin/env bash
d="\$HOME/.stubver"
mkdir -p "\$d"
[ -f "\$d/codegraph" ] || printf '%s\n' "$ver" > "\$d/codegraph"
printf '%s\n' "codegraph \$*" >> "\$d/codegraph.calls"
case "\${1:-}" in
  --version|version) printf 'codegraph %s\n' "\$(cat "\$d/codegraph")"; exit 0 ;;
  upgrade) printf '%s\n' "1.7.0" > "\$d/codegraph"; exit 0 ;;
  status)
    if [ -f "\$d/reindex-recommended" ]; then
      printf '%s\n' '{"index":{"state":"stale","reindexRecommended":true}}'
    else
      printf '%s\n' '{"index":{"state":"ok","reindexRecommended":false}}'
    fi
    exit 0 ;;
esac
exit 0
EOF
  chmod +x "$dir/codegraph"
}
