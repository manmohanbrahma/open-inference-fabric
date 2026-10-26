#!/bin/bash
# Acceptance test for T-122, run on the first node after  sudo ./oif install --until amd-gpu-verify  (or later).
# Creates and deletes two short test pods (namespaces oif-t122-nvidia, oif-t122-amd); otherwise read-only.
#   sudo tests/lab/t122-gpus.sh
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

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
node_alloc() { kc get node "$1" -o jsonpath="{.status.allocatable.${2//./\\.}}"; }
pod_on() {   # namespace pod: the node it ran on
  kc -n "$1" get pod "$2" -o jsonpath='{.spec.nodeName}'; }
pod_done() { kc -n "$1" get pod "$2" -o jsonpath='{.status.phase}' | grep -qE 'Succeeded|Failed'; }

INV=$(gpu_inventory)
NV=$(awk '$3 == "nvidia"' <<< "$INV" | wc -l); AMD=$(awk '$3 == "amd"' <<< "$INV" | wc -l)
echo "T-122 GPUs on their nodes ($NV NVIDIA, $AMD AMD)"
sed 's/^/        /' <<< "$INV"
check "at least one NVIDIA and one AMD GPU in the cluster" test "$NV" -ge 1 -a "$AMD" -ge 1

while read -r name addr kind bdf dev drv; do
  [ -n "$name" ] || continue
  host=$(on_gpu_node "$addr" hostname)
  if [ "$kind" = nvidia ]; then
    check "$name: $bdf on the nvidia driver" test "$drv" = nvidia
    check "$name: nvidia-smi sees the GPU" on_gpu_node "$addr" "nvidia-smi -L | grep -q GPU"
    check "$name: node $host offers nvidia.com/gpu" test "$(node_alloc "$host" nvidia.com/gpu)" -ge 1
  else
    check "$name: $bdf on the amdgpu driver" test "$drv" = amdgpu
    check "$name: /dev/kfd present" on_gpu_node "$addr" "test -e /dev/kfd"
    check "$name: node $host offers amd.com/gpu" test "$(node_alloc "$host" amd.com/gpu)" -ge 1
  fi
done <<< "$INV"

check "the cluster offers exactly $NV nvidia.com/gpu" gpu_resource_is nvidia.com/gpu "$NV"
check "the cluster offers exactly $AMD amd.com/gpu" gpu_resource_is amd.com/gpu "$AMD"
GPU_HOSTS=" $(while read -r _ addr _; do on_gpu_node "$addr" hostname; done <<< "$INV" | sort -u | paste -sd' ') "
while read -r n; do
  [[ $GPU_HOSTS == *" $n "* ]] && continue
  check "$n (no GPU) offers no GPU resource" bash -c "[ -z \"\$(kubectl --kubeconfig $KCFG get node $n -o jsonpath='{.status.allocatable.nvidia\\.com/gpu}{.status.allocatable.amd\\.com/gpu}' | tr -d 0)\" ]"
done < <(kc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

check "NVIDIA GPU Operator ready (ClusterPolicy)" bash -c "kubectl --kubeconfig $KCFG get clusterpolicy cluster-policy -o jsonpath='{.status.state}' | grep -qx ready"
check "AMD device plugin running on every AMD node" bash -c "n=\$(kubectl --kubeconfig $KCFG -n kube-amd-gpu get ds default-device-plugin -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}'); [ \"\${n%/*}\" -ge 1 ] && [ \"\${n%/*}\" = \"\${n#*/}\" ]"

# one pod per vendor: lands on that vendor's node and gets only that GPU
nv_node=$(node_with nvidia.com/gpu); amd_node=$(node_with amd.com/gpu)
kc delete namespace oif-t122-nvidia oif-t122-amd --ignore-not-found --wait=true >/dev/null 2>&1
kc create namespace oif-t122-nvidia >/dev/null; kc create namespace oif-t122-amd >/dev/null
kc -n oif-t122-nvidia run smi --restart=Never --image="$CUDA_SAMPLE_IMAGE" --overrides='{"spec":{"runtimeClassName":"nvidia","containers":[{"name":"smi","image":"'"$CUDA_SAMPLE_IMAGE"'","command":["sh","-c","nvidia-smi -L; ls /dev/kfd 2>&1 | head -1"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}' >/dev/null
kc -n oif-t122-amd run devs --restart=Never --image="$BUSYBOX_IMAGE" --overrides='{"spec":{"containers":[{"name":"devs","image":"'"$BUSYBOX_IMAGE"'","command":["sh","-c","ls /dev/kfd; ls /dev/dri; ls /dev/nvidia0 2>&1"],"resources":{"limits":{"amd.com/gpu":"1"}}}]}}' >/dev/null
both_done() { pod_done oif-t122-nvidia smi && pod_done oif-t122-amd devs; }
wait_for "test pods finished" 600 5 both_done >/dev/null 2>&1 || true
nv_log=$(kc -n oif-t122-nvidia logs smi 2>&1); amd_log=$(kc -n oif-t122-amd logs devs 2>&1)
echo "        NVIDIA pod on $(pod_on oif-t122-nvidia smi): $(head -1 <<< "$nv_log")"
echo "        AMD pod on $(pod_on oif-t122-amd devs): $(tr '\n' ' ' <<< "$amd_log")"
check "NVIDIA pod ran on the NVIDIA node" test "$(pod_on oif-t122-nvidia smi)" = "$nv_node"
check "NVIDIA pod sees its GPU and no /dev/kfd" bash -c "grep -q '^GPU 0:' <<< '$nv_log' && grep -q 'No such file' <<< '$nv_log'"
check "AMD pod ran on the AMD node" test "$(pod_on oif-t122-amd devs)" = "$amd_node"
check "AMD pod has /dev/kfd and a render device, no /dev/nvidia0" bash -c "grep -q '^/dev/kfd' <<< '$amd_log' && grep -q renderD <<< '$amd_log' && grep -q 'No such file' <<< '$amd_log'"
kc delete namespace oif-t122-nvidia oif-t122-amd --wait=false >/dev/null 2>&1

ip=$(kc -n gpu-operator get svc nvidia-dcgm-exporter -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
check "DCGM exporter reports the NVIDIA GPU" bash -c "curl -fsS -m 10 http://$ip:9400/metrics | grep -q '^DCGM_FI_DEV_GPU_TEMP'"
ip=$(kc -n kube-amd-gpu get svc default-metrics-exporter -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
check "AMD metrics exporter reports the AMD GPU" bash -c "curl -fsS -m 10 http://$ip:5000/metrics | grep -q '^gpu_edge_temperature'"

echo
if [ $FAILS = 0 ]; then echo "T-122: PASS ($N checks)"; else echo "T-122: FAIL ($FAILS of $N checks failed)"; fi
[ $FAILS = 0 ]
