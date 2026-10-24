# shellcheck shell=bash
# T-104 NVIDIA GPU Operator: default stack on the host driver; a CUDA pod and DCGM metrics prove it.

GPU_NS=gpu-operator

register_stage gpu-operator
register_teardown gpu-operator
stage_gpu_operator() {
  [ -n "$(nv_targets)" ] || { warn "no NVIDIA GPU: GPU Operator skipped"; return 0; }
  mkdir -p "$STATE/charts"; local chart=$STATE/charts/gpu-operator-$GPU_OPERATOR_VERSION.tgz
  [ -s "$chart" ] || fetch_pinned "https://helm.ngc.nvidia.com/nvidia/charts/gpu-operator-$GPU_OPERATOR_VERSION.tgz" "$GPU_OPERATOR_SHA256" "$chart"
  rec "TEARDOWN gpu-operator"
  log "GPU Operator $GPU_OPERATOR_VERSION (pulls the operator images, 3-8 min)"
  hl upgrade --install gpu-operator "$chart" -n "$GPU_NS" --create-namespace \
    -f "$OIF_HOME/platform/gpu-nvidia/values.yaml" --wait --timeout 10m >> "$LOG" 2>&1 \
    || die "GPU Operator chart failed (kubectl -n $GPU_NS get pods; helm -n $GPU_NS status gpu-operator)"
  wait_for "GPU Operator ready (ClusterPolicy)" 1200 15 bash -c \
    "kubectl --kubeconfig $KCFG get clusterpolicy cluster-policy -o jsonpath='{.status.state}' | grep -qx ready" \
    || { kc -n "$GPU_NS" get pods | grep -vE 'Running|Completed' | tee -a "$TLOG"; die "GPU Operator not ready (kubectl -n $GPU_NS get pods)"; }
}

teardown_gpu_operator() {   # chart first so the toolkit undoes its containerd and CDI changes; then any leftovers
  if kc get --raw /readyz >/dev/null 2>&1; then
    hl uninstall gpu-operator -n "$GPU_NS" --wait --timeout 5m >> "$LOG" 2>&1 || warn "helm uninstall gpu-operator did not finish"
  fi
  rm -rf /etc/containerd/conf.d/99-nvidia.toml /usr/local/nvidia /etc/cdi/nvidia*.yaml /var/run/cdi/nvidia*.yaml 2>/dev/null || true
  rmdir /etc/containerd/conf.d /etc/cdi /var/run/cdi 2>/dev/null || true
  ok "GPU Operator removed"
}

register_stage gpu-verify
stage_gpu_verify() {
  [ -n "$(nv_targets)" ] || return 0
  local want n node; want=$(nv_targets | wc -w); node=$(kc get nodes -o jsonpath='{.items[0].metadata.name}')
  wait_for "nvidia.com/gpu advertised" 300 10 bash -c \
    "[ \"\$(kubectl --kubeconfig $KCFG get node $node -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')\" = $want ]" \
    || die "the node does not advertise $want nvidia.com/gpu (kubectl describe node $node)"
  n=$(kc get node "$node" -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}')
  [ -n "$n" ] || die "GPU feature discovery labels missing (kubectl get node $node --show-labels)"
  ok "node advertises nvidia.com/gpu: $want ($n)"
  export CUDA_SAMPLE_IMAGE
  kc delete namespace oif-gpu-test --ignore-not-found --wait=true >/dev/null 2>&1
  render "$OIF_HOME/platform/gpu-nvidia/gpu-test.yaml" | kc apply -f - >> "$LOG" || die "GPU test pod could not be created"
  wait_for "CUDA test pod finished" 600 5 bash -c \
    "kubectl --kubeconfig $KCFG -n oif-gpu-test get pod cuda -o jsonpath='{.status.phase}' | grep -qE 'Succeeded|Failed'" || true
  local smi va; smi=$(kc -n oif-gpu-test logs cuda -c nvidia-smi 2>&1 | head -3); va=$(kc -n oif-gpu-test logs cuda -c vectoradd 2>&1 | tail -3)
  printf '%s\n%s\n' "$smi" "$va" | sed 's/^/    /' | tee -a "$TLOG"
  grep -q '^GPU 0:' <<< "$smi" || die "nvidia-smi did not see a GPU inside the pod (kubectl -n oif-gpu-test describe pod cuda)"
  grep -q 'Test PASSED' <<< "$va" || die "CUDA vectorAdd did not pass (kubectl -n oif-gpu-test logs cuda -c vectoradd)"
  kc delete namespace oif-gpu-test --wait=true >> "$LOG" 2>&1 || warn "test namespace oif-gpu-test not deleted"
  local ip m; ip=$(kc -n "$GPU_NS" get svc nvidia-dcgm-exporter -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
  [ -n "$ip" ] || die "DCGM exporter service missing"
  wait_for "DCGM metrics" 180 10 bash -c "curl -fsS -m 10 http://$ip:9400/metrics | grep -q '^DCGM_FI_DEV_GPU_TEMP'" || die "no DCGM metrics at $ip:9400"
  m=$(curl -fsS -m 10 "http://$ip:9400/metrics" | awk '/^DCGM_FI_DEV_GPU_TEMP|^DCGM_FI_DEV_POWER_USAGE|^DCGM_FI_DEV_FB_USED/ {sub(/\{.*\}/,"",$1); printf "%s=%s ", $1, $2}')
  ok "pod saw the GPU, CUDA test passed; DCGM: $m"
}
