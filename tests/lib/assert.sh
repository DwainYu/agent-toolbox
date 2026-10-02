#!/usr/bin/env bash
# =============================================================================
# assert.sh — tiny test helpers shared by all ATB tests
# =============================================================================
set -uo pipefail

declare -i ATB_T_PASS=0 ATB_T_FAIL=0 ATB_T_SKIP=0
ATB_T_CASE=""

t_begin() { ATB_T_CASE="$1"; }
t_pass()  { ATB_T_PASS+=1; echo "  ok  - ${ATB_T_CASE}: $1"; }
t_fail()  { ATB_T_FAIL+=1; echo "  FAIL - ${ATB_T_CASE}: $1" >&2; }
t_skip()  { ATB_T_SKIP+=1; echo "  skip- ${ATB_T_CASE}: $1"; }

assert_eq() { # assert_eq <got> <want> <msg>
  [[ "$1" == "$2" ]] && t_pass "$3" || t_fail "$3 (got '$1', want '$2')"
}

assert_contains() { # assert_contains <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) t_pass "$3" ;;
    *)      t_fail "$3 (missing '$2' in output)" ;;
  esac
}

assert_not_contains() { # assert_not_contains <haystack> <needle> <msg>
  case "$1" in
    *"$2"*) t_fail "$3 (unexpected '$2' in output)" ;;
    *)      t_pass "$3" ;;
  esac
}

assert_true() { # assert_true <cmd...>
  if "$@" >/dev/null 2>&1; then t_pass "$*"; else t_fail "$* (exit != 0)"; fi
}

assert_false() { # assert_false <cmd...>
  if "$@" >/dev/null 2>&1; then t_fail "$* (expected non-zero exit)"; else t_pass "$*"; fi
}

assert_exists() { # assert_exists <path> <msg>
  [[ -e "$1" ]] && t_pass "$2" || t_fail "$2 ($1 not found)"
}

assert_not_exists() { # assert_not_exists <path> <msg>
  [[ ! -e "$1" ]] && t_pass "$2" || t_fail "$2 ($1 should not exist)"
}

t_summary() {
  echo ""
  echo "Tests: $ATB_T_PASS passed, $ATB_T_FAIL failed, $ATB_T_SKIP skipped"
  [[ $ATB_T_FAIL -gt 0 ]] && return 1 || return 0
}