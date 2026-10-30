#!/bin/bash
# Acceptance test for T-124 (ADR-017, ADR-021): a control-plane node goes down and the platform keeps working.
# Run on ANOTHER control-plane node, from oif's copy there, after a full install with three control-plane nodes:
#   sudo /var/lib/oif/src/tests/lab/t124-ha.sh cp1
# It waits for that node to go down (power it off; hybrid-gpu-lab host: virsh destroy hl-cp1), then checks the API,
# etcd, Run:ai, workloads and quotas in both vendor pools, the platform's volumes and the dashboards. Pods that only
# an operator can release (a StatefulSet pod without a Longhorn volume on a node that is off) are released with
# Kubernetes' out-of-service taint, as an operator would after confirming the node is off. Then it waits for the node
# to come back (virsh start hl-cp1), removes the taint and checks that every volume has all its copies again.
# Creates and deletes test pods in project team-c's namespace; otherwise only reads, except for that taint.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); OIF_HOME=$ROOT
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
DOWN=${1:-}; [ -n "$DOWN" ] || { echo "usage: sudo $0 NODE   (the Kubernetes node to take down, e.g. cp1)"; exit 2; }
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
for f in "$ROOT"/installer/lib/*.sh "$ROOT"/installer/stages/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
INTERACTIVE=0; TLOG=/dev/null; LOG=/dev/null
[ -f "$KCFG" ] || { echo "run it on a control-plane node ($KCFG not found)"; exit 2; }
[ "$(hostname)" != "$DOWN" ] || { echo "run it on another control-plane node: $DOWN goes down"; exit 2; }
kc get node "$DOWN" >/dev/null 2>&1 || { echo "$DOWN is not a node of this cluster"; exit 2; }

FAILS=0; N=0
check() { N=$((N + 1)); if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }
info() { echo "        $*"; }
PLATFORM_NS="runai-backend runai monitoring haproxy-controller longhorn-system metallb-system"
ready_is() { [ "$(kc get node "$1" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "$2" ]; }
api_ok() { [ "$(kc get --raw /readyz 2>/dev/null)" = ok ]; }
not_ready() {   # the platform's Deployments and StatefulSets that miss ready replicas, one per line
  kc get deploy,statefulset -A -o json | python3 -c '
import json, sys
ns = set(sys.argv[1].split())
for o in json.load(sys.stdin)["items"]:
    m, want = o["metadata"], o["spec"].get("replicas", 1)
    if m["namespace"] in ns and want and o.get("status", {}).get("readyReplicas", 0) < want:
        print(m["namespace"] + "/" + o["kind"].lower() + "/" + m["name"])' "$PLATFORM_NS"; }
platform_ready() { [ -z "$(not_ready)" ]; }
pods_on() { kc get pods -A --field-selector "spec.nodeName=$1" --no-headers 2>/dev/null | awk -v ns=" $PLATFORM_NS " 'index(ns, " " $1 " ")' | wc -l; }
volumes() { kc -n longhorn-system get volumes.longhorn.io -o jsonpath='{range .items[*]}{.status.kubernetesStatus.namespace}/{.status.kubernetesStatus.pvcName} {.status.state} {.status.robustness}{"\n"}{end}'; }
volumes_usable() { ! volumes | awk '$2 == "attached" && $3 == "faulted"' | grep . >/dev/null && [ -n "$(volumes)" ]; }
volumes_healthy() { ! volumes | awk '$2 == "attached" && $3 != "healthy"' | grep . >/dev/null; }
wait_until() { local t=$1 s=$SECONDS; shift; until "$@" >/dev/null 2>&1; do [ $((SECONDS - s)) -ge "$t" ] && return 1; sleep 10; done; }

# Run:ai's address and CA come from the cluster: this node has no oif settings
RUNAI_DOMAIN=$(kc -n runai-backend get ingress -o jsonpath='{.items[0].spec.rules[0].host}')
PKI=$(mktemp -d); trap 'rm -rf "$PKI"' EXIT
kc -n runai-backend get secret runai-ca-cert -o jsonpath='{.data.runai-ca\.pem}' | base64 -d > "$PKI/ca.crt"
ui_ok() { curl -fsS -m 10 --cacert "$PKI/ca.crt" -o /dev/null "https://$RUNAI_DOMAIN/"; }
prom() {   # query: the result's label values "vendor node", one per line, from the cluster Prometheus
  kc get --raw "/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")" \
    | python3 -c 'import json, sys; [print(r["metric"].get("vendor", "-"), r["metric"].get("node", r["metric"].get("Hostname", "-"))) for r in json.load(sys.stdin)["data"]["result"]]'; }
grafana_ok() {   # dashboards oif-fleet and oif-scheduling answer through the ingress
  local pw u; u=$(kc -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-user}' | base64 -d)
  pw=$(kc -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)
  for d in oif-fleet oif-scheduling; do
    curl -fsS -m 10 --cacert "$PKI/ca.crt" -u "$u:$pw" -o /dev/null "https://grafana.$RUNAI_DOMAIN/api/dashboards/uid/$d" || return 1; done; }

echo "T-124 the platform without $DOWN"
check "$DOWN Ready before the test" ready_is "$DOWN" True
check "platform ready before the test" platform_ready
info "$(pods_on "$DOWN") platform pod(s) on $DOWN; API address held by $(kc -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}')"
echo "        power $DOWN off now (hybrid-gpu-lab host: virsh destroy hl-$DOWN); waiting up to 15 min ..."
wait_until 900 ready_is "$DOWN" Unknown || { echo "  FAIL  $DOWN did not go down"; exit 1; }
t0=$SECONDS; echo "        $DOWN is down (NotReady)"

# the control plane does not wait for anything
check "API answers on the shared address" api_ok
check "API address held by another node" bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}')\" != '$DOWN' ]"
check "etcd keeps a majority (writes work)" bash -c "kubectl --kubeconfig $KCFG -n default create configmap oif-t124-write --from-literal=t=1 && kubectl --kubeconfig $KCFG -n default delete configmap oif-t124-write"

# phase A: what comes back without anyone (Kubernetes evicts after 5 min; Longhorn moves pods that hold its volumes)
if wait_until 720 platform_ready; then auto=yes; else auto=no; fi
info "without operator action: $([ $auto = yes ] && echo "platform ready after $((SECONDS - t0)) s" || echo "still waiting after $((SECONDS - t0)) s: $(not_ready | xargs)")"
TAINTED=no
if [ $auto = no ]; then   # phase B: the operator confirms the node is off
  kc taint node "$DOWN" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute --overwrite >/dev/null && TAINTED=yes
  info "out-of-service taint on $DOWN (the operator confirms it is off)"
  wait_until 600 platform_ready
  info "with the taint: $(platform_ready && echo "platform ready after $((SECONDS - t0)) s" || echo "still waiting: $(not_ready | xargs)")"
fi
check "platform ready again without $DOWN" platform_ready
check "no platform pod running on $DOWN" bash -c "! kubectl --kubeconfig $KCFG get pods -A --field-selector spec.nodeName=$DOWN --no-headers | grep -E ' Running ' | grep -E '^($(tr ' ' '|' <<< "$PLATFORM_NS")) ' >/dev/null"
check "platform volumes usable (Longhorn, a copy lost)" volumes_usable
volumes | sed 's/^/        /'
check "Run:ai UI answers (https://$RUNAI_DOMAIN)" ui_ok
check "Run:ai API: log in and keep project team-c (quota 1 GPU per vendor pool)" runai_api project-pools team-c nvidia=1 amd=1

# workloads in both pools, the quota per pool
NS=runai-team-c; export NS CUDA_SAMPLE_IMAGE BUSYBOX_IMAGE
kc -n "$NS" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test --ignore-not-found --wait=true >/dev/null 2>&1
NODE_POOL=nvidia render "$OIF_HOME/platform/runai/quota-test.yaml" | kc apply -f - >/dev/null
NODE_POOL=amd render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >/dev/null
node_of() { kc -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }
phase_of() { kc -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
both_running() { [ "$(phase_of gpu-quota-test) $(phase_of amd-quota-test)" = "Running Running" ]; }
wait_until 300 both_running
NV=$(node_of gpu-quota-test); AM=$(node_of amd-quota-test)
check "NVIDIA workload runs in pool nvidia (${NV:-not placed})" bash -c "[ -n '$NV' ] && [ \"\$(kubectl --kubeconfig $KCFG get node '$NV' -o jsonpath='{.metadata.labels.oif\\.ai/gpu-vendor}')\" = nvidia ]"
check "AMD workload runs in pool amd (${AM:-not placed})" bash -c "[ -n '$AM' ] && [ \"\$(kubectl --kubeconfig $KCFG get node '$AM' -o jsonpath='{.metadata.labels.oif\\.ai/gpu-vendor}')\" = amd ]"
NODE_POOL=nvidia render "$OIF_HOME/platform/runai/quota-test.yaml" | sed 's/name: gpu-quota-test$/name: gpu-quota-test-2/' | kc apply -f - >/dev/null
sleep 45
check "a third workload (second NVIDIA) waits: quota 1 in pool nvidia" bash -c "[ '$(phase_of gpu-quota-test-2)' = Pending ]"
info "waiting reason: $(kc -n "$NS" get events --field-selector involvedObject.name=gpu-quota-test-2 -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1 | cut -c1-120)"
kc -n "$NS" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test --wait=false >/dev/null 2>&1

# the dashboards: both GPU nodes reported, Grafana answers
gpus=$(prom 'count by (vendor, node) (oif:gpu_allocatable)'); sed 's/^/        oif:gpu_allocatable /' <<< "$gpus"
check "Prometheus reports both vendors' GPU nodes" bash -c "grep -q '^nvidia ' <<< '$gpus' && grep -q '^amd ' <<< '$gpus'"
check "Grafana dashboards OIF Fleet and OIF Scheduling answer" grafana_ok

echo "        power $DOWN on again (hybrid-gpu-lab host: virsh start hl-$DOWN); waiting up to 15 min ..."
wait_until 900 ready_is "$DOWN" True; check "$DOWN Ready again" ready_is "$DOWN" True
[ $TAINTED = yes ] && kc taint node "$DOWN" node.kubernetes.io/out-of-service=nodeshutdown:NoExecute- >/dev/null && info "out-of-service taint removed"
wait_until 900 volumes_healthy
check "every platform volume has all its copies again" volumes_healthy
check "platform ready with $DOWN back" wait_until 600 platform_ready

echo
if [ $FAILS = 0 ]; then echo "T-124: PASS ($N checks)"; else echo "T-124: FAIL ($FAILS of $N checks failed)"; fi
[ $FAILS = 0 ]
