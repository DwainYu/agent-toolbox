#!/usr/bin/env bash
# =============================================================================
# common.sh — shared helpers for agent-toolbox scripts
#
# Provides:
#   * exit-code constants (0 ok, 1 updates, 2 config/validation)
#   * colored logging
#   * YAML -> JSON conversion with engine auto-detection
#     (prefers python3+PyYAML, falls back to yq, then ruby/psych)
#   * jq-backed JSON query helpers (yqjson / yqdata, supports --arg passthrough)
#   * flag parsing helpers (--dry-run, --apply, --json, --mock, --target)
#   * secret-pattern detection helper
#
# IMPORTANT: yaml_to_json converts YAML date objects to ISO strings so that jq
# and downstream JSON consumers never choke on `checked_at: 2026-10-02`.
# =============================================================================

set -euo pipefail

# Resolve the toolbox root (parent of scripts/).
ATB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ATB_ROOT

MANIFEST="$ATB_ROOT/manifest.yaml"
LOCK="$ATB_ROOT/lock.yaml"
CATALOG_DIR="$ATB_ROOT/catalog"
PROFILES_DIR="$ATB_ROOT/profiles"
SCRIPTS_DIR="$ATB_ROOT/scripts"

# ---- exit codes -------------------------------------------------------------
EXIT_OK=0
EXIT_UPDATES=1
EXIT_CONFIG=2

# ---- colors -----------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m';  C_RESET=$'\033[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log()  { printf '%s\n' "$*"; }
err()  { printf '%s\n' "${C_RED}ERROR:${C_RESET} $*" >&2; }
warn() { printf '%s\n' "${C_YELLOW}warn:${C_RESET} $*" >&2; }
info() { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
ok()   { printf '%s\n' "${C_GREEN}✓${C_RESET} $*"; }
die()  { err "$*"; exit "$EXIT_CONFIG"; }

die_if_not_file() { # die_if_not_file <path> <label>
  if [[ ! -f "$1" ]]; then
    die "missing required file: $2 ($1)"
  fi
}

# ---- YAML engine detection --------------------------------------------------
# Prints the name of a working YAML->JSON engine: "python" | "yq" | "ruby" | ""
_yaml_engine_check() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    echo python; return
  fi
  if command -v yq >/dev/null 2>&1; then
    echo yq; return
  fi
  if command -v ruby >/dev/null 2>&1 && ruby -ryaml -e 'YAML' >/dev/null 2>&1; then
    echo ruby; return
  fi
  echo ""
}

# Convert a YAML file to JSON on stdout. Dies with a clear message if no engine
# is available. The engine is cached (assumed stable within one script run).
YAML_ENGINE=""
yaml_to_json() { # yaml_to_json <yaml-file>
  local f="$1"
  die_if_not_file "$f" "YAML input"
  if [[ -z "$YAML_ENGINE" ]]; then
    YAML_ENGINE="$(_yaml_engine_check)"
  fi
  case "$YAML_ENGINE" in
    python) python3 -c '
import sys, json, yaml, datetime
def _default(o):
    if isinstance(o, (datetime.date, datetime.datetime)):
        return o.isoformat()
    return str(o)
with open(sys.argv[1], "r") as fh:
    data = yaml.safe_load(fh)
print(json.dumps(data, ensure_ascii=False, default=_default))
' "$f" ;;
    yq) yq -o=json "$f" ;;
    ruby) ruby -ryaml -rjson -e 'puts JSON.generate(YAML.load_file(ARGV[0]))' "$f" ;;
    *)
      die "No YAML engine found. Install PyYAML (pip install pyyaml), yq, or ruby." ;;
  esac
}

# Query a YAML file with jq. Extra args are forwarded verbatim to jq, so you
# can use --arg etc. The jq expression is the last argument.
#   yqjson <yaml-file> [jq flags...] <expr>   -> compact JSON on stdout
#   yqdata <yaml-file> [jq flags...] <expr>   -> raw (unquoted) scalar
yqjson() { # yqjson <yaml-file> [jq flags...] <expr>
  local f="$1"; shift
  yaml_to_json "$f" | jq -c "$@"
}
yqdata() { # yqdata <yaml-file> [jq flags...] <expr>
  local f="$1"; shift
  yaml_to_json "$f" | jq -r "$@"
}

# ---- flag parsing -----------------------------------------------------------
# Parses a fixed set of boolean/valued flags into globals.
# Positional args are kept in $ATB_POS.
ATB_DRY_RUN=0
ATB_APPLY=0
ATB_JSON=0
ATB_MOCK=0
ATB_TARGET=""
ATB_WRITE_LOCK=0
ATB_POS=()

parse_flags() {
  local a
  ATB_POS=()
  while (( $# )); do
    a="$1"
    case "$a" in
      --dry-run)    ATB_DRY_RUN=1 ;;
      --apply)      ATB_APPLY=1 ;;
      --json)       ATB_JSON=1 ;;
      --mock)       ATB_MOCK=1 ;;
      --write-lock) ATB_WRITE_LOCK=1 ;;
      --target)     ATB_TARGET="$2"; shift ;;
      --target=*)   ATB_TARGET="${a#--target=}" ;;
      *)            ATB_POS+=("$a") ;;
    esac
    shift
  done
}

# ---- misc -------------------------------------------------------------------
# True if a value looks like a secret (value form). Used by validate.sh.
is_potential_secret() { # is_potential_secret <string>
  local s="$1"
  [[ "$s" =~ (sk-[A-Za-z0-9_-]{16,}) ]] && return 0
  [[ "$s" =~ (ghp_[A-Za-z0-9]{20,}) ]] && return 0
  [[ "$s" =~ (AKIA[0-9A-Z]{16}) ]] && return 0
  [[ "$s" =~ (-----BEGIN[ A-Z]*PRIVATE KEY-----) ]] && return 0
  [[ "$s" =~ (eyJ[A-Za-z0-9_-]{20,}) ]] && return 0
  [[ "$s" =~ (github_pat_[A-Za-z0-9_]{20,}) ]] && return 0
  return 1
}

# Read manifest + lock as JSON (loaded once, cached).
MANIFEST_JSON=""
LOCK_JSON=""
manifest_json() { [[ -z "$MANIFEST_JSON" ]] && MANIFEST_JSON="$(yaml_to_json "$MANIFEST")"; printf '%s' "$MANIFEST_JSON"; }
lock_json()    { [[ -z "$LOCK_JSON" ]]    && LOCK_JSON="$(yaml_to_json "$LOCK")";    printf '%s' "$LOCK_JSON"; }
