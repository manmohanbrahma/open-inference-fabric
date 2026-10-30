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

# Run:ai placement (ADR-021): nothing on a single node; on several, required system-node affinity and platform storage
host_prefix() { [ "$1" = 192.0.2.11 ] && echo 192.0.2.11/24; }
OIF_NODES=""; runai_placement
eq "$RUNAI_SYSTEM_NODES" '{"enabled": false}' "single node, system nodes:"; eq "$RUNAI_CP_VALUES" '{}' "single node, values:"; eq "$RUNAI_CLUSTER_VALUES" '{}' "single node, cluster values:"
OIF_NODES="cp1=192.0.2.11:control cp2=192.0.2.12:control cp3=192.0.2.13:control gpu=192.0.2.21:worker"; runai_placement
eq "$(python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print(d["enabled"], d["mode"], d["label"], d["manageLabels"], d["selector"])' "$RUNAI_SYSTEM_NODES")" \
  "True required node-role.kubernetes.io/runai-system False {'node-role.kubernetes.io/runai-system': 'true'}" "system nodes:"
eq "$(python3 -c 'import json, sys; d = json.loads(sys.argv[1])
print(len(d), d["postgresql.primary.persistence.storageClass"], d["thanos.receive.affinity.nodeAffinity.requiredDuringSchedulingIgnoredDuringExecution.nodeSelectorTerms[0].matchExpressions[0].operator"],
      "key: node-role.kubernetes.io/runai-system" in d["keycloakx.affinity"], any("," in v for v in d.values()))' "$RUNAI_CP_VALUES")" \
  "12 longhorn Exists True False" "control-plane values (no commas: they are helm --set values):"
OIF_NODES="cp1=192.0.2.11:control gpu=192.0.2.21:worker"; runai_placement
eq "$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["nats.persistence.storageClass"])' "$RUNAI_CP_VALUES")" local-path "one control-plane node, storage:"
# the rendered installer config keeps both as one line each
export RUNAI_VERSION RUNAI_CLUSTER_NAME=oif RUNAI_DOMAIN=runai.example.com RUNAI_TLS_CERT=/p/t RUNAI_TLS_KEY=/p/k RUNAI_CA_CERT=/p/c
cfg=$(render "$ROOT/platform/runai/config.yaml")
grep -qxF "  customHelmValues: $RUNAI_CP_VALUES" <<< "$cfg" || fail "customHelmValues not under controlPlane"
grep -qxF "systemNodes: $RUNAI_SYSTEM_NODES" <<< "$cfg" || fail "systemNodes not at the top level"
grep -qxF "  customHelmValues: $RUNAI_CLUSTER_VALUES" <<< "$cfg" || fail "cluster customHelmValues missing"
eq "$(python3 -c 'import json, sys; print(sorted(k.split(".affinity")[0] for k in json.loads(sys.argv[1]) if k.endswith(".key")))' "$RUNAI_CLUSTER_VALUES")" \
  "['kai-resource-management.kai-scheduler.gpu-fractioning', 'karta']" "cluster subcharts pinned:"
if python3 -c 'import yaml' 2>/dev/null; then   # where PyYAML is installed (Ubuntu hosts): the installer reads the same
  eq "$(python3 -c 'import sys, yaml; c = yaml.safe_load(sys.stdin); print(c["systemNodes"]["enabled"], len(c["controlPlane"]["customHelmValues"]), len(c["cluster"]["customHelmValues"]), c["controlPlane"]["domain"])' <<< "$cfg")" \
    "True 12 4 runai.example.com" "config.yaml parsed as YAML:"
fi
OIF_NODES=""

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
