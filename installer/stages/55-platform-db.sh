# shellcheck shell=bash
# ADR-022 The platform's database, highly available: with three or more control-plane nodes a CloudNativePG cluster
# (one PostgreSQL instance per control-plane node, automatic failover) holds Run:ai's and Grafana's data, instead of
# Run:ai's single built-in PostgreSQL, which cannot be replicated. Fewer nodes keep the built-in database.

PG_NS=oif-db
PG_HOST=oif-pg-rw.$PG_NS.svc.cluster.local   # the primary, wherever it runs
RUNAI_DB_USER=runai
RUNAI_DB_SECRET=oif-runai-db                 # in runai-backend, in Run:ai's key names
GRAFANA_DB_SECRET=oif-grafana-db             # in monitoring

register_stage platform-db CNPG_VERSION
stage_platform_db() {
  platform_ha || { ok "Run:ai keeps its own database ($(multi_node && echo 'fewer than 3 control-plane nodes' || echo 'single node'))"; return 0; }
  local chart=$STATE/charts/cloudnative-pg-$CNPG_VERSION.tgz n; mkdir -p "$STATE/charts"
  [ -s "$chart" ] || fetch_pinned "https://github.com/cloudnative-pg/charts/releases/download/cloudnative-pg-v$CNPG_VERSION/cloudnative-pg-$CNPG_VERSION.tgz" "$CNPG_SHA256" "$chart"
  platform_render database/cnpg-values.yaml
  log "CloudNativePG $CNPG_VERSION operator (1-2 min)"
  hl upgrade --install cnpg "$chart" -n cnpg-system --create-namespace -f "$STATE/cnpg-values.yaml" --wait --timeout 10m >> "$LOG" 2>&1 \
    || die "CloudNativePG operator failed (kubectl -n cnpg-system get pods)"
  # the passwords: made once, kept in the cluster's secrets (a re-run reuses them), never in a file or on a command line
  local ns; for ns in "$PG_NS" runai-backend monitoring; do kc create namespace "$ns" --dry-run=client -o yaml | kc apply -f - >> "$LOG"; done
  local su rn gf; su=$(db_password oif-pg-superuser) rn=$(db_password oif-pg-runai) gf=$(db_password oif-pg-grafana)
  db_secret "$PG_NS" oif-pg-superuser kubernetes.io/basic-auth username=postgres "password=$su"
  db_secret "$PG_NS" oif-pg-runai kubernetes.io/basic-auth "username=$RUNAI_DB_USER" "password=$rn"
  db_secret "$PG_NS" oif-pg-grafana kubernetes.io/basic-auth username=grafana "password=$gf"
  db_secret runai-backend "$RUNAI_DB_SECRET" Opaque "password=$rn" "postgres-password=$su"
  db_secret monitoring "$GRAFANA_DB_SECRET" Opaque "password=$gf"
  n=$(control_count); [ "$n" -gt 3 ] && n=3
  export PG_INSTANCES=$n CNPG_PG_IMAGE SYSTEM_LABEL
  render "$OIF_HOME/platform/database/oif-pg.yaml" | kc apply -f - >> "$LOG" 2>&1 || die "database cluster rejected (kubectl -n $PG_NS get cluster)"
  log "PostgreSQL: $n instances, one per control-plane node (3-5 min)"
  wait_for "database cluster healthy ($n instances)" 900 10 pg_ready "$n" \
    || die "database cluster not ready (kubectl -n $PG_NS get clusters.postgresql.cnpg.io oif-pg; kubectl -n $PG_NS get pods)"
  wait_for "database grafana created" 300 5 pg_db_applied || die "database grafana not created (kubectl -n $PG_NS describe database oif-pg-grafana)"
  ok "PostgreSQL $n instances (primary $(kc -n "$PG_NS" get clusters.postgresql.cnpg.io oif-pg -o jsonpath='{.status.currentPrimary}')): databases backend (Run:ai) and grafana, at $PG_HOST"
}
db_password() {   # secret name in the database namespace: its password, or a new random one
  local p; p=$(kc -n "$PG_NS" get secret "$1" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)
  [ -n "$p" ] || p=$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')   # letters, digits, - and _ only
  printf '%s' "$p"; }
db_secret() {   # namespace name type key=value...: create or update, the values through a file
  local ns=$1 name=$2 type=$3 d kv; shift 3; d=$(mktemp -d); chmod 700 "$d"
  local args=(); for kv in "$@"; do printf '%s' "${kv#*=}" > "$d/${kv%%=*}"; args+=(--from-file="${kv%%=*}=$d/${kv%%=*}"); done
  kc -n "$ns" create secret generic "$name" --type="$type" "${args[@]}" --dry-run=client -o yaml | kc apply -f - >> "$LOG" \
    || { rm -rf "$d"; die "secret $ns/$name rejected"; }
  rm -rf "$d"; }
pg_ready() {   # instances: the cluster reports them all ready and healthy
  kc -n "$PG_NS" get clusters.postgresql.cnpg.io oif-pg -o json 2>/dev/null | N=$1 python3 -c 'import json, os, sys
s = json.load(sys.stdin).get("status", {})
sys.exit(0 if s.get("readyInstances") == int(os.environ["N"]) and s.get("phase") == "Cluster in healthy state" else 1)'; }
pg_db_applied() { [ "$(kc -n "$PG_NS" get database oif-pg-grafana -o jsonpath='{.status.applied}' 2>/dev/null)" = true ]; }
