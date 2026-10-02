#!/usr/bin/env bash
# =============================================================================
# run-tests.sh — run all agent-toolbox tests against an isolated copy
#
#   bash tests/run-tests.sh [--keep]        # --keep: leave the work copy
#
# Tests never touch the real checkout. A pristine copy is made in a temp dir
# and a fake $HOME is used, so install.sh --apply and check-updates.sh --apply
# exercises run against throwaway data.
#
# Exit codes: 0 all green, 1 any test failed.
# =============================================================================
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
KEEP=0
for a in "$@"; do [[ "$a" == "--keep" ]] && KEEP=1; done
[[ "$KEEP" == "1" ]] || trap 'rm -rf "$TMP"' EXIT

WORK="$TMP/work"
FHOME="$TMP/home"
mkdir -p "$FHOME" "$WORK"

echo "work copy : $WORK"
echo "fake HOME : $FHOME"
echo ""

cp -a "$SRC/." "$WORK/"
rm -rf "$WORK/.git"

status=0
 for t in "$WORK"/tests/unit/*_test.sh "$WORK"/tests/integration/*_test.sh; do
   [ -f "$t" ] || continue
   echo "== ${t#$WORK/tests/}"
   if bash "$t" "$WORK" "$FHOME" 2>&1; then
     :
   else
     status=1
   fi
   echo ""
 done

echo "=============================="
if [[ "$status" == "0" ]]; then
  echo "ALL TESTS PASSED"
else
  echo "SOME TESTS FAILED"
fi
[[ "$KEEP" == "1" ]] && echo "work copy kept at $WORK"
exit "$status"