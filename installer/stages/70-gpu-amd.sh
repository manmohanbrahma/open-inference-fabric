# shellcheck shell=bash
# T-111/T-112 AMD GPUs: AMD GPU Operator on the in-kernel amdgpu driver; a pod and the metrics exporter prove it.
# S-2: Run:ai quotas on amd.com/gpu.

AMD_NS=kube-amd-gpu
AMD_WORKSTATION_IDS="7448 744a 745e"     # Radeon PRO W7900 / W7900 dual slot / W7800: kernel 7.0 phantom UMC ECC errors
AMD_ECC_UMC_THRESHOLD=4000000000
AMD_GPU_OPERATOR_REV=$AMD_GPU_OPERATOR_VERSION-r3   # bump the suffix when platform/gpu-amd/ changes: reruns the stages

amd_exporter_ip() {   # the first AMD metrics exporter pod (its Service answers only on AMD nodes)
  kc -n "$AMD_NS" get endpointslices -l kubernetes.io/service-name=default-metrics-exporter \
    -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null | awk '{print $1}'; }
amd_targets() { discover_gpus; if [ -n "${AMD_GPUS:-}" ]; then echo "${AMD_GPUS//,/ }"; else echo "${AMD_BDFS[*]}"; fi; }

register_stage amd-gpu-operator AMD_GPU_OPERATOR_REV
register_teardown amd-gpu-operator
stage_amd_gpu_operator() {
  local name addr kind b dev drv chart ws="" n=0
  while read -r name addr kind b dev drv; do   # every AMD GPU of the cluster, checked on its own node
    [ "$kind" = amd ] || continue; n=$((n + 1))
    [ "$drv" = amdgpu ] || die "$name: $b is on driver '$drv', not amdgpu"
    on_gpu_node "$addr" "test -e /dev/kfd" || die "$name: /dev/kfd is missing: the amdgpu driver did not enable compute"
    [[ " $AMD_WORKSTATION_IDS " == *" $dev "* ]] && ws=yes
  done < <(gpu_inventory)
  [ $n -gt 0 ] || { warn "no AMD compute GPU on any node: AMD GPU Operator skipped"; return 0; }
  rec "TEARDOWN amd-gpu-operator"
  chart=$STATE/charts/gpu-operator-charts-$AMD_GPU_OPERATOR_VERSION.tgz; mkdir -p "$STATE/charts"
  [ -s "$chart" ] || fetch_pinned "https://rocm.github.io/gpu-operator/charts/gpu-operator-charts-$AMD_GPU_OPERATOR_VERSION.tgz" "$AMD_GPU_OPERATOR_SHA256" "$chart"
  kc create namespace "$AMD_NS" --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  if [ -n "$ws" ]; then
    export AMD_ECC_UMC_THRESHOLD; render "$OIF_HOME/platform/gpu-amd/metrics-config.yaml" | kc apply -f - >> "$LOG" || die "metrics config rejected"
    ok "metrics exporter: UMC ECC health threshold raised for the Radeon PRO workstation GPU on kernel $(uname -r)"
  else
    kc -n "$AMD_NS" create configmap amd-metrics-config --from-literal=config.json='{}' --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  fi
  export BUSYBOX_IMAGE AMD_UTILS_IMAGE AMD_DEVICE_PLUGIN_IMAGE AMD_NODE_LABELLER_IMAGE AMD_METRICS_EXPORTER_IMAGE
  render "$OIF_HOME/platform/gpu-amd/values.yaml" > "$STATE/amd-values.yaml"
  log "AMD GPU Operator $AMD_GPU_OPERATOR_VERSION (2-5 min)"
  hl upgrade --install amd-gpu-operator "$chart" -n "$AMD_NS" -f "$STATE/amd-values.yaml" --wait --timeout 10m >> "$LOG" 2>&1 \
    || die "AMD GPU Operator chart failed (kubectl -n $AMD_NS get pods; helm -n $AMD_NS status amd-gpu-operator)"
  wait_for "AMD GPU node labelled by Node Feature Discovery" 300 10 bash -c \
    "kubectl --kubeconfig $KCFG get nodes -l feature.node.kubernetes.io/amd-gpu=true --no-headers | grep -q ." \
    || die "no node labelled feature.node.kubernetes.io/amd-gpu=true (kubectl get nodefeaturerules; NFD runs in namespace gpu-operator)"
  # The controller is ready for its first minutes even when it later crash-loops; only its device plugin proves it works.
  wait_for "AMD device plugin running" 600 10 bash -c \
    "n=\$(kubectl --kubeconfig $KCFG -n $AMD_NS get ds default-device-plugin -o jsonpath='{.status.desiredNumberScheduled}/{.status.numberReady}'); [ \"\${n%/*}\" -gt 0 ] && [ \"\${n%/*}\" = \"\${n#*/}\" ]" \
    || { kc -n "$AMD_NS" get pods | tee -a "$TLOG"; kc -n "$AMD_NS" logs deploy/amd-gpu-operator-gpu-operator-charts-controller-manager --tail=5 2>&1 | tee -a "$TLOG"
         die "AMD device plugin not running (kubectl -n $AMD_NS logs deploy/amd-gpu-operator-gpu-operator-charts-controller-manager)"; }
  wait_for "AMD GPU Operator pods running" 600 10 pods_settled "$AMD_NS" \
    || { kc -n "$AMD_NS" get pods | grep -vE 'Running|Completed' | tee -a "$TLOG"; die "AMD GPU Operator pods not running"; }
}

teardown_amd_gpu_operator() {   # DeviceConfig, then the chart, then host leftovers
  if kc get --raw /readyz >/dev/null 2>&1; then
    # The chart's pre-delete hook deletes the DeviceConfig and waits for its finalizer; on the reference host (KMM off) it
    # never finished and helm timed out after 5 min. Delete it here with a limit, drop a stuck finalizer, skip the hook.
    if ! kc delete deviceconfigs.amd.com --all -n "$AMD_NS" --timeout=90s >> "$LOG" 2>&1; then
      warn "DeviceConfig deletion stuck: removing its finalizer"
      local dc; for dc in $(kc -n "$AMD_NS" get deviceconfigs.amd.com -o name 2>/dev/null); do
        kc -n "$AMD_NS" patch "$dc" --type merge -p '{"metadata":{"finalizers":null}}' >> "$LOG" 2>&1 || true; done
    fi
    hl uninstall amd-gpu-operator -n "$AMD_NS" --no-hooks --wait --timeout 3m >> "$LOG" 2>&1 || warn "helm uninstall amd-gpu-operator did not finish"
  fi
  # seen on the reference host: the exporter's health binary and gRPC socket, and its runtime folder
  rm -rf /var/lib/amd-metrics-exporter /var/run/exporter 2>/dev/null || true
  local name addr kind   # multi-node: the exporter ran on the AMD nodes, which are still reachable at this point
  while read -r -u 3 name addr kind _; do
    [ "$kind" = amd ] && { on_gpu_node "$addr" "sudo rm -rf /var/lib/amd-metrics-exporter /var/run/exporter" >/dev/null 2>&1 || warn "$name: AMD exporter folders not removed"; }
  done 3< <(multi_node && gpu_inventory || true)
  ok "AMD GPU Operator removed"
}

register_stage amd-gpu-verify AMD_GPU_OPERATOR_REV
stage_amd_gpu_verify() {
  local want node out ip m; want=$(gpu_count amd); [ "$want" -gt 0 ] || return 0
  wait_for "amd.com/gpu advertised ($want in the cluster)" 300 10 gpu_resource_is amd.com/gpu "$want" \
    || die "the cluster does not advertise $want amd.com/gpu (kubectl -n $AMD_NS logs ds/default-device-plugin)"
  node=$(node_with amd.com/gpu)
  out=$(kc get node "$node" -o json | python3 -c 'import json,sys; l=json.load(sys.stdin)["metadata"]["labels"]; print(", ".join(f"{k.split("/")[1]}={l[k]}" for k in sorted(l) if k in ("amd.com/gpu.product-name", "amd.com/gpu.vram", "amd.com/gpu.family", "amd.com/gpu.device-id")))')
  ok "node advertises amd.com/gpu: $want (${out:-no AMD labels yet})"
  export BUSYBOX_IMAGE
  kc delete namespace oif-amd-test --ignore-not-found --wait=true >/dev/null 2>&1
  render "$OIF_HOME/platform/gpu-amd/gpu-test.yaml" | kc apply -f - >> "$LOG" || die "AMD test pod could not be created"
  wait_for "AMD test pod finished" 300 5 bash -c \
    "kubectl --kubeconfig $KCFG -n oif-amd-test get pod amd -o jsonpath='{.status.phase}' | grep -qE 'Succeeded|Failed'" || true
  out=$(kc -n oif-amd-test logs amd 2>&1)
  sed 's/^/    /' <<< "$out" | tee -a "$TLOG"
  grep -q '/dev/kfd' <<< "$out" && grep -q 'renderD' <<< "$out" || die "the pod did not get the AMD GPU's devices (kubectl -n oif-amd-test describe pod amd)"
  kc delete namespace oif-amd-test --wait=true >> "$LOG" 2>&1 || warn "test namespace oif-amd-test not deleted"
  # The exporter's Service (<DeviceConfig>-metrics-exporter) has internalTrafficPolicy Local: its address answers only on
  # an AMD node. Ask the exporter pod itself (Prometheus scrapes the pods too).
  ip=$(amd_exporter_ip) || true
  [ -n "$ip" ] || die "no AMD metrics exporter pod behind service default-metrics-exporter (kubectl -n $AMD_NS get pods,endpointslices)"
  wait_for "AMD GPU metrics" 180 10 bash -c "curl -fsS -m 10 http://$ip:5000/metrics | grep -q '^gpu_'" || die "no AMD GPU metrics at $ip:5000"
  m=$(curl -fsS -m 10 "http://$ip:5000/metrics" | grep -E '^(gpu_edge_temperature|gpu_junction_temperature|gpu_power_usage|gpu_used_vram|gpu_total_vram|gpu_health)\{' \
    | sed -E 's/\{[^}]*\}//' | awk '{printf "%s=%s ", $1, $2}')
  ok "pod got the AMD GPU; metrics: ${m:-none of the expected series}"
}

register_stage amd-quota
stage_amd_quota() {   # S-2: Run:ai quotas count amd.com/gpu (team-a quota 1 runs, team-b quota 0 waits on a free GPU)
  [ "$(gpu_count amd)" -gt 0 ] || return 0
  local a b reason
  a=$(runai_project team-a 1) || die "project team-a: $a"
  b=$(runai_project team-b 0) || die "project team-b: $b"
  export BUSYBOX_IMAGE
  kc -n "$a" delete pod amd-quota-test --ignore-not-found --wait=true >/dev/null 2>&1; kc -n "$b" delete pod amd-quota-test --ignore-not-found --wait=true >/dev/null 2>&1
  NS=$b NODE_POOL=$(pool_for amd) render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >> "$LOG" || die "AMD test pod for team-b rejected"
  sleep 45
  [ "$(kc -n "$b" get pod amd-quota-test -o jsonpath='{.status.phase}')" = Pending ] \
    || die "team-b's AMD GPU pod is '$(kc -n "$b" get pod amd-quota-test -o jsonpath='{.status.phase}')' although its quota is 0 (quota not enforced on amd.com/gpu)"
  reason=$(kc -n "$b" get events --field-selector involvedObject.name=amd-quota-test -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1)
  ok "team-b (quota 0) waits while the AMD GPU is free: ${reason:-pending}"
  NS=$a NODE_POOL=$(pool_for amd) render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >> "$LOG" || die "AMD test pod for team-a rejected"
  wait_for "team-a (quota 1) gets the AMD GPU" 300 5 bash -c \
    "[ \"\$(kubectl --kubeconfig $KCFG -n $a get pod amd-quota-test -o jsonpath='{.status.phase}')\" = Running ]" \
    || die "team-a's AMD GPU pod did not start (kubectl -n $a describe pod amd-quota-test)"
  ok "team-a runs with $(kc -n "$a" logs amd-quota-test 2>/dev/null | tr '\n' ' '); team-b still $(kc -n "$b" get pod amd-quota-test -o jsonpath='{.status.phase}')"
  kc -n "$a" delete pod amd-quota-test --wait=true >> "$LOG" 2>&1; kc -n "$b" delete pod amd-quota-test --wait=true >> "$LOG" 2>&1
  ok "S-2 passed: Run:ai enforces quotas on amd.com/gpu"
}

# the templates stage reruns when a template file or a pinned image changes
AMD_TEMPLATES_REV=$(cat "$OIF_HOME"/platform/runai/templates/*.json 2>/dev/null | { cat; echo "$ROCM_PYTORCH_IMAGE $JUPYTERLAB_VERSION"; } | sha256sum | cut -c1-12)

register_stage runai-amd-templates AMD_TEMPLATES_REV
stage_runai_amd_templates() {   # T-115: Run:ai workload templates on amd.com/gpu (extendedResources), next to Run:ai's NVIDIA ones
  [ "$(gpu_count amd)" -gt 0 ] || return 0
  local f out tmp; tmp=$(mktemp)
  export ROCM_PYTORCH_IMAGE JUPYTERLAB_VERSION
  for f in "$OIF_HOME"/platform/runai/templates/*.json; do
    render "$f" > "$tmp" || { rm -f "$tmp"; die "cannot render $f"; }
    out=$(runai_api template "$tmp" 2>&1) || { rm -f "$tmp"; die "Run:ai template from ${f##*/}: $out"; }
    ok "$out"
  done
  rm -f "$tmp"
}

register_stage vendor-quota
stage_vendor_quota() {   # T-113 (ADR-015): team-c, Run:ai quota 2 GPUs, capped at 1 NVIDIA + 1 AMD by a Kubernetes ResourceQuota
  local alloc c out
  alloc=$(allocatable_sum nvidia.com/gpu)/$(allocatable_sum amd.com/gpu)   # over every node of the cluster
  [ "${alloc%/*}" -ge 1 ] 2>/dev/null && [ "${alloc#*/}" -ge 1 ] 2>/dev/null || { warn "per-vendor quota test needs an NVIDIA and an AMD GPU: skipped"; return 0; }
  if multi_node; then vendor_quota_pools; return; fi   # several nodes: Run:ai's own quota per vendor pool (T-123)
  c=$(runai_api project team-c 2 2) || die "project team-c: $c"
  export BUSYBOX_IMAGE CUDA_SAMPLE_IMAGE
  NS=$c NVIDIA_GPU_CAP=1 AMD_GPU_CAP=1 render "$OIF_HOME/platform/runai/vendor-quota.yaml" | kc apply -f - >> "$LOG" || die "ResourceQuota for $c rejected"
  ok "project team-c (Run:ai quota 2 GPUs, namespace $c) capped at 1 NVIDIA + 1 AMD GPU"
  kc -n "$c" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test --ignore-not-found --wait=true >/dev/null 2>&1
  NS=$c NODE_POOL=$(pool_for nvidia) render "$OIF_HOME/platform/runai/quota-test.yaml" | kc apply -f - >> "$LOG" || die "NVIDIA test pod for team-c rejected"
  NS=$c NODE_POOL=$(pool_for amd) render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >> "$LOG" || die "AMD test pod for team-c rejected"
  wait_for "team-c runs one GPU of each vendor" 300 5 bash -c \
    "[ \"\$(kubectl --kubeconfig $KCFG -n $c get pod gpu-quota-test amd-quota-test -o jsonpath='{.items[*].status.phase}')\" = 'Running Running' ]" \
    || die "team-c's GPU pods did not both start (kubectl -n $c describe pod gpu-quota-test amd-quota-test)"
  ok "team-c runs $(kc -n "$c" logs gpu-quota-test 2>/dev/null | head -1 | cut -d'(' -f1)and the AMD GPU ($(kc -n "$c" logs amd-quota-test 2>/dev/null | tr '\n' ' '))"
  # a second NVIDIA GPU pod: inside Run:ai's quota of 2, over the NVIDIA cap of 1
  if out=$(NS=$c NODE_POOL=$(pool_for nvidia) render "$OIF_HOME/platform/runai/quota-test.yaml" | sed 's/name: gpu-quota-test$/name: gpu-quota-test-2/' | kc create -f - 2>&1); then
    die "a second NVIDIA GPU pod was accepted in $c although the NVIDIA cap is 1 (kubectl -n $c describe resourcequota oif-gpu-vendor)"
  fi
  grep -q 'exceeded quota' <<< "$out" || die "second NVIDIA pod failed for another reason: $out"
  ok "a second NVIDIA GPU pod is refused: $(grep -o 'exceeded quota.*' <<< "$out" | head -1)"
  kc -n "$c" delete pod gpu-quota-test amd-quota-test --wait=true >> "$LOG" 2>&1
  ok "T-113 passed: per-vendor GPU caps inside one Run:ai project (project team-c and its quota kept)"
}

# Both GPU operators come before the platform: the AMD one right after prometheus (its exporter's ServiceMonitor
# needs the monitoring CRDs), so Run:ai and the rest find both vendors' GPUs
stage_after amd-gpu-operator prometheus
stage_after amd-gpu-verify amd-gpu-operator

vendor_quota_pools() {   # T-123: team-c has 1 GPU in pool nvidia and 1 in pool amd; a second NVIDIA pod waits in the queue
  local c reason
  c=$(runai_api project-pools team-c nvidia=1 amd=1) || die "project team-c: $c"
  ok "project team-c (namespace $c): Run:ai quota 1 GPU in node pool nvidia and 1 in node pool amd"
  export BUSYBOX_IMAGE CUDA_SAMPLE_IMAGE
  kc -n "$c" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test --ignore-not-found --wait=true >/dev/null 2>&1
  NS=$c NODE_POOL=nvidia render "$OIF_HOME/platform/runai/quota-test.yaml" | kc apply -f - >> "$LOG" || die "NVIDIA test pod for team-c rejected"
  NS=$c NODE_POOL=amd render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >> "$LOG" || die "AMD test pod for team-c rejected"
  wait_for "team-c runs one GPU in each vendor's pool" 300 5 bash -c \
    "[ \"\$(kubectl --kubeconfig $KCFG -n $c get pod gpu-quota-test amd-quota-test -o jsonpath='{.items[*].status.phase}')\" = 'Running Running' ]" \
    || die "team-c's GPU pods did not both start (kubectl -n $c describe pod gpu-quota-test amd-quota-test)"
  ok "team-c runs $(kc -n "$c" logs gpu-quota-test 2>/dev/null | head -1 | cut -d'(' -f1)on $(kc -n "$c" get pod gpu-quota-test -o jsonpath='{.spec.nodeName}') and the AMD GPU on $(kc -n "$c" get pod amd-quota-test -o jsonpath='{.spec.nodeName}')"
  # a second NVIDIA pod: accepted (no ResourceQuota on several nodes) but over the project's quota in pool nvidia
  NS=$c NODE_POOL=nvidia render "$OIF_HOME/platform/runai/quota-test.yaml" | sed 's/name: gpu-quota-test$/name: gpu-quota-test-2/' | kc apply -f - >> "$LOG" \
    || die "second NVIDIA test pod for team-c rejected"
  sleep 45
  [ "$(kc -n "$c" get pod gpu-quota-test-2 -o jsonpath='{.status.phase}')" = Pending ] \
    || die "team-c's second NVIDIA pod is '$(kc -n "$c" get pod gpu-quota-test-2 -o jsonpath='{.status.phase}')' although pool nvidia's quota is used"
  reason=$(kc -n "$c" get events --field-selector involvedObject.name=gpu-quota-test-2 -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1)
  ok "a second NVIDIA pod waits in the queue: ${reason:-pending}"
  kc -n "$c" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test --wait=true >> "$LOG" 2>&1
  ok "T-123: per-vendor quotas through Run:ai node pools (project team-c kept)"
}
