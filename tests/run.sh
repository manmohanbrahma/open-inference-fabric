#!/bin/bash
# Run every check that needs no root and no cluster: shellcheck and the unit tests in tests/unit.
#   tests/run.sh            all checks
#   tests/run.sh unit       unit tests only
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
fail=0

if [ "${1:-}" != unit ]; then
  if command -v shellcheck >/dev/null; then
    echo "== shellcheck"
    shellcheck -x -S warning oif installer/lib/*.sh installer/stages/*.sh tests/*.sh tests/unit/*.sh && echo "   ok" || fail=1
  else
    echo "== shellcheck not installed: skipped (CI runs it)"
  fi
fi

echo "== python syntax"
python3 -m py_compile installer/tools/*.py && echo "   ok" || fail=1

echo "== unit tests"
for t in tests/unit/test_*.sh; do
  if bash "$t"; then echo "   ok   $t"; else echo "   FAIL $t"; fail=1; fi
done

[ $fail = 0 ] && echo "all checks passed" || echo "CHECKS FAILED"
exit $fail
