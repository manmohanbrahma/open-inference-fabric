#!/bin/bash
# Acceptance test for T-123, run on the first node after a full  sudo ./oif install  on several nodes.
# Creates and deletes test pods in project team-c's namespace; otherwise read-only.
#   sudo tests/lab/t123-runai.sh
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); OIF_HOME=$ROOT; SELF=$ROOT/oif
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
for f in "$ROOT"/installer/lib/*.sh "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
INTERACTIVE=0; TLOG=/dev/null
config_load_saved
multi_node || { echo "T-123 needs a multi-node install (OIF_NODES)"; exit 2; }

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
phase() { kc -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
node_of() { kc -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }
running() { [ "$(phase "$1")" = Running ]; }

echo "T-123 Run:ai on several nodes: node pools per vendor"
INV=$(gpu_inventory)
while read -r name addr kind _; do
  host=$(on_gpu_node "$addr" hostname)
  eval "HOST_$kind=$host"
  check "$name ($host) labelled $VENDOR_LABEL=$kind" bash -c "[ \"\$(kubectl --kubeconfig $KCFG get node $host -o jsonpath='{.metadata.labels.oif\\.ai/gpu-vendor}')\" = $kind ]"
done <<< "$INV"
check "nodes without GPUs carry no vendor label" bash -c "[ \"\$(kubectl --kubeconfig $KCFG get nodes -l '$VENDOR_LABEL' --no-headers | wc -l)\" = $(wc -l <<< "$INV") ]"

POOLS=$(runai_api pools); sed 's/^/        /' <<< "$POOLS"
for v in nvidia amd; do
  n=$(gpu_count "$v")
  check "Run:ai node pool $v Ready with $n GPU(s)" grep -qE "^$v phase=Ready .* gpus $n\$" <<< "$POOLS"
done

for c in cluster-sync go-operator frontend; do
  img=$RUNAI_PATCH_REGISTRY/$c:$RUNAI_VERSION-oif1
  check "patched $c image on this node" runai_image_loaded "$img"
  while read -r -u 3 name addr role; do
    check "patched $c image on $name" node_ssh "$addr" "sudo ctr -n k8s.io images ls -q | grep -xF '$img' >/dev/null"
  done 3< <(other_nodes)
done
check "Run:ai cluster-sync runs the patched image" bash -c "kubectl --kubeconfig $KCFG -n runai get deploy cluster-sync -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q '^$RUNAI_PATCH_REGISTRY/'"
check "Run:ai operator runs the patched image" bash -c "kubectl --kubeconfig $KCFG -n runai get deploy runai-operator -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -q '^$RUNAI_PATCH_REGISTRY/'"
check "no Run:ai pod waiting for an image (runai, runai-backend)" bash -c "! kubectl --kubeconfig $KCFG get pods -A --no-headers | awk '\$1 == \"runai\" || \$1 == \"runai-backend\"' | grep -E 'ImagePull|ErrImage' >/dev/null"

# placement and quota in project team-c (quota 1 GPU in pool nvidia, 1 in pool amd)
NS=$(runai_api project-pools team-c nvidia=1 amd=1)
export CUDA_SAMPLE_IMAGE BUSYBOX_IMAGE NS
kc -n "$NS" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test wrong-pool --ignore-not-found --wait=true >/dev/null 2>&1
NODE_POOL=nvidia render "$OIF_HOME/platform/runai/quota-test.yaml" | kc apply -f - >/dev/null
NODE_POOL=amd render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >/dev/null
wait_for "both test pods running" 300 5 bash -c "$(declare -p NS KCFG); [ \"\$(kubectl --kubeconfig \$KCFG -n \$NS get pod gpu-quota-test amd-quota-test -o jsonpath='{.items[*].status.phase}')\" = 'Running Running' ]" >/dev/null 2>&1
check "pod in pool nvidia runs on the NVIDIA node (${HOST_nvidia:-?})" bash -c "[ '$(node_of gpu-quota-test)' = '${HOST_nvidia:-}' ]"
check "pod in pool amd runs on the AMD node (${HOST_amd:-?})" bash -c "[ '$(node_of amd-quota-test)' = '${HOST_amd:-}' ]"
NODE_POOL=nvidia render "$OIF_HOME/platform/runai/quota-test.yaml" | sed 's/name: gpu-quota-test$/name: gpu-quota-test-2/' | kc apply -f - >/dev/null
# an NVIDIA GPU asked for in pool amd: no node of that pool has one, so it must never be placed
NODE_POOL=amd render "$OIF_HOME/platform/runai/quota-test.yaml" | sed 's/name: gpu-quota-test$/name: wrong-pool/' | kc apply -f - >/dev/null
sleep 45
check "a second pod in pool nvidia waits (quota 1 used)" bash -c "[ '$(phase gpu-quota-test-2)' = Pending ]"
check "an NVIDIA GPU asked for in pool amd is never placed" bash -c "[ '$(phase wrong-pool)' = Pending ] && [ -z '$(node_of wrong-pool)' ]"
echo "        waiting reason: $(kc -n "$NS" get events --field-selector involvedObject.name=gpu-quota-test-2 -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1 | cut -c1-140)"
kc -n "$NS" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test wrong-pool --wait=false >/dev/null 2>&1

echo
if [ $FAILS = 0 ]; then echo "T-123: PASS ($N checks)"; else echo "T-123: FAIL ($FAILS of $N checks failed)"; fi
[ $FAILS = 0 ]
