#!/bin/bash
# The oif command line: help, version, usage errors, root check.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF=$ROOT/oif

out=$(bash "$OIF" help); eq "$?" 0 "help exit code:"
echo "$out" | grep -q "oif install" || fail "help lists install"
eq "$(bash "$OIF" version)" "oif $OIF_VERSION" "version:"
bash "$OIF" frobnicate >/dev/null 2>&1; eq "$?" 2 "unknown command exit code:"
bash "$OIF" check --env >/dev/null 2>&1; eq "$?" 2 "--env without a file:"
if [ "$(id -u)" != 0 ]; then
  out=$(bash "$OIF" status 2>&1); eq "$?" 2 "non-root exit code:"
  echo "$out" | grep -q "run with sudo" || fail "non-root message"
fi
finish
