#!/bin/bash
# Templates: ${NAME} placeholders replaced, other dollar signs untouched, a missing value is an error;
# every template under platform/ renders with sample values and leaves no placeholder behind.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

printf 'a: ${ONE}\n# cost: $5, ${not a var}, $HOME\nb: "${TWO}"\n' > "$SANDBOX/t.yaml"
eq "$(ONE=1 TWO=x render "$SANDBOX/t.yaml")" "$(printf 'a: 1\n# cost: $5, ${not a var}, $HOME\nb: "x"')" "render:"
no_ env ONE=1 render "$SANDBOX/t.yaml"            # TWO missing
no_ env ONE=1 TWO= render "$SANDBOX/t.yaml"       # empty counts as missing

export HOST_IP=192.0.2.10 POD_CIDR=10.244.0.0/16 SERVICE_CIDR=172.30.0.0/16 KUBERNETES_VERSION KUBELET_MAX_PODS \
  METALLB_RANGE=192.0.2.240-192.0.2.244 SMOKE_IMAGE=$BUSYBOX_IMAGE CUDA_SAMPLE_IMAGE INGRESS_IP=192.0.2.240 \
  RUNAI_VERSION RUNAI_CLUSTER_NAME=oif RUNAI_DOMAIN=runai.example.com RUNAI_TLS_CERT=/p/tls.crt RUNAI_TLS_KEY=/p/tls.key \
  RUNAI_CA_CERT=/p/ca.crt NS=runai-team-a BUSYBOX_IMAGE AMD_UTILS_IMAGE AMD_DEVICE_PLUGIN_IMAGE AMD_NODE_LABELLER_IMAGE \
  AMD_METRICS_EXPORTER_IMAGE AMD_ECC_UMC_THRESHOLD=4000000000
for t in "$ROOT"/platform/*/*.yaml; do
  out=$(render "$t") || { fail "render $t"; continue; }
  grep -qE '\$\{[A-Z_]+\}' <<< "$out" && fail "placeholder left in $t"
  [ -n "$out" ] || fail "empty output for $t"
done
finish
