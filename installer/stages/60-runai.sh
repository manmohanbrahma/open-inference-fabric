# shellcheck shell=bash
# T-105 Run:ai on NVIDIA: what Run:ai expects to find (Prometheus, an ingress controller, a domain with TLS),
# then open-source Run:ai (control plane and cluster on this cluster) with its own installer.

RUNAI_CLUSTER_NAME=oif
PKI=$STATE/pki

register_stage prometheus KPS_VERSION
stage_prometheus() {
  local chart=$STATE/charts/kube-prometheus-stack-$KPS_VERSION.tgz pw; mkdir -p "$STATE/charts"
  [ -s "$chart" ] || fetch_pinned "https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-$KPS_VERSION/kube-prometheus-stack-$KPS_VERSION.tgz" "$KPS_SHA256" "$chart"
  kc create namespace monitoring --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  pw=$(mktemp); chmod 600 "$pw"; printf '%s' "$GRAFANA_ADMIN_PASSWORD" > "$pw"   # a file, not a command-line argument
  kc -n monitoring create secret generic grafana-admin --from-literal=admin-user=admin --from-file=admin-password="$pw" \
    --dry-run=client -o yaml | kc apply -f - >> "$LOG"; rm -f "$pw"
  log "kube-prometheus-stack $KPS_VERSION (3-5 min)"
  hl upgrade --install kps "$chart" -n monitoring -f "$OIF_HOME/platform/observability/kps-values.yaml" --wait --timeout 15m >> "$LOG" 2>&1 \
    || die "kube-prometheus-stack failed (kubectl -n monitoring get pods)"
  ok "Prometheus, Grafana and Alertmanager running (namespace monitoring)"
}

register_stage ingress HAPROXY_INGRESS_VERSION
stage_ingress() {
  local chart=$STATE/charts/kubernetes-ingress-$HAPROXY_INGRESS_VERSION.tgz ip; mkdir -p "$STATE/charts"
  [ -s "$chart" ] || fetch_pinned "https://github.com/haproxytech/helm-charts/releases/download/kubernetes-ingress-$HAPROXY_INGRESS_VERSION/kubernetes-ingress-$HAPROXY_INGRESS_VERSION.tgz" "$HAPROXY_INGRESS_SHA256" "$chart"
  export INGRESS_IP; INGRESS_IP=$(first_ip "$METALLB_RANGE")
  render "$OIF_HOME/platform/ingress/haproxy-values.yaml" > "$STATE/haproxy-values.yaml"
  hl upgrade --install haproxy-ingress "$chart" -n haproxy-controller --create-namespace -f "$STATE/haproxy-values.yaml" --wait --timeout 10m >> "$LOG" 2>&1 \
    || die "HAProxy ingress controller failed (kubectl -n haproxy-controller get pods)"
  ip=$(kc -n haproxy-controller get svc haproxy-ingress-kubernetes-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
  [ "$ip" = "$INGRESS_IP" ] || die "ingress got address '$ip', expected $INGRESS_IP (is it free in the MetalLB pool?)"
  ok "HAProxy ingress (class haproxy) on $ip"
}

register_stage pki
stage_pki() {   # a private CA (10 years) and one certificate for the Run:ai domain, its workloads and inference endpoints
  local d; d=$(runai_domain); RUNAI_DOMAIN=$d; save RUNAI_DOMAIN "$d"
  mkdir -p "$PKI"; chmod 700 "$PKI"
  if [ ! -s "$PKI/ca.crt" ]; then
    openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes -keyout "$PKI/ca.key" -out "$PKI/ca.crt" \
      -subj "/O=Open Inference Fabric/CN=oif local CA $(hostname -s | cut -c1-20)" \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>>"$LOG" || die "cannot create the CA"
  fi
  openssl req -newkey rsa:2048 -nodes -keyout "$PKI/tls.key" -out "$PKI/tls.csr" -subj "/CN=$d" 2>>"$LOG"
  printf 'subjectAltName=DNS:%s,DNS:*.%s,DNS:*.inference.%s\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\nkeyUsage=digitalSignature,keyEncipherment\n' \
    "$d" "$d" "$d" > "$PKI/tls.ext"
  openssl x509 -req -in "$PKI/tls.csr" -CA "$PKI/ca.crt" -CAkey "$PKI/ca.key" -CAcreateserial -days 825 -sha256 \
    -extfile "$PKI/tls.ext" -out "$PKI/tls.crt" 2>>"$LOG" || die "cannot sign the certificate"
  chmod 600 "$PKI"/*.key
  openssl verify -CAfile "$PKI/ca.crt" "$PKI/tls.crt" >/dev/null || die "certificate does not verify against the CA"
  backup_file "$UHOME/oif-ca.crt"; install -m 644 -o "$INSTALL_USER" "$PKI/ca.crt" "$UHOME/oif-ca.crt"
  ok "certificate for $d and *.$d (CA for browsers: $UHOME/oif-ca.crt)"
}

register_stage runai-dns
stage_runai_dns() {   # cluster DNS answers the Run:ai domain itself (pods do not depend on external DNS for it)
  export RUNAI_DOMAIN INGRESS_IP; RUNAI_DOMAIN=$(runai_domain); INGRESS_IP=$(first_ip "$METALLB_RANGE")
  local patch dnsip r
  patch=$(BLOCK=$(render "$OIF_HOME/platform/runai/coredns-block.txt") CUR=$(kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}') python3 -c '
import json, os, re
cur = re.sub(r"# BEGIN oif runai-dns.*?# END oif runai-dns\n?", "", os.environ["CUR"], flags=re.S)
print(json.dumps({"data": {"Corefile": os.environ["BLOCK"].rstrip("\n") + "\n" + cur}}))') || die "cannot build the CoreDNS configuration"
  kc -n kube-system patch configmap coredns --type merge -p "$patch" >> "$LOG" || die "CoreDNS configuration rejected"
  kc -n kube-system rollout restart deploy/coredns >> "$LOG"
  kc -n kube-system rollout status deploy/coredns --timeout=180s >> "$LOG" || die "CoreDNS did not restart (kubectl -n kube-system logs deploy/coredns)"
  dnsip=$(kc -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
  # old CoreDNS pods keep answering for a few seconds after the rollout reports done: wait for the new answer
  local n=0; until [ "$(dns_query "$dnsip" "check.$RUNAI_DOMAIN")" = "rcode 0 $INGRESS_IP" ] \
    && [ "$(dns_query "$dnsip" "$RUNAI_DOMAIN")" = "rcode 0 $INGRESS_IP" ]; do
    n=$((n + 1)); [ $n -ge 30 ] && die "cluster DNS answers '$(dns_query "$dnsip" "check.$RUNAI_DOMAIN")' for check.$RUNAI_DOMAIN (expected $INGRESS_IP)"
    sleep 2; done
  ok "cluster DNS: $RUNAI_DOMAIN and *.$RUNAI_DOMAIN -> $INGRESS_IP"
}

register_stage runai RUNAI_VERSION
stage_runai() {
  local bin=$STATE/bin/runai-installer-$RUNAI_VERSION w=$STATE/runai rc=0; mkdir -p "$STATE/bin" "$w"; chmod 700 "$w"
  [ -x "$bin" ] || { fetch_pinned "https://github.com/dsx-ai-factory/run-ai/releases/download/$RUNAI_VERSION/runai-installer-linux-amd64" "$RUNAI_INSTALLER_SHA256" "$bin"; chmod 755 "$bin"; }
  RUNAI_DOMAIN=$(runai_domain)
  export RUNAI_VERSION RUNAI_CLUSTER_NAME RUNAI_DOMAIN RUNAI_TLS_CERT=$PKI/tls.crt RUNAI_TLS_KEY=$PKI/tls.key RUNAI_CA_CERT=$PKI/ca.crt
  render "$OIF_HOME/platform/runai/config.yaml" > "$w/config.yaml"; chmod 600 "$w/config.yaml"
  getent hosts "$RUNAI_DOMAIN" >/dev/null || die "$RUNAI_DOMAIN does not resolve from this host (DNS for sslip.io blocked?)"
  # the installer's own output and logs stay in the root-only state folder; the readable log gets a filtered summary
  log "Run:ai $RUNAI_VERSION preflight checks"
  "$bin" install --config "$w/config.yaml" --kubeconfig "$KCFG" --preflight-only --output text --logs-dir "$w/logs" > "$w/preflight.txt" 2>&1 || rc=$?
  grep -viE 'password|secret|token|key' "$w/preflight.txt" | tail -40 | redact | sed 's/^/    /'
  [ $rc = 0 ] || die "Run:ai preflight failed (sudo less $w/preflight.txt)"
  # a failed earlier attempt leaves its hook jobs behind; a job with the same name would block the next one
  kc get namespace runai >/dev/null 2>&1 && kc -n runai delete jobs --field-selector status.successful=0 --ignore-not-found >> "$LOG" 2>&1
  log "Run:ai $RUNAI_VERSION install: control plane and cluster (15-30 min; sudo tail -f $w/logs/runai-installer.log)"
  "$bin" install --config "$w/config.yaml" --kubeconfig "$KCFG" -y --output text --step-timeout 15m --logs-dir "$w/logs" > "$w/install.txt" 2>&1 || rc=$?
  grep -viE 'password|secret|token|key' "$w/install.txt" | tail -40 | redact | sed 's/^/    /'
  [ $rc = 0 ] || die "Run:ai install failed (sudo less $w/install.txt; sudo less $w/logs/runai-installer.log)"
  ok "Run:ai $RUNAI_VERSION installed"
}

RUNAI_FRACTIONS_MIN_DRIVER=615   # Run:ai 3.0 support matrix: GPU fractions need driver r615 or later
register_stage runai-fractions RUNAI_VERSION
stage_runai_fractions() {   # the fractioning daemons (fractiond, mpsd) only where the driver supports them
  local v; v=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  if [ -n "$v" ] && [ "${v%%.*}" -lt $RUNAI_FRACTIONS_MIN_DRIVER ]; then
    # the chart's CR targets every node with nvidia.com/gpu.present; adding a label no node carries keeps the
    # daemons off (mpsd crash-loops on older drivers). A Run:ai upgrade re-creates the CR, so this stage re-runs.
    fractioning_selector enabled
    wait_for "GPU fractioning daemons removed" 300 5 bash -c \
      "[ -z \"\$(kubectl --kubeconfig $KCFG -n runai get pods --no-headers -l app.kubernetes.io/managed-by=gpu-fractioning 2>/dev/null)\" ]" \
      || die "GPU fractioning daemons still running (kubectl -n runai get pods | grep fractioning)"
    warn "GPU fractions off: driver $v is older than r$RUNAI_FRACTIONS_MIN_DRIVER (whole GPUs, quotas and projects work)"
  else
    fractioning_selector ""
    ok "GPU fractions available (driver $v)"
  fi
}

fractioning_selector() {   # value: re-create the GpuFractioningConfig with oif.ai/gpu-fractions=<value> required ("" = not)
  local cur new; cur=$(kc get gpufractioningconfig default -o json) || die "GpuFractioningConfig default not found"
  new=$(WANT=$1 python3 -c '
import json, os, sys
o = json.load(sys.stdin); want = os.environ["WANT"]
sel = o["spec"].setdefault("nodeSelector", {})
if (sel.get("oif.ai/gpu-fractions") or "") == want: sys.exit(3)          # already as wanted
if want: sel["oif.ai/gpu-fractions"] = want
else: sel.pop("oif.ai/gpu-fractions", None)
m = o["metadata"]; o["metadata"] = {k: m[k] for k in ("name", "labels", "annotations") if k in m}
o.pop("status", None); print(json.dumps(o))' <<< "$cur") || { [ $? = 3 ] && return 0; die "cannot build GpuFractioningConfig"; }
  # nodeSelector is immutable and the object must be named "default" (no dry run possible): replace it, and put the
  # original back if the new one is rejected
  local old; old=$(python3 -c 'import json, sys
o = json.load(sys.stdin); m = o["metadata"]; o["metadata"] = {k: m[k] for k in ("name", "labels", "annotations") if k in m}
o.pop("status", None); print(json.dumps(o))' <<< "$cur")
  kc delete gpufractioningconfig default --wait=true >> "$LOG" || die "cannot delete GpuFractioningConfig"
  if ! kc create -f - <<< "$new" >> "$LOG" 2>&1; then
    kc create -f - <<< "$old" >> "$LOG" 2>&1 || warn "the original GpuFractioningConfig could not be restored either"
    die "new GpuFractioningConfig rejected (see $LOG); the original was restored"
  fi
}

register_stage runai-verify RUNAI_VERSION
stage_runai_verify() {
  local ns code; RUNAI_DOMAIN=$(runai_domain)
  for ns in runai-backend runai; do
    wait_for "Run:ai pods running in $ns" 1800 15 pods_settled "$ns" \
      || { kc -n "$ns" get pods | grep -vE 'Running|Completed' | tee -a "$TLOG"; die "Run:ai pods in $ns are not all running"; }
  done
  code=$(curl -sS -o /dev/null -w '%{http_code}' --cacert "$PKI/ca.crt" -m 20 "https://$RUNAI_DOMAIN/" || true)
  [[ $code =~ ^(200|30[0-9])$ ]] || die "https://$RUNAI_DOMAIN/ answered '$code' (kubectl -n runai-backend get ingress)"
  ok "Run:ai UI answers on https://$RUNAI_DOMAIN (HTTP $code, certificate trusted by the oif CA)"
  echo "  Log in as the generated administrator (shown only to root):" | tee -a "$TLOG"
  echo "    sudo kubectl --kubeconfig $KCFG -n runai-backend get configmap runai-backend-tenants-manager -o jsonpath='{.data.ADMIN_USERNAME}'; echo" | tee -a "$TLOG"
  echo "    sudo kubectl --kubeconfig $KCFG -n runai-backend get secret runai-backend-gen-tenants-manager -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d; echo" | tee -a "$TLOG"
}
