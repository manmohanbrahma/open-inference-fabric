# shellcheck shell=bash
# T-106/T-112/T-114 observability: oif:* recording rules for both GPU vendors, the Fleet and Scheduling dashboards,
# and Grafana on https://grafana.<runai-domain>. Kubernetes objects only, in namespace monitoring.

OBS_DIR=$OIF_HOME/platform/observability
# the stages rerun whenever the rules, dashboards or ingress change
OBS_REV=$(cat "$OBS_DIR"/rules/oif-gpu.rules.yaml "$OBS_DIR"/dashboards/*.json "$OBS_DIR"/grafana-ingress.yaml 2>/dev/null | sha256sum | cut -c1-12)

prom_query() {   # PromQL -> "labels value" lines, from the cluster Prometheus
  local ip; ip=$(kc -n monitoring get svc kps-kube-prometheus-stack-prometheus -o jsonpath='{.spec.clusterIP}')
  curl -fsS -m 20 "http://$ip:9090/api/v1/query" --data-urlencode "query=$1" | python3 -c '
import json, sys
for r in json.load(sys.stdin)["data"]["result"]:
    print(",".join(f"{k}={v}" for k, v in sorted(r["metric"].items())), r["value"][1])'
}

register_stage observability OBS_REV
stage_observability() {
  export GRAFANA_HOST; GRAFANA_HOST=grafana.$(runai_domain)
  { printf 'apiVersion: monitoring.coreos.com/v1\nkind: PrometheusRule\nmetadata:\n  name: oif-gpu\n  namespace: monitoring\n  labels:\n    app.kubernetes.io/managed-by: oif\nspec:\n'
    grep -v '^#' "$OBS_DIR/rules/oif-gpu.rules.yaml" | sed 's/^/  /'; } | kc apply -f - >> "$LOG" || die "recording rules rejected (kubectl -n monitoring get prometheusrule oif-gpu)"
  ok "recording rules oif:gpu_*, oif:node_*, oif:project_* loaded into Prometheus"
  kc -n monitoring create configmap oif-dashboards --from-file="$OBS_DIR/dashboards" --dry-run=client -o yaml \
    | kc label --local -f - grafana_dashboard=1 app.kubernetes.io/managed-by=oif -o yaml | kc apply --server-side --force-conflicts -f - >> "$LOG" \
    || die "dashboards configmap rejected"
  ok "dashboards OIF Fleet and OIF Scheduling handed to Grafana"
  kc -n monitoring create secret tls oif-tls --cert="$PKI/tls.crt" --key="$PKI/tls.key" --dry-run=client -o yaml | kc apply -f - >> "$LOG" \
    || die "TLS secret for Grafana rejected"
  render "$OBS_DIR/grafana-ingress.yaml" | kc apply -f - >> "$LOG" || die "Grafana ingress rejected"
  ok "Grafana ingress for https://$GRAFANA_HOST"
}

OIF_GPU_SERIES="util_ratio mem_used_bytes mem_total_bytes power_watts temp_celsius sm_clock_hz"
vendors_of() { prom_query "count by (vendor) ($1)" | sed -E 's/^vendor=([a-z]+) .*/\1/' | sort | xargs; }
has_allocatable() { [ -n "$(vendors_of 'oif:gpu_allocatable > 0')" ]; }
all_series_cover() {   # vendors: every oif:gpu_* series has exactly these vendors
  local m; for m in $OIF_GPU_SERIES; do [ "$(vendors_of "oif:gpu_$m")" = "$1" ] || return 1; done; }
gpu_summary() {   # one line per GPU: model, utilisation, memory, power, temperature
  local ip; ip=$(kc -n monitoring get svc kps-kube-prometheus-stack-prometheus -o jsonpath='{.spec.clusterIP}')
  python3 - "$ip" <<'PY'
import json, sys, urllib.parse, urllib.request
def q(e):
    u = f"http://{sys.argv[1]}:9090/api/v1/query?" + urllib.parse.urlencode({"query": e})
    return {(r["metric"]["vendor"], r["metric"]["model"], r["metric"]["gpu"]): float(r["value"][1])
            for r in json.load(urllib.request.urlopen(u, timeout=20))["data"]["result"]}
util, used, total, power, temp = (q(f"oif:gpu_{m}") for m in ("util_ratio", "mem_used_bytes", "mem_total_bytes", "power_watts", "temp_celsius"))
for k in sorted(util):
    print(f"{k[0]} {k[1]} (gpu {k[2]}): util {util[k]:.0%}, memory {used.get(k, 0) / 2**30:.1f} of {total.get(k, 0) / 2**30:.1f} GiB, "
          f"{power.get(k, 0):.0f} W, {temp.get(k, 0):.0f} °C")
PY
}

register_stage observability-verify OBS_REV
stage_observability_verify() {
  local host ip vendors m netrc code
  host=grafana.$(runai_domain); ip=$(first_ip "$METALLB_RANGE")
  # rules are evaluated every 15-30 s after they are loaded
  wait_for "GPU vendors recorded (oif:gpu_allocatable)" 120 10 has_allocatable \
    || die "no oif:gpu_allocatable series (kubectl -n monitoring get prometheusrule oif-gpu; is kube-state-metrics running?)"
  vendors=$(vendors_of 'oif:gpu_allocatable > 0')
  wait_for "every oif:gpu_* series covers: $vendors" 180 10 all_series_cover "$vendors" || {
    for m in $OIF_GPU_SERIES; do echo "    oif:gpu_$m: $(vendors_of "oif:gpu_$m")" | tee -a "$TLOG"; done
    die "some oif:gpu_* series miss a vendor (docs/guides/07-observability.md, troubleshooting)"; }
  gpu_summary | sed 's/^/    /' | tee -a "$TLOG"
  code=$(curl -s -o /dev/null -w '%{http_code}' -m 20 --cacert "$PKI/ca.crt" --resolve "$host:443:$ip" "https://$host/api/health")
  [ "$code" = 200 ] || die "https://$host/api/health answered '$code' (kubectl -n monitoring describe ingress oif-grafana)"
  netrc=$(mktemp); chmod 600 "$netrc"; printf 'machine %s login admin password %s\n' "$host" "$GRAFANA_ADMIN_PASSWORD" > "$netrc"
  for m in oif-fleet oif-scheduling; do
    wait_for "Grafana dashboard $m" 120 10 curl -fsS -m 20 --netrc-file "$netrc" --cacert "$PKI/ca.crt" --resolve "$host:443:$ip" "https://$host/api/dashboards/uid/$m" \
      || { rm -f "$netrc"; die "Grafana has no dashboard $m (kubectl -n monitoring logs deploy/kps-grafana -c grafana-sc-dashboard)"; }
  done
  rm -f "$netrc"
  ok "Grafana answers on https://$host (CA: $UHOME/oif-ca.crt) with dashboards OIF Fleet and OIF Scheduling (user admin)"
}
