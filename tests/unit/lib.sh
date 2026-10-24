# shellcheck shell=bash
# Test helpers: a throw-away state folder and sandbox, the oif libraries loaded, small assertions.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SANDBOX=$(mktemp -d); trap 'rm -rf "$SANDBOX"' EXIT
export OIF_STATE=$SANDBOX/state
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
for f in "$ROOT"/installer/lib/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
INTERACTIVE=0; TLOG=/dev/null; LOG=$SANDBOX/test.log
state_init

FAILS=0
pass() { :; }
fail() { echo "      FAIL: $*"; FAILS=$((FAILS + 1)); }
eq() { [ "$1" = "$2" ] && pass || fail "${3:-} expected '$2', got '$1'"; }
ok_() { "$@" >/dev/null 2>&1 && pass || fail "expected success: $*"; }
no_() { "$@" >/dev/null 2>&1 && fail "expected failure: $*" || pass; }
finish() { [ "$FAILS" = 0 ]; exit $?; }
