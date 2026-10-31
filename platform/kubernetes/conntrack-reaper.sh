#!/bin/bash
# oif (ADR-022): drop the kernel's connection tracking for connections whose Kubernetes endpoint is gone.
# A client connected through a Service keeps a conntrack entry that sends its packets to one pod. When that pod's node
# loses power, nothing ever answers: the client retransmits for about 15 minutes before giving up, even though the
# Service already points to another pod (the database primary after a failover, a second copy of a Run:ai service).
# Every 2 s this compares the redirected connections with the endpoints the NAT rules (kube-proxy, hostPort) send to
# now; an entry whose endpoint is missing in two rounds in a row is deleted. The client's next packet is then routed
# afresh, reaches a live pod, gets a reset, and the client reconnects at once.
set -u

live_targets() {   # every address:port the NAT rules send to now
  iptables-save -t nat 2>/dev/null | grep -o 'DNAT --to-destination [0-9.]*:[0-9]*' | awk '{print $3}' | sort -u; }

stale_entries() {   # $1 live targets (one per line), conntrack -L on stdin: "src dst sport dport endpoint" per stale entry
  awk -v t="$1" '
    BEGIN { n = split(t, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") live[a[i]] = 1 }
    { os = od = osp = odp = rs = rsp = ""; ns = np = 0
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^src=/) { if (++ns == 1) os = substr($i, 5); else if (ns == 2) rs = substr($i, 5) }
        else if ($i ~ /^dst=/ && od == "") od = substr($i, 5)
        else if ($i ~ /^sport=/) { if (++np == 1) osp = substr($i, 7); else if (np == 2) rsp = substr($i, 7) }
        else if ($i ~ /^dport=/ && odp == "") odp = substr($i, 7) }
      # redirected (the reply comes from another address than the one dialled) to an endpoint no rule sends to
      if (rs != "" && rs != od && !((rs ":" rsp) in live)) print os, od, osp, odp, rs ":" rsp }'; }

main() {
  local prev="" now targets line os od osp odp ep
  while :; do
    targets=$(live_targets)
    if [ -n "$targets" ]; then   # no NAT rules at all (kube-proxy not up yet): nothing to judge
      now=$(conntrack -L -p tcp 2>/dev/null | stale_entries "$targets")
      while read -r line; do
        [ -n "$line" ] && grep -qxF "$line" <<< "$prev" || continue
        read -r os od osp odp ep <<< "$line"
        conntrack -D -p tcp --orig-src "$os" --orig-dst "$od" --sport "$osp" --dport "$odp" >/dev/null 2>&1 \
          && echo "dropped $os:$osp -> $od:$odp (endpoint $ep is gone)"
      done <<< "$now"
      prev=$now
    fi
    sleep "${REAP_INTERVAL:-2}"
  done; }

[ "${BASH_SOURCE[0]}" = "$0" ] && main
