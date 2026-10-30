# shellcheck shell=bash
# Kubernetes helpers: kubectl and helm against the cluster's admin kubeconfig, templates, pinned downloads.

KCFG=/etc/kubernetes/admin.conf
kc() { kubectl --kubeconfig "$KCFG" "$@"; }
hl() { helm --kubeconfig "$KCFG" "$@"; }

render() {   # template: print it with ${VAR} replaced from the environment (only the variables named in it)
  python3 - "$1" <<'PY'
import os, re, sys
text = open(sys.argv[1], encoding="utf-8").read()
var = re.compile(r"\$\{([A-Z_][A-Z0-9_]*)\}")
missing = sorted({m for m in var.findall(text) if not os.environ.get(m)})
if missing: sys.exit(f"{sys.argv[1]}: not set: {', '.join(missing)}")
sys.stdout.write(var.sub(lambda m: os.environ[m.group(1)], text))
PY
}

fetch_pinned() {   # url sha256 dst: download and verify against the checksum pinned in versions.env
  local tmp; tmp=$(mktemp)
  retry wget -q -O "$tmp" "$1" || { rm -f "$tmp"; die "cannot download $1"; }
  [ "$(sha256sum "$tmp" | cut -c1-64)" = "$2" ] || { rm -f "$tmp"; die "checksum mismatch for $1 (expected $2)"; }
  mv "$tmp" "$3"
}

cidr_free() {   # cidr: no overlap with any address or route on this host
  python3 - "$1" <<'PY'
import ipaddress, subprocess, sys
want = ipaddress.ip_network(sys.argv[1])
nets = set()
for line in subprocess.run(["ip", "-4", "-o", "addr"], capture_output=True, text=True).stdout.splitlines():
    nets.add(ipaddress.ip_network(line.split()[3], strict=False))
for line in subprocess.run(["ip", "-4", "route"], capture_output=True, text=True).stdout.splitlines():
    words = line.split()
    dst = words[1] if words[0] in ("blackhole", "unreachable", "prohibit", "throw", "local", "broadcast", "multicast", "unicast") else words[0]
    if dst != "default":
        nets.add(ipaddress.ip_network(dst if "/" in dst else dst + "/32", strict=False))
clash = [str(n) for n in nets if n.overlaps(want)]
if clash: sys.exit(f"{want} overlaps {', '.join(sorted(clash))}")
PY
}

pick_cidr() {   # candidates...: print the first one that does not overlap the host's networks
  local c; for c in "$@"; do cidr_free "$c" 2>/dev/null && { echo "$c"; return 0; }; done; return 1; }

pods_settled() {   # [namespace]: every pod (in the namespace, or the cluster) Running and ready, or Succeeded
  local scope=(-A) out; [ -n "${1:-}" ] && scope=(-n "$1")
  out=$(kc get pods "${scope[@]}" --no-headers -o 'custom-columns=R:.status.containerStatuses[*].ready,P:.status.phase' 2>/dev/null) || return 1
  [ -n "$out" ] && ! awk '$2=="Succeeded" {next} $2!="Running" || $1 ~ /false/ || $1=="<none>" {bad=1} END {exit !bad}' <<< "$out"; }
