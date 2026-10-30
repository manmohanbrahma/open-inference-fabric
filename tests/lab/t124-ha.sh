#!/bin/bash
# Acceptance test for T-124 (ADR-017, ADR-021, ADR-022): a control-plane node goes down and the platform keeps working
# from its other copies, with nobody acting.
# Run on ANOTHER control-plane node, from oif's copy there, after a full install with three control-plane nodes:
#   sudo /var/lib/oif/src/tests/lab/t124-ha.sh cp1
# It waits for that node to go down (power it off; hybrid-gpu-lab host: virsh destroy hl-cp1). From the power-off on it
# probes the Run:ai UI, Grafana and the Kubernetes API every 5 s and fails if any is away longer than HA_MAX (90 s).
# While the node is off it checks the API, etcd, the database failover, Run:ai, new workloads and quotas in both vendor
# pools and the dashboards. Then it waits for the node to come back (virsh start hl-cp1) and checks that every copy and
# volume is complete again. Creates and deletes test pods in project team-c's namespace; otherwise only reads.
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

HA_MAX=${HA_MAX:-90}   # seconds users may lose the UI or the dashboards (ADR-022): detection of the dead node, then failover
serving() {   # every platform Deployment and StatefulSet has at least one ready copy (the node that is off holds the rest)
  kc get deploy,statefulset -A -o json | python3 -c '
import json, sys
ns = set(sys.argv[1].split())
bad = [o["metadata"]["namespace"] + "/" + o["metadata"]["name"] for o in json.load(sys.stdin)["items"]
       if o["metadata"]["namespace"] in ns and o["spec"].get("replicas", 1) and not o.get("status", {}).get("readyReplicas")]
print(" ".join(bad)); sys.exit(1 if bad else 0)' "$PLATFORM_NS"; }
pg() { kc -n oif-db get cluster oif-pg -o jsonpath="{.status.$1}" 2>/dev/null; }
pg_moved() {   # the database primary runs on another node and at least two instances are ready
  local p n; p=$(pg currentPrimary); [ -n "$p" ] || return 1
  n=$(kc -n oif-db get pod "$p" -o jsonpath='{.spec.nodeName}' 2>/dev/null)
  [ -n "$n" ] && [ "$n" != "$DOWN" ] && [ "$(pg readyInstances)" -ge 2 ]; }
pg_complete() { [ "$(pg readyInstances)" = "$(kc -n oif-db get cluster oif-pg -o jsonpath='{.spec.instances}')" ]; }
probe() {   # every 5 s until told to stop: "seconds ui grafana api" (1 = answered)
  local t0=$SECONDS; while [ -f "$PKI/probing" ]; do
    echo "$((SECONDS - t0)) $(ui_ok >/dev/null 2>&1 && echo 1 || echo 0) $(grafana_ok >/dev/null 2>&1 && echo 1 || echo 0) $(api_ok && echo 1 || echo 0)"
    sleep 5; done; }
longest_gap() {   # column: the longest run of failed probes, in seconds (first failure to the next success)
  awk -v c="$1" '{ if ($c == 0) { if (s == "") s = $1 } else if (s != "") { g = $1 - s; if (g > m) m = g; s = "" } }
    END { if (s != "") { g = $1 - s + 5; if (g > m) m = g }; print m + 0 }' "$PKI/probe.txt"; }
vendor_of() { kc get node "$1" -o jsonpath='{.metadata.labels.oif\.ai/gpu-vendor}' 2>/dev/null; }

echo "T-124 the platform without $DOWN"
check "$DOWN Ready before the test" ready_is "$DOWN" True
check "platform ready before the test" platform_ready
info "$(pods_on "$DOWN") platform pod(s) on $DOWN; API address held by $(kc -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}'); database primary $(pg currentPrimary)"
touch "$PKI/probing"; probe > "$PKI/probe.txt" & PROBE=$!
echo "        power $DOWN off now (hybrid-gpu-lab host: virsh destroy hl-$DOWN); waiting up to 15 min ..."
wait_until 900 ready_is "$DOWN" Unknown || { rm -f "$PKI/probing"; echo "  FAIL  $DOWN did not go down"; exit 1; }
t0=$SECONDS; echo "        $DOWN is down (NotReady)"

# the control plane does not wait for anything
check "API answers on the shared address" api_ok
check "API address held by another node" bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}')\" != '$DOWN' ]"
check "etcd keeps a majority (writes work)" bash -c "kubectl --kubeconfig $KCFG -n default create configmap oif-t124-write --from-literal=t=1 && kubectl --kubeconfig $KCFG -n default delete configmap oif-t124-write"

# the platform keeps serving from its other copies: nobody acts, no taint
wait_until 180 serving
info "$(serving >/dev/null && echo "every platform service serving $((SECONDS - t0)) s after NotReady" || echo "not serving after $((SECONDS - t0)) s: $(serving)")"
check "every platform service has a ready copy without $DOWN (no operator action)" serving
wait_until 120 pg_moved
check "database primary on another node, at least 2 instances ready" pg_moved
info "database primary now $(pg currentPrimary), $(pg readyInstances) instance(s) ready"
check "platform volumes usable (Longhorn, a copy lost)" volumes_usable
check "Run:ai UI answers (https://$RUNAI_DOMAIN)" ui_ok
check "Run:ai API: log in and keep project team-c (quota 1 GPU per vendor pool)" runai_api project-pools team-c nvidia=1 amd=1

# new workloads in both pools are scheduled, the quota per pool holds
NS=runai-team-c; export NS CUDA_SAMPLE_IMAGE BUSYBOX_IMAGE
kc -n "$NS" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test --ignore-not-found --wait=true >/dev/null 2>&1
NODE_POOL=nvidia render "$OIF_HOME/platform/runai/quota-test.yaml" | kc apply -f - >/dev/null
NODE_POOL=amd render "$OIF_HOME/platform/runai/quota-test-amd.yaml" | kc apply -f - >/dev/null
node_of() { kc -n "$NS" get pod "$1" -o jsonpath='{.spec.nodeName}' 2>/dev/null; }
phase_of() { kc -n "$NS" get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
both_running() { [ "$(phase_of gpu-quota-test) $(phase_of amd-quota-test)" = "Running Running" ]; }
wait_until 300 both_running
NV=$(node_of gpu-quota-test); AM=$(node_of amd-quota-test)
check "NVIDIA workload runs in pool nvidia (${NV:-not placed})" bash -c "[ -n '$NV' ] && [ '$(vendor_of "$NV")' = nvidia ]"
check "AMD workload runs in pool amd (${AM:-not placed})" bash -c "[ -n '$AM' ] && [ '$(vendor_of "$AM")' = amd ]"
NODE_POOL=nvidia render "$OIF_HOME/platform/runai/quota-test.yaml" | sed 's/name: gpu-quota-test$/name: gpu-quota-test-2/' | kc apply -f - >/dev/null
sleep 45
check "a third workload (second NVIDIA) waits: quota 1 in pool nvidia" bash -c "[ '$(phase_of gpu-quota-test-2)' = Pending ]"
info "waiting reason: $(kc -n "$NS" get events --field-selector involvedObject.name=gpu-quota-test-2 -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1 | cut -c1-120)"
kc -n "$NS" delete pod gpu-quota-test gpu-quota-test-2 amd-quota-test --wait=false >/dev/null 2>&1

# the dashboards: both GPU nodes reported, Grafana answers
gpus=$(prom 'count by (vendor, node) (oif:gpu_allocatable)'); sed 's/^/        oif:gpu_allocatable /' <<< "$gpus"
check "Prometheus reports both vendors' GPU nodes" bash -c "grep -q '^nvidia ' <<< '$gpus' && grep -q '^amd ' <<< '$gpus'"
check "Grafana dashboards OIF Fleet and OIF Scheduling answer" grafana_ok

# what users saw: the longest time each answer was missing, from the power-off on
rm -f "$PKI/probing"; wait "$PROBE" 2>/dev/null
UI_GAP=$(longest_gap 2) GF_GAP=$(longest_gap 3) API_GAP=$(longest_gap 4)
info "longest outage seen by users: Run:ai UI ${UI_GAP} s, Grafana ${GF_GAP} s, Kubernetes API ${API_GAP} s (probe every 5 s; limit ${HA_MAX} s)"
check "Run:ai UI never away longer than ${HA_MAX} s" bash -c "[ $UI_GAP -le $HA_MAX ]"
check "Grafana never away longer than ${HA_MAX} s" bash -c "[ $GF_GAP -le $HA_MAX ]"
check "Kubernetes API never away longer than ${HA_MAX} s" bash -c "[ $API_GAP -le $HA_MAX ]"

echo "        power $DOWN on again (hybrid-gpu-lab host: virsh start hl-$DOWN); waiting up to 15 min ..."
wait_until 900 ready_is "$DOWN" True; check "$DOWN Ready again" ready_is "$DOWN" True
wait_until 900 volumes_healthy
check "every platform volume has all its copies again" volumes_healthy
check "platform ready with $DOWN back (every copy)" wait_until 900 platform_ready
check "database back to all its instances" wait_until 600 pg_complete

echo
if [ $FAILS = 0 ]; then echo "T-124: PASS ($N checks)"; else echo "T-124: FAIL ($FAILS of $N checks failed)"; fi
[ $FAILS = 0 ]
