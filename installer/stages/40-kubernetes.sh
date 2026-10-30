# shellcheck shell=bash
# T-103 Kubernetes: kubeadm single node (control plane runs workloads), Calico, local-path storage, MetalLB, Helm.

K8S_TEMPLATES=$OIF_HOME/platform/kubernetes
K8S_REPO=https://pkgs.k8s.io/core:/stable:/v${KUBERNETES_VERSION%.*}/deb/

register_stage k8s-packages
stage_k8s_packages() {
  local key=/etc/apt/keyrings/oif-kubernetes.gpg list=/etc/apt/sources.list.d/oif-kubernetes.list tmp
  if [ ! -s "$key" ]; then
    tmp=$(mktemp); retry wget -q -O "$tmp" "${K8S_REPO}Release.key" || die "cannot download the Kubernetes package key"
    backup_file "$key"; mkdir -p /etc/apt/keyrings; gpg --batch --yes --dearmor -o "$key" "$tmp"; chmod 644 "$key"; rm -f "$tmp"
  fi
  put_file "$list" "deb [signed-by=$key] $K8S_REPO /
"
  local v="$KUBERNETES_VERSION-$KUBERNETES_PKG_REV"
  apt_install "kubelet=$v" "kubeadm=$v" "kubectl=$v" cri-tools
  apt-mark hold kubelet kubeadm kubectl >/dev/null
  put_file /etc/crictl.yaml $'runtime-endpoint: unix:///run/containerd/containerd.sock\nimage-endpoint: unix:///run/containerd/containerd.sock\n'
  if [ "$(helm version --short 2>/dev/null | cut -d+ -f1)" != "$HELM_VERSION" ]; then
    tmp=$(mktemp -d)
    fetch_pinned "https://get.helm.sh/helm-$HELM_VERSION-linux-amd64.tar.gz" "$HELM_SHA256" "$tmp/helm.tgz"
    tar -xzf "$tmp/helm.tgz" -C "$tmp"; backup_file /usr/local/bin/helm; install -m 755 "$tmp/linux-amd64/helm" /usr/local/bin/helm; rm -rf "$tmp"
  fi
  ok "kubeadm, kubelet, kubectl $KUBERNETES_VERSION (held); helm $(helm version --short | cut -d+ -f1)"
}

register_stage nodes nodes_rev   # multi-node: the node stages above on every other node (installer/lib/60-nodes.sh);
                                 # reruns when the node stages change (each node still skips the ones it has done)

register_stage kubernetes
register_teardown kubernetes
stage_kubernetes() {
  if [ -z "${POD_CIDR:-}" ]; then   # Kubernetes' defaults can overlap the host's own network (10.96.0.0/12 spans 10.96-10.111.x.x)
    POD_CIDR=$(pick_cidr 10.244.0.0/16 172.20.0.0/16 192.168.128.0/17) || die "no free pod network range"
    SERVICE_CIDR=$(pick_cidr 172.30.0.0/16 10.112.0.0/16 192.168.64.0/18) || die "no free service range"
    save POD_CIDR "$POD_CIDR"; save SERVICE_CIDR "$SERVICE_CIDR"
  fi
  ok "pod network $POD_CIDR, services $SERVICE_CIDR (no overlap with this host's networks)"
  if [ ! -f "$KCFG" ]; then
    rec "TEARDOWN kubernetes"
    API_ENDPOINT=$(api_endpoint)
    export HOST_IP POD_CIDR SERVICE_CIDR KUBERNETES_VERSION KUBELET_MAX_PODS API_ENDPOINT
    render "$K8S_TEMPLATES/kubeadm.yaml" > "$STATE/kubeadm.yaml" || die "cannot render the kubeadm configuration"
    # several control-plane nodes: kube-vip holds the API address; during init it needs super-admin.conf (ADR-017)
    [ -n "${OIF_API_VIP:-}" ] && kube_vip_manifest /etc/kubernetes/super-admin.conf "$HOST_IP"
    systemctl enable kubelet >/dev/null 2>&1
    log "kubeadm init (pulls the control-plane images, 2-5 min)"
    # its output names join credentials: kept in the root-only state folder, not in the readable install log
    if ! kubeadm init --config "$STATE/kubeadm.yaml" --skip-token-print > "$STATE/kubeadm-init.log" 2>&1; then
      grep -E '^\[|error|ERROR' "$STATE/kubeadm-init.log" | tail -20 | redact
      kubeadm reset -f >> "$STATE/kubeadm-init.log" 2>&1 || true   # so the next run starts clean
      die "kubeadm init failed (sudo less $STATE/kubeadm-init.log; journalctl -u kubelet); run oif install again after fixing the cause"
    fi
    grep -E '^\[(init|preflight|certs\] Generating "ca"|control-plane-check\] kube|addons)' "$STATE/kubeadm-init.log" | redact
  fi
  if [ -n "${OIF_API_VIP:-}" ] && grep -q super-admin.conf /etc/kubernetes/manifests/kube-vip.yaml 2>/dev/null; then
    kube_vip_manifest /etc/kubernetes/admin.conf "$HOST_IP"   # init is done: back to the normal admin credentials
    ok "kube-vip holds the API address $OIF_API_VIP"
  fi
  local kd=$UHOME/.kube
  [ -d "$kd" ] || rec "DIR $kd"
  backup_file "$kd/config"; install -d -m 700 -o "$INSTALL_USER" -g "$(id -gn "$INSTALL_USER")" "$kd"
  install -m 600 -o "$INSTALL_USER" -g "$(id -gn "$INSTALL_USER")" "$KCFG" "$kd/config"
  wait_for "API server answering" 300 5 kc get --raw /readyz || die "the API server did not come up (journalctl -u kubelet)"
  ok "Kubernetes $KUBERNETES_VERSION control plane on $(api_endpoint):6443; kubectl works for $INSTALL_USER"
}

register_stage k8s-join     # multi-node: the other control-plane nodes and the workers join (installer/lib/60-nodes.sh)

register_stage k8s-tokens
stage_k8s_tokens() {   # after the joins (if any): no join tokens or uploaded certificates are kept
  local t
  for t in $(kubeadm token list --kubeconfig "$KCFG" 2>/dev/null | awk 'NR>1 {print $1}' | cut -d. -f1); do
    kubeadm token delete --kubeconfig "$KCFG" "$t" >/dev/null 2>&1 || warn "join token $t not deleted"; done
  kc -n kube-system delete secret kubeadm-certs --ignore-not-found >/dev/null
  [ -z "$(kubeadm token list --kubeconfig "$KCFG" 2>/dev/null | awk 'NR>1')" ] || die "join tokens remain (sudo kubeadm token list)"
  redact_file "$LOG"   # installs before this stage existed copied kubeadm's join command into the log
  ok "no join tokens or uploaded certificates left ($(multi_node && echo 'all nodes joined' || echo 'single node'))"
}

teardown_kubernetes() {   # everything kubeadm and the network plugin put on the host
  # Stop the workloads while the API server still runs: Calico needs it to release pod networks, and GPU pods need the
  # NVIDIA runtime (removed later, with containerd). Left to kubeadm reset, both failed and the reset took 5.5 min.
  if command -v crictl >/dev/null && [ -S /run/containerd/containerd.sock ]; then
    systemctl stop kubelet >/dev/null 2>&1 || true
    # a re-run after a partial uninstall finds no pods and crictl may print nothing: that is not a failure
    local ids; ids=$({ crictl pods -o json 2>/dev/null || true; } | python3 -c '
import json, sys
text = sys.stdin.read().strip()
static = ("etcd-", "kube-apiserver-", "kube-controller-manager-", "kube-scheduler-")
for p in (json.loads(text).get("items") or [] if text else []):
    m = p["metadata"]
    if not (m["namespace"] == "kube-system" and m["name"].startswith(static)):
        print(p["id"])' | xargs) || ids=""
    if [ -n "$ids" ]; then
      # shellcheck disable=SC2086
      timeout 300 crictl stopp $ids >> "$LOG" 2>&1 || warn "some pods did not stop in time"
      # shellcheck disable=SC2086
      timeout 120 crictl rmp $ids >> "$LOG" 2>&1 || true
      ok "workload pods stopped and removed ($(wc -w <<< "$ids"))"
    fi
  fi
  # kube-vip added the API address to this node's interface; stopped, it leaves it there, and a node that keeps it
  # answers its own joins to that address with "connection refused" on the next install
  local vip=""; [ -f /etc/kubernetes/manifests/kube-vip.yaml ] \
    && vip=$(sed -n 's/.*{name: address, value: "\([0-9.]*\)"}.*/\1/p' /etc/kubernetes/manifests/kube-vip.yaml)
  kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock >> "$LOG" 2>&1 || true
  if [ -n "$vip" ]; then local d; for d in $(ip -o -4 addr show | awk -v a="$vip/32" '$4 == a {print $2}'); do
    ip addr del "$vip/32" dev "$d" >/dev/null 2>&1 || true; done; fi
  systemctl disable --now kubelet >/dev/null 2>&1 || true
  local t   # no mount left is fine: grep's "no match" must not fail the pipeline
  findmnt -rn -o TARGET | { grep -E '^/(var/lib/kubelet|run/netns|run/calico|var/lib/calico)(/|$)' || true; } | sort -r \
    | while read -r t; do umount "$t" 2>/dev/null || umount -l "$t" 2>/dev/null || true; done
  rm -rf --one-file-system /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni/net.d /var/lib/cni /var/lib/calico \
    /run/calico /var/log/calico /var/run/nodeagent /var/log/pods /var/log/containers 2>>"$LOG" || true
  local l; for l in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(cali|vxlan\.calico|tunl0|kube-ipvs0)'); do
    ip link delete "$l" >/dev/null 2>&1 || true; done
  # Calico leaves its routes (protocol 80), e.g. "blackhole 10.244.176.0/26": a later install would see the
  # pod range as taken
  local r; ip -4 route show proto 80 2>/dev/null | while read -r r; do
    # shellcheck disable=SC2086
    ip route del $r proto 80 >/dev/null 2>&1 || true; done
  # Calico copies its CNI plugins next to the kubernetes-cni package's; left there, dpkg cannot remove /opt/cni
  rm -f /opt/cni/bin/calico /opt/cni/bin/calico-ipam /opt/cni/bin/flannel 2>/dev/null || true
  local ipt; for ipt in iptables ip6tables; do   # drop only Kubernetes' and Calico's rules, keep everything else
    command -v "$ipt-save" >/dev/null || continue
    "$ipt-save" | grep -vE 'KUBE-|cali-|cali:|CNI-' | "$ipt-restore" 2>>"$LOG" || warn "$ipt rules not cleaned (a reboot clears them)"
  done
  ok "Kubernetes removed from the host"
}

register_stage calico
stage_calico() {
  local tmp; tmp=$(mktemp -d)
  fetch_pinned "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/operator-crds.yaml" "$CALICO_CRDS_SHA256" "$tmp/crds.yaml"
  fetch_pinned "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/tigera-operator.yaml" "$CALICO_OPERATOR_SHA256" "$tmp/operator.yaml"
  kc apply --server-side --force-conflicts -f "$tmp/crds.yaml" >> "$LOG" || die "Calico CRDs failed"
  kc apply --server-side --force-conflicts -f "$tmp/operator.yaml" >> "$LOG" || die "Tigera operator failed"
  kc -n tigera-operator rollout status deploy/tigera-operator --timeout=300s >> "$LOG" || die "Tigera operator not ready (kubectl -n tigera-operator get pods)"
  export POD_CIDR; render "$K8S_TEMPLATES/calico-installation.yaml" | kc apply -f - >> "$LOG" || die "Calico installation failed"
  rm -rf "$tmp"
  wait_for "Calico running" 600 10 bash -c "kubectl --kubeconfig $KCFG get tigerastatus calico -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' | grep -qx True" \
    || die "Calico is not available (kubectl get tigerastatus; kubectl -n calico-system get pods)"
  local want; want=$(multi_node && nodes_list | wc -l || echo 1)
  wait_for "all $want node(s) Ready" 600 5 bash -c "kubectl --kubeconfig $KCFG get nodes --no-headers | awk '\$2 == \"Ready\" {n++} END {exit !(n == $want)}'" \
    || die "not every node is Ready (kubectl get nodes; kubectl describe node)"
}

register_stage system-nodes
stage_system_nodes() {   # multi-node: the control-plane nodes carry the platform, labelled with Run:ai's system-node role
  multi_node || { ok "single node"; return 0; }
  local name addr role node l=""
  while read -r -u 3 name addr role; do
    [ "$role" = control ] || continue
    node=$(node_name_of "$addr"); [ -n "$node" ] || die "$name ($addr) is not a Kubernetes node"
    kc label node "$node" "$SYSTEM_LABEL=true" --overwrite >> "$LOG" || die "cannot label $node"; l+=" $node"
  done 3< <(nodes_list)
  ok "platform nodes ($SYSTEM_LABEL):$l; GPU nodes run workloads only"
}

register_stage storage
stage_storage() {
  local tmp; tmp=$(mktemp)
  fetch_pinned "https://raw.githubusercontent.com/rancher/local-path-provisioner/$LOCAL_PATH_VERSION/deploy/local-path-storage.yaml" "$LOCAL_PATH_SHA256" "$tmp"
  grep -q '"/opt/local-path-provisioner"' "$tmp" || die "local-path manifest format changed (no default path)"
  mkdir -p "$INSTALL_DIR/volumes"
  sed -e "s|\"/opt/local-path-provisioner\"|\"$INSTALL_DIR/volumes\"|" -e "s|image: docker.io/library/busybox\$|image: $BUSYBOX_IMAGE|" "$tmp"     | kc apply -f - >> "$LOG" || die "local-path storage failed"
  rm -f "$tmp"
  kc annotate storageclass local-path storageclass.kubernetes.io/is-default-class=true --overwrite >> "$LOG"
  kc -n local-path-storage rollout status deploy/local-path-provisioner --timeout=300s >> "$LOG" || die "local-path provisioner not ready"
  ok "default StorageClass local-path, volumes in $INSTALL_DIR/volumes"
}

register_stage longhorn LONGHORN_VERSION
stage_longhorn() {   # three or more control-plane nodes: the platform's data on Longhorn, a copy on each (ADR-021)
  platform_ha || { ok "platform data on local-path ($(multi_node && echo 'fewer than 3 control-plane nodes' || echo 'single node'))"; return 0; }
  local chart=$STATE/charts/longhorn-$LONGHORN_VERSION.tgz n; mkdir -p "$STATE/charts"
  [ -s "$chart" ] || fetch_pinned "https://github.com/longhorn/charts/releases/download/longhorn-$LONGHORN_VERSION/longhorn-$LONGHORN_VERSION.tgz" "$LONGHORN_SHA256" "$chart"
  n=$(control_count); [ "$n" -gt 3 ] && n=3
  export LONGHORN_DATA=$INSTALL_DIR/longhorn LONGHORN_REPLICAS=$n SYSTEM_LABEL
  render "$OIF_HOME/platform/storage/longhorn-values.yaml" > "$STATE/longhorn-values.yaml"
  log "Longhorn $LONGHORN_VERSION on the control-plane nodes (3-5 min)"
  hl upgrade --install longhorn "$chart" -n longhorn-system --create-namespace -f "$STATE/longhorn-values.yaml" --wait --timeout 15m >> "$LOG" 2>&1 \
    || die "Longhorn failed (kubectl -n longhorn-system get pods)"
  wait_for "$(control_count) Longhorn node(s) ready" 600 10 longhorn_nodes_ready \
    || die "Longhorn nodes not ready (kubectl -n longhorn-system get nodes.longhorn.io)"
  # helm returns before Longhorn's driver deployer has made the CSI driver; its sidecars restart until the plugin on
  # their node answers (6-8 min on the reference run)
  wait_for "Longhorn CSI driver ready" 900 10 longhorn_csi_ready \
    || die "Longhorn CSI driver not ready (kubectl -n longhorn-system get pods | grep csi)"
  # a test volume: bound, written by a pod, every replica healthy
  export BUSYBOX_IMAGE; render "$OIF_HOME/platform/storage/longhorn-test.yaml" | kc apply -f - >> "$LOG" || die "Longhorn test could not be created"
  wait_for "test pod writes to a Longhorn volume" 300 5 pod_running oif-longhorn-test writer \
    || die "test pod on a Longhorn volume not running (kubectl -n oif-longhorn-test describe pod writer)"
  local pv; pv=$(kc -n oif-longhorn-test get pvc data -o jsonpath='{.spec.volumeName}')
  wait_for "test volume healthy ($LONGHORN_REPLICAS copies)" 300 5 longhorn_volume_is "$pv" healthy \
    || die "Longhorn test volume not healthy (kubectl -n longhorn-system get volumes.longhorn.io)"
  kc delete namespace oif-longhorn-test --wait=true >> "$LOG" 2>&1 || warn "test namespace oif-longhorn-test not deleted"
  ok "Longhorn $LONGHORN_VERSION: StorageClass longhorn, $LONGHORN_REPLICAS copies of each volume on the control-plane nodes, data in $LONGHORN_DATA"
}
longhorn_nodes_ready() {   # every control-plane node is a ready, schedulable Longhorn node
  [ "$(kc -n longhorn-system get nodes.longhorn.io -o json | python3 -c 'import json, sys
ok = lambda n, t: any(c["type"] == t and c["status"] == "True" for c in n.get("status", {}).get("conditions", []))
print(sum(ok(n, "Ready") and ok(n, "Schedulable") for n in json.load(sys.stdin)["items"]))')" = "$(control_count)" ]; }
longhorn_csi_ready() {   # the CSI plugin on every Longhorn node, and every CSI sidecar deployment, fully ready
  kc -n longhorn-system get ds/longhorn-csi-plugin deploy/csi-attacher deploy/csi-provisioner deploy/csi-resizer deploy/csi-snapshotter -o json 2>/dev/null \
    | python3 -c 'import json, sys
items = json.load(sys.stdin)["items"]
def ready(o):
    s = o.get("status", {})
    if o["kind"] == "DaemonSet": return s.get("desiredNumberScheduled", 0) > 0 and s.get("numberReady") == s["desiredNumberScheduled"]
    return s.get("readyReplicas", 0) == o["spec"].get("replicas", 1)
sys.exit(0 if len(items) == 5 and all(ready(o) for o in items) else 1)'; }
longhorn_volume_is() { [ "$(kc -n longhorn-system get volumes.longhorn.io "$1" -o jsonpath='{.status.robustness}')" = "$2" ]; }   # pv robustness
pod_running() { [ "$(kc -n "$1" get pod "$2" -o jsonpath='{.status.phase}' 2>/dev/null)" = Running ]; }   # namespace pod

register_stage metallb
stage_metallb() {
  local tmp; tmp=$(mktemp)
  fetch_pinned "https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml" "$METALLB_SHA256" "$tmp"
  kc apply -f "$tmp" >> "$LOG" || die "MetalLB failed"; rm -f "$tmp"
  if multi_node; then   # the controller on the platform nodes; the speakers stay on every node
    kc -n metallb-system patch deploy controller --type merge -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"$SYSTEM_LABEL\":\"true\"}}}}}" >> "$LOG" \
      || die "cannot place the MetalLB controller"
  fi
  kc -n metallb-system rollout status deploy/controller --timeout=300s >> "$LOG" || die "MetalLB controller not ready"
  kc -n metallb-system rollout status ds/speaker --timeout=300s >> "$LOG" || die "MetalLB speaker not ready"
  export METALLB_RANGE
  local n=0; until render "$K8S_TEMPLATES/metallb-pool.yaml" | kc apply -f - >> "$LOG" 2>&1; do   # webhook needs a moment
    n=$((n + 1)); [ $n -ge 12 ] && die "MetalLB address pool rejected (kubectl -n metallb-system logs deploy/controller)"; sleep 10; done
  ok "MetalLB pool $METALLB_RANGE"
}

register_stage k8s-verify
stage_k8s_verify() {
  wait_for "all system pods running" 600 10 pods_settled || { kc get pods -A | grep -vE 'Running|Completed'; die "some pods are not running"; }
  export SMOKE_IMAGE=$BUSYBOX_IMAGE
  render "$K8S_TEMPLATES/smoke-test.yaml" | kc apply -f - >> "$LOG" || die "smoke test could not be created"
  wait_for "test volume bound" 300 5 bash -c "kubectl --kubeconfig $KCFG -n oif-smoke get pvc data -o jsonpath='{.status.phase}' | grep -qx Bound" || die "test volume not bound"
  wait_for "test pod running" 300 5 bash -c "kubectl --kubeconfig $KCFG -n oif-smoke get pod web -o jsonpath='{.status.phase}' | grep -qx Running" || die "test pod not running"
  local ip=""; wait_for "LoadBalancer address" 120 5 bash -c "kubectl --kubeconfig $KCFG -n oif-smoke get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}' | grep -q ." \
    && ip=$(kc -n oif-smoke get svc web -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ -n "$ip" ] || die "no LoadBalancer address from MetalLB"
  wait_for "http://$ip answers" 60 3 bash -c "curl -fsS -m 5 http://$ip/ | grep -qx oif-smoke-ok" || die "http://$ip did not answer (MetalLB L2 announcements?)"
  kc delete namespace oif-smoke --wait=true >> "$LOG" 2>&1 || warn "test namespace oif-smoke not deleted"
  ok "Kubernetes ready: $(kc get nodes --no-headers | awk '$2 == "Ready" {n++; s = s " " $1} END {print n " node(s) Ready:" s}'), storage and load balancer tested ($ip)"
}
