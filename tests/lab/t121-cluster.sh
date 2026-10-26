#!/bin/bash
# Acceptance test for T-121 (ADR-017), run on the first node after  sudo ./oif install --until k8s-verify  (or later).
# Read-only, except with --failover: takes kube-vip off the node that holds the API address, checks that another
# control-plane node takes the address and the API keeps answering, then puts kube-vip back.
#   sudo tests/lab/t121-cluster.sh [--failover]
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
for f in "$ROOT"/installer/lib/*.sh "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
INTERACTIVE=0; TLOG=/dev/null
config_load_saved
FAILOVER=no; [ "${1:-}" = --failover ] && FAILOVER=yes

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
nodes_ready() { [ "$(kc get nodes --no-headers | awk '$2 == "Ready"' | wc -l)" = "$1" ]; }
role_count() { [ "$(kc get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)" = "$1" ]; }
api_at() { curl -fsk -m 5 "https://$1:6443/readyz" | grep -qx ok; }
static_pods_running() { [ "$(kc -n kube-system get pods --no-headers | awk -v p="^$1-" '$1 ~ p && $3 == "Running"' | wc -l)" = "$2" ]; }
holder() { kc -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'; }

NN=$(nodes_list | wc -l); NC=$(nodes_list | awk '$3 == "control"' | wc -l); VIP=${OIF_API_VIP:-}
echo "T-121 cluster across $NN nodes ($NC control plane)"
check "every node Ready ($NN)" nodes_ready "$NN"
check "$NC control-plane nodes" role_count "$NC"
check "no node tainted against workloads (the platform runs on the control plane too)" \
  bash -c "! kubectl --kubeconfig $KCFG get nodes -o jsonpath='{.items[*].spec.taints[*].effect}' | grep -qE 'NoSchedule|NoExecute'"
check "one etcd member per control-plane node" static_pods_running etcd "$NC"
check "one API server per control-plane node" static_pods_running kube-apiserver "$NC"
check "no join tokens left" bash -c "[ -z \"\$(kubeadm token list --kubeconfig $KCFG 2>/dev/null | awk 'NR>1')\" ]"
check "no uploaded control-plane certificates left" bash -c "! kubectl --kubeconfig $KCFG -n kube-system get secret kubeadm-certs"
check "kubeconfig points at the API endpoint $(api_endpoint)" grep -q "server: https://$(api_endpoint):6443" "$KCFG"
if [ -n "$VIP" ]; then
  check "API answers on the shared address $VIP" api_at "$VIP"
  check "one kube-vip per control-plane node" static_pods_running kube-vip "$NC"
  h=$(holder); echo "        (API address held by $h)"
  check "a control-plane node holds the API address" test -n "$h"
  if [ $FAILOVER = yes ] && [ -n "$h" ]; then
    addr=$(nodes_list | awk -v n="$h" '$1 == n {print $2}')
    move="mv /etc/kubernetes/manifests/kube-vip.yaml /etc/kubernetes/kube-vip.yaml.off"
    back="mv /etc/kubernetes/kube-vip.yaml.off /etc/kubernetes/manifests/kube-vip.yaml"
    if [ "$addr" = "$HOST_IP" ]; then run_on() { bash -c "$1"; }; else run_on() { node_ssh "$addr" "sudo bash -c '$1'"; }; fi
    run_on "$move"; t0=$SECONDS; new=""
    while [ $((SECONDS - t0)) -lt 120 ]; do new=$(holder 2>/dev/null); [ -n "$new" ] && [ "$new" != "$h" ] && api_at "$VIP" && break; sleep 2; done
    echo "        (after taking kube-vip off $h: address held by ${new:-nobody} after $((SECONDS - t0)) s)"
    check "another control-plane node takes the API address" bash -c "[ -n '$new' ] && [ '$new' != '$h' ]"
    check "API keeps answering on $VIP" api_at "$VIP"
    run_on "$back"
    check "kube-vip back on $h" wait_for "kube-vip on $h" 120 5 static_pods_running kube-vip "$NC"
  fi
fi

echo
if [ $FAILS = 0 ]; then echo "T-121: PASS ($N checks)"; else echo "T-121: FAIL ($FAILS of $N checks failed)"; fi
[ $FAILS = 0 ]
