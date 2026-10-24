#!/bin/bash
# oif:* recording rules: promtool checks the rule file and runs its unit tests (platform/observability/rules/).
# promtool comes from the pinned Prometheus release (versions.env), cached in tests/.cache; skipped when offline.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

cache=$ROOT/tests/.cache; tool=$cache/promtool-$PROMETHEUS_VERSION
if [ ! -x "$tool" ]; then
  mkdir -p "$cache"; tgz=$cache/prometheus-$PROMETHEUS_VERSION.tgz
  if ! wget -q -O "$tgz" "https://github.com/prometheus/prometheus/releases/download/v$PROMETHEUS_VERSION/prometheus-$PROMETHEUS_VERSION.linux-amd64.tar.gz"; then
    rm -f "$tgz"; echo "   (promtool download failed: rule tests skipped)"; finish; exit
  fi
  [ "$(sha256sum "$tgz" | cut -d' ' -f1)" = "$PROMETHEUS_SHA256" ] || { rm -f "$tgz"; fail "prometheus $PROMETHEUS_VERSION checksum mismatch"; finish; exit; }
  tar -xzf "$tgz" -C "$cache" --strip-components=1 "prometheus-$PROMETHEUS_VERSION.linux-amd64/promtool" && mv "$cache/promtool" "$tool"; rm -f "$tgz"
fi

out=$("$tool" check rules "$ROOT/platform/observability/rules/oif-gpu.rules.yaml" 2>&1) || fail "promtool check rules: $out"
out=$(cd "$ROOT/platform/observability/rules" && "$tool" test rules oif-gpu.test.yaml 2>&1) || fail "promtool test rules: $out"
finish
