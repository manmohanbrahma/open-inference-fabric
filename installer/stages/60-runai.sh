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

RUNAI_DNS_REV=2   # 2: forward only to the host's DNS servers that answer
register_stage runai-dns RUNAI_DNS_REV
stage_runai_dns() {   # cluster DNS answers the Run:ai domain itself, and forwards only to DNS servers that answer
  export RUNAI_DOMAIN INGRESS_IP; RUNAI_DOMAIN=$(runai_domain); INGRESS_IP=$(first_ip "$METALLB_RANGE")
  local patch dnsip r s answering=""
  # A host DNS server that refuses queries makes pods fail lookups at random (CoreDNS spreads queries over every
  # server in /etc/resolv.conf). Forward only to the servers that answer; keep /etc/resolv.conf if none does.
  for s in $(host_nameservers); do [[ $(dns_query "$s" registry.k8s.io) == "rcode 0 "?* ]] && answering+=" $s"; done
  if [ -n "$answering" ]; then ok "cluster DNS forwards to:$answering"
  else warn "no host DNS server answered a test query: CoreDNS keeps /etc/resolv.conf"; fi
  patch=$(BLOCK=$(render "$OIF_HOME/platform/runai/coredns-block.txt") CUR=$(kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}') FWD=$answering python3 -c '
import json, os, re
cur = re.sub(r"# BEGIN oif runai-dns.*?# END oif runai-dns\n?", "", os.environ["CUR"], flags=re.S)
fwd = os.environ["FWD"].split()
if fwd:   # the main server block forwards to the answering servers instead of /etc/resolv.conf (or an older list)
    cur = re.sub(r"forward \. [^{\n]*\{", "forward . " + " ".join(fwd) + " {", cur, count=1)
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

runai_api() {   # args...: the oif Run:ai client, logged in as the generated administrator (secrets stay in env)
  RUNAI_URL="https://$(runai_domain)" RUNAI_CA="$PKI/ca.crt" \
  RUNAI_USER=$(kc -n runai-backend get configmap runai-backend-tenants-manager -o jsonpath='{.data.ADMIN_USERNAME}') \
  RUNAI_PASSWORD=$(kc -n runai-backend get secret runai-backend-gen-tenants-manager -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d) \
    python3 "$OIF_HOME/installer/tools/runai_api.py" "$@"
}
pod_phase() { kc -n "$1" get pod gpu-quota-test -o jsonpath='{.status.phase}' 2>/dev/null; }

register_stage runai-admin RUNAI_ADMIN_EMAIL   # a new e-mail in the settings runs it again
stage_runai_admin() {   # the owner's administrator account from the settings; the generated test@run.ai stays for oif
  [ -n "${RUNAI_ADMIN_EMAIL:-}" ] || { warn "RUNAI_ADMIN_EMAIL not set: only the generated administrator exists"; return 0; }
  local why out
  why=$(check_runai_password "${RUNAI_ADMIN_PASSWORD:-}") \
    || die "RUNAI_ADMIN_PASSWORD: $why; set a new one with 'sudo ./oif install --reconfigure'"
  out=$(RUNAI_NEW_PASSWORD=$RUNAI_ADMIN_PASSWORD runai_api admin "$RUNAI_ADMIN_EMAIL" 2>&1) || die "Run:ai administrator $RUNAI_ADMIN_EMAIL: $out"
  sed 's/^/    /' <<< "$out" | tee -a "$TLOG"
  ok "log in to Run:ai as $RUNAI_ADMIN_EMAIL with the password from the settings"
}

# T-115: oif's patches to Run:ai (patches/runai/): cluster-sync counts AMD GPUs on nodes that also have NVIDIA GPUs,
# the web UI shows the AMD logo for ROCm images, the operator reports fractions unavailable when no node runs them.
# Each patched component is built from the tagged source in a Job,
# layered onto its stock image, loaded into containerd and switched on. RUNAI_PATCHES=none puts the stock images back.
# The stage reruns when a patch, a build script, a pinned version or RUNAI_PATCHES changes.
runai_patch_rev() { cat "$OIF_HOME"/patches/runai/build-*.sh "$OIF_HOME"/patches/runai/"$RUNAI_VERSION"/*.patch 2>/dev/null \
  | { cat; echo "$GO_BUILD_IMAGE $NODE_BUILD_IMAGE $CRANE_VERSION $CRANE_SHA256 $RUNAI_SOURCE_SHA256 ${RUNAI_PATCHES:-}"; } | sha256sum | cut -c1-12; }
RUNAI_STOCK_REGISTRY=nvcr.io/nvidia/runai-oss
RUNAI_PATCH_REGISTRY=oif.local/runai-oss
# component  build image (variable)  build script  source folder  binary  test packages ("-" = not used)
RUNAI_PATCH_COMPONENTS=(
  "cluster-sync GO_BUILD_IMAGE build-go.sh runai-cluster/cluster/cluster-sync cluster-sync ./pkg/handlers/parsers/"
  "go-operator GO_BUILD_IMAGE build-go.sh runai-cluster/cluster/go-operator go-operator ./pkg/controller-utils/"
  "frontend NODE_BUILD_IMAGE build-frontend.sh - - -")

register_stage runai-patches runai_patch_rev
stage_runai_patches() {
  local c comp bimg script src bin tests
  if [ "${RUNAI_PATCHES:-}" = none ]; then
    for c in "${RUNAI_PATCH_COMPONENTS[@]}"; do runai_patch_use "${c%% *}" stock; done
    ok "Run:ai runs its stock images (RUNAI_PATCHES=none)"; return 0
  fi
  kc create namespace oif-build --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  kc -n oif-build create configmap runai-patch-build $(printf -- '--from-file=%s ' "$OIF_HOME"/patches/runai/build-*.sh) \
    --dry-run=client -o yaml | kc apply -f - >> "$LOG"
  kc -n oif-build create configmap runai-patches --from-file="$OIF_HOME/patches/runai/$RUNAI_VERSION/" --dry-run=client -o yaml \
    | kc apply -f - >> "$LOG"
  for c in "${RUNAI_PATCH_COMPONENTS[@]}"; do read -r comp bimg script src bin tests <<< "$c"
    if ! ls "$OIF_HOME/patches/runai/$RUNAI_VERSION"/*"$comp"*.patch >/dev/null 2>&1; then
      runai_patch_use "$comp" stock; continue; fi
    BUILD_SCRIPT=$script SRC_DIR=$src BINARY=$bin TEST_PKGS=$tests runai_patch_build "$comp" "${!bimg}"
    runai_patch_use "$comp" patched
  done
  wait_for "Run:ai counts every GPU of the node" 300 15 runai_nodes_total_gpus_ok || warn "Run:ai still counts fewer GPUs than the node offers"
  runai_api nodes | sed 's/^/    /' | tee -a "$TLOG"
}
runai_patch_build() {   # component build-image (env BUILD_SCRIPT SRC_DIR BINARY TEST_PKGS): Job -> image tarball -> containerd
  local comp=$1 out=$STATE/build/runai img=$RUNAI_PATCH_REGISTRY/$1:$RUNAI_VERSION-oif1
  mkdir -p "$out"; rm -f "$out/$comp.tar"
  kc -n oif-build delete job "runai-patch-$comp" --ignore-not-found --wait=true >> "$LOG" 2>&1
  COMPONENT=$comp BUILD_IMAGE=$2 BASE_IMAGE=$RUNAI_STOCK_REGISTRY/$comp:$RUNAI_VERSION NEW_IMAGE=$img RUNAI_PATCH_OUT=$out \
    RUNAI_VERSION=$RUNAI_VERSION RUNAI_SOURCE_SHA256=$RUNAI_SOURCE_SHA256 CRANE_VERSION=$CRANE_VERSION CRANE_SHA256=$CRANE_SHA256 \
    render "$OIF_HOME/platform/runai/patch-build-job.yaml" | kc apply -f - >> "$LOG" || die "build Job for $comp rejected"
  log "building Run:ai $comp with $(cd "$OIF_HOME/patches/runai/$RUNAI_VERSION" && ls ./*"$comp"*.patch | sed 's|./||' | paste -sd' ') (5-20 min)"
  wait_for "$comp built" 2400 15 bash -c \
    "kubectl --kubeconfig $KCFG -n oif-build get job runai-patch-$comp -o jsonpath='{.status.conditions[*].type}' | grep -qE 'Complete|Failed'" || true
  kc -n oif-build logs "job/runai-patch-$comp" 2>&1 | grep -E '^(==|ok|FAIL|---| *Tests|.*passed|.*failed)' | sed 's/^/    /' | tee -a "$TLOG"
  [ "$(kc -n oif-build get job "runai-patch-$comp" -o jsonpath='{.status.succeeded}')" = 1 ] && [ -s "$out/$comp.tar" ] \
    || die "Run:ai $comp build failed (kubectl -n oif-build logs job/runai-patch-$comp)"
  ctr -n k8s.io images import "$out/$comp.tar" >> "$LOG" 2>&1 || die "cannot import the patched $comp image into containerd"
  ctr -n k8s.io images ls -q | grep -qxF "$img" || die "image $img not found after import"
  ok "patched image $img loaded into containerd"
}
runai_patch_use() {   # component stock|patched: point Run:ai at the image and wait for the rollout
  local comp=$1 reg=$RUNAI_STOCK_REGISTRY tag=$RUNAI_VERSION ns=runai deploy=$1
  [ "$2" = patched ] && { reg=$RUNAI_PATCH_REGISTRY; tag=$RUNAI_VERSION-oif1; }
  case $comp in
    cluster-sync)   # the Run:ai operator owns this deployment: set the image in its RunaiConfig
      if [ "$2" = patched ]; then
        kc -n runai patch runaiconfig runai --type merge -p "{\"spec\":{\"cluster-sync\":{\"image\":{\"registry\":\"$reg\",\"name\":\"$comp\",\"tag\":\"$tag\",\"pullPolicy\":\"IfNotPresent\"}}}}" >> "$LOG" \
          || die "RunaiConfig rejected the $comp image"
      else
        kc -n runai patch runaiconfig runai --type json -p '[{"op":"remove","path":"/spec/cluster-sync/image"}]' >> "$LOG" 2>&1 || true
      fi ;;
    frontend)       # plain Helm deployments: a later helm upgrade of the Run:ai charts puts the stock image back
      ns=runai-backend deploy=runai-backend-frontend
      runai_patch_set_image "$ns" "$deploy" frontend "$reg/$comp:$tag" ;;
    go-operator)
      deploy=runai-operator
      runai_patch_set_image "$ns" "$deploy" runai-go-operator "$reg/$comp:$tag" ;;
  esac
  wait_for "Run:ai $comp runs the $2 image" 300 10 bash -c \
    "kubectl --kubeconfig $KCFG -n $ns get deploy $deploy -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -qxF '$reg/$comp:$tag' && kubectl --kubeconfig $KCFG -n $ns rollout status deploy/$deploy --timeout=10s" \
    || die "$comp did not roll out the $2 image (kubectl -n $ns describe deploy $deploy)"
}
runai_patch_set_image() {   # namespace deployment container image: set the image; a local image is never pulled
  local ns=$1 dep=$2 ctr=$3 img=$4 policy stock
  # remember the stock pull policy once, so switching back to the stock image restores it
  stock=$(kc -n "$ns" get deploy "$dep" -o jsonpath='{.metadata.annotations.oif\.ai/stock-pull-policy}')
  if [ -z "$stock" ]; then
    stock=$(kc -n "$ns" get deploy "$dep" -o jsonpath="{.spec.template.spec.containers[?(@.name=='$ctr')].imagePullPolicy}")
    kc -n "$ns" annotate deploy "$dep" "oif.ai/stock-pull-policy=${stock:-IfNotPresent}" >> "$LOG"
  fi
  policy=IfNotPresent; [[ $img == "$RUNAI_STOCK_REGISTRY"/* ]] && policy=${stock:-IfNotPresent}
  kc -n "$ns" patch deploy "$dep" --type strategic \
    -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"$ctr\",\"image\":\"$img\",\"imagePullPolicy\":\"$policy\"}]}}}}" >> "$LOG" \
    || die "cannot set the image of $ns/$dep"
}
runai_nodes_total_gpus_ok() {   # every node's GPU count in Run:ai equals its nvidia.com/gpu + amd.com/gpu
  local want got; want=$(kc get nodes -o json | python3 -c 'import json,sys; print(sum(int(n["status"]["allocatable"].get(r,0)) for n in json.load(sys.stdin)["items"] for r in ("nvidia.com/gpu","amd.com/gpu")))')
  got=$(runai_api nodes | awk '{s+=$NF} END {print s+0}'); [ "$want" = "$got" ]
}

register_stage runai-quota
stage_runai_quota() {   # T-105 checkpoint: team-a (quota 1 GPU) runs; team-b (quota 0) waits even on a free GPU (over-quota is off by default)
  local a b reason
  runai_api check | sed 's/^/    cluster: /' | tee -a "$TLOG"
  a=$(runai_api project team-a 1 1) || die "project team-a: $a"
  b=$(runai_api project team-b 0 0) || die "project team-b: $b"
  ok "projects team-a (1 GPU, namespace $a) and team-b (0 GPU, namespace $b)"
  export CUDA_SAMPLE_IMAGE
  kc -n "$a" delete pod gpu-quota-test --ignore-not-found --wait=true >/dev/null 2>&1; kc -n "$b" delete pod gpu-quota-test --ignore-not-found --wait=true >/dev/null 2>&1
  # 1. team-b alone, with the GPU free: the quota alone must keep it waiting
  NS=$b render "$OIF_HOME/platform/runai/quota-test.yaml" | kc apply -f - >> "$LOG" || die "test pod for team-b rejected"
  sleep 45
  [ "$(pod_phase "$b")" = Pending ] || die "team-b's GPU pod is '$(pod_phase "$b")' although its quota is 0 (quota not enforced)"
  reason=$(kc -n "$b" get events --field-selector involvedObject.name=gpu-quota-test -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | tail -1)
  ok "team-b (quota 0) waits while the GPU is free: ${reason:-pending}"
  # 2. team-a: its quota covers one GPU, it must run
  NS=$a render "$OIF_HOME/platform/runai/quota-test.yaml" | kc apply -f - >> "$LOG" || die "test pod for team-a rejected"
  wait_for "team-a (quota 1) gets the GPU" 300 5 bash -c "[ \"\$(kubectl --kubeconfig $KCFG -n $a get pod gpu-quota-test -o jsonpath='{.status.phase}')\" = Running ]" \
    || die "team-a's GPU pod did not start (kubectl -n $a describe pod gpu-quota-test)"
  [ "$(pod_phase "$b")" = Pending ] || die "team-b's pod left Pending ($(pod_phase "$b"))"
  ok "team-a runs on $(kc -n "$a" logs gpu-quota-test 2>/dev/null | head -1 | cut -d'(' -f1); team-b still waits"
  kc -n "$a" delete pod gpu-quota-test --wait=true >> "$LOG" 2>&1; kc -n "$b" delete pod gpu-quota-test --wait=true >> "$LOG" 2>&1
  ok "quota test passed; test pods removed (projects team-a and team-b kept)"
}
