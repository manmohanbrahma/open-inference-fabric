# shellcheck shell=bash
# T-111/T-112 AMD GPUs: AMD GPU Operator on the in-kernel amdgpu driver; a pod and the metrics exporter prove it.
# S-2: Run:ai quotas on amd.com/gpu.

AMD_NS=kube-amd-gpu
AMD_WORKSTATION_IDS="7448 744a 745e"     # Radeon PRO W7900 / W7900 dual slot / W7800: kernel 7.0 phantom UMC ECC errors
AMD_ECC_UMC_THRESHOLD=4000000000
AMD_GPU_OPERATOR_REV=$AMD_GPU_OPERATOR_VERSION-r2   # bump the suffix when platform/gpu-amd/ changes: reruns the stages

amd_targets() { discover_gpus; if [ -n "${AMD_GPUS:-}" ]; then echo "${AMD_GPUS//,/ }"; else echo "${AMD_BDFS[*]}"; fi; }

register_stage amd-gpu-operator AMD_GPU_OPERATOR_REV
stage_amd_gpu_operator() {
  local b t chart ws=""; t=$(amd_targets)
  [ -n "$t" ] || { warn "no AMD compute GPU: AMD GPU Operator skipped"; return 0; }
  for b in $t; do [ "$(drv "$b")" = amdgpu ] || die "$b is on driver '$(drv "$b")', not amdgpu"
    [[ " $AMD_WORKSTATION_IDS " == *" $(pci_ids "$b" | cut -d: -f2) "* ]] && ws=yes; done
  [ -e /dev/kfd ] || die "/dev/kfd is missing: the amdgpu driver did not enable compute"
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

register_stage amd-gpu-verify AMD_GPU_OPERATOR_REV
stage_amd_gpu_verify() {
  local want node out ip m; want=$(amd_targets | wc -w); [ "$want" -gt 0 ] || return 0
  node=$(kc get nodes -o jsonpath='{.items[0].metadata.name}')
  wait_for "amd.com/gpu advertised" 300 10 bash -c \
    "[ \"\$(kubectl --kubeconfig $KCFG get node $node -o jsonpath='{.status.allocatable.amd\.com/gpu}')\" = $want ]" \
    || die "the node does not advertise $want amd.com/gpu (kubectl -n $AMD_NS logs ds/default-device-plugin)"
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
  ip=$(kc -n "$AMD_NS" get svc default-metrics-exporter -o jsonpath='{.spec.clusterIP}' 2>/dev/null) || true   # <DeviceConfig>-metrics-exporter
  [ -n "$ip" ] || die "AMD metrics exporter service default-metrics-exporter not found (kubectl -n $AMD_NS get svc)"
  wait_for "AMD GPU metrics" 180 10 bash -c "curl -fsS -m 10 http://$ip:5000/metrics | grep -q '^gpu_'" || die "no AMD GPU metrics at $ip:5000"
  m=$(curl -fsS -m 10 "http://$ip:5000/metrics" | grep -E '^(gpu_edge_temperature|gpu_junction_temperature|gpu_power_usage|gpu_used_vram|gpu_total_vram|gpu_health)\{' \
    | sed -E 's/\{[^}]*\}//' | awk '{printf "%s=%s ", $1, $2}')
  ok "pod got the AMD GPU; metrics: ${m:-none of the expected series}"
}

register_stage amd-quota
stage_amd_quota() {   # S-2: Run:ai quotas count amd.com/gpu (team-a quota 1 runs, team-b quota 0 waits on a free GPU)
  [ -n "$(amd_targets)" ] || return 0
  local a b reason
  a=$(runai_api project team-a 1 1) || die "project team-a: $a"
  b=$(runai_api project team-b 0 0) || die "project team-b: $b"
  export BUSYBOX_IMAGE
  kc -n "$a" delete pod amd-quota-test --ignore-not-found --wait=true >/dev/null 2>&1; kc -n "$b" delete pod amd-quota-test --ignore-not-found --wait=true >/dev/null 2>&1
  NS=$b render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >> "$LOG" || die "AMD test pod for team-b rejected"
  sleep 45
  [ "$(kc -n "$b" get pod amd-quota-test -o jsonpath='{.status.phase}')" = Pending ] \
    || die "team-b's AMD GPU pod is '$(kc -n "$b" get pod amd-quota-test -o jsonpath='{.status.phase}')' although its quota is 0 (quota not enforced on amd.com/gpu)"
  reason=$(kc -n "$b" get events --field-selector involvedObject.name=amd-quota-test -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1)
  ok "team-b (quota 0) waits while the AMD GPU is free: ${reason:-pending}"
  NS=$a render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >> "$LOG" || die "AMD test pod for team-a rejected"
  wait_for "team-a (quota 1) gets the AMD GPU" 300 5 bash -c \
    "[ \"\$(kubectl --kubeconfig $KCFG -n $a get pod amd-quota-test -o jsonpath='{.status.phase}')\" = Running ]" \
    || die "team-a's AMD GPU pod did not start (kubectl -n $a describe pod amd-quota-test)"
  ok "team-a runs with $(kc -n "$a" logs amd-quota-test 2>/dev/null | tr '\n' ' '); team-b still $(kc -n "$b" get pod amd-quota-test -o jsonpath='{.status.phase}')"
  kc -n "$a" delete pod amd-quota-test --wait=true >> "$LOG" 2>&1; kc -n "$b" delete pod amd-quota-test --wait=true >> "$LOG" 2>&1
  ok "S-2 passed: Run:ai enforces quotas on amd.com/gpu"
}
