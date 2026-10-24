#!/bin/bash
# Run:ai prerequisites that need no cluster: the default domain, and the CA and certificate the pki stage makes.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
OIF_HOME=$ROOT
for f in "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done

METALLB_RANGE=192.0.2.240-192.0.2.244; RUNAI_DOMAIN=""
eq "$(runai_domain)" runai.192-0-2-240.sslip.io "default domain from the first MetalLB address:"
RUNAI_DOMAIN=runai.example.com; eq "$(runai_domain)" runai.example.com "a set domain wins:"
ok_ v_domain runai.example.com; ok_ v_domain ""; no_ v_domain "not a domain"; no_ v_domain runai.example.com.

command -v openssl >/dev/null || { echo "      (openssl missing: certificate test skipped)"; finish; }
PKI=$SANDBOX/pki; UHOME=$SANDBOX/home; mkdir -p "$UHOME"; INSTALL_USER=$(id -un); RUNAI_DOMAIN=""
save() { :; }; install() { command install "${@/-o/-g}" 2>/dev/null || command cp "${@: -2}"; }   # no chown as non-root
stage_pki >/dev/null
d=runai.192-0-2-240.sslip.io
ok_ openssl verify -CAfile "$PKI/ca.crt" "$PKI/tls.crt"
san=$(openssl x509 -in "$PKI/tls.crt" -noout -ext subjectAltName)
for n in "$d" "*.$d" "*.inference.$d"; do grep -qF "DNS:$n" <<< "$san" || fail "SAN $n missing: $san"; done
openssl x509 -in "$PKI/ca.crt" -noout -ext basicConstraints | grep -q 'CA:TRUE' || fail "CA certificate is a CA"
eq "$(stat -c %a "$PKI/ca.key")" 600 "CA key mode:"
eq "$(stat -c %a "$PKI")" 700 "pki folder mode:"
[ -s "$UHOME/oif-ca.crt" ] || fail "CA copied for the user"
grep -q PRIVATE "$UHOME/oif-ca.crt" && fail "no private key in the user's copy"
before=$(openssl x509 -in "$PKI/ca.crt" -noout -fingerprint)
stage_pki >/dev/null
eq "$(openssl x509 -in "$PKI/ca.crt" -noout -fingerprint)" "$before" "the CA survives a re-run (browsers keep trusting it):"
finish
