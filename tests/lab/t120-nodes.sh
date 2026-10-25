#!/bin/bash
# Acceptance test for T-120 (ADR-017), run on the first node of a multi-node install after
#   sudo ./oif install --until nodes      (or a full install)
# Read-only, except with --reboot NODE: reboots that node through the cluster key and waits for it.
#   sudo tests/lab/t120-nodes.sh [--reboot NODE]
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 2; }
# shellcheck source=../../versions.env
. "$ROOT/versions.env"
for f in "$ROOT"/installer/lib/*.sh; do
  # shellcheck source=/dev/null
  . "$f"
done
INTERACTIVE=0; TLOG=/dev/null
config_load_saved
REBOOT_NODE=""; [ "${1:-}" = --reboot ] && REBOOT_NODE=${2:?--reboot needs a node name}

FAILS=0; N=0
check() {   # description command...
  N=$((N + 1))
  if "${@:2}" >/dev/null 2>&1; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAILS=$((FAILS + 1)); fi; }

echo "T-120 node list, cluster key and node runner"
check "settings name more than one node (OIF_NODES)" multi_node
check "this host is the first node in the list" v_nodes "$OIF_NODES"
check "cluster key exists, readable by root only" bash -c "[ -f '$CLUSTER_KEY' ] && [ \"\$(stat -c %a '$CLUSTER_KEY')\" = 600 ] && [ \"\$(stat -c %U '$CLUSTER_KEY')\" = root ]"
check "stage 'nodes' finished" test -f "$DONE/nodes"

while read -r -u 3 name addr role; do
  echo "node $name ($addr, $role)"
  check "reachable with the cluster key only (no agent), sudo without a password" node_ok "$addr"
  check "recorded for uninstall (NODE, NODEKEY)" bash -c "grep -qx 'NODE $addr $name' '$MANIFEST' && grep -q '^NODEKEY $addr ' '$MANIFEST'"
  check "oif copied to $NODE_SRC" node_ssh "$addr" "sudo test -x $NODE_SRC/oif"
  for s in "${NODE_STAGES[@]}"; do
    check "node stage $s done" node_ssh "$addr" "sudo test -f /var/lib/oif/done/$s"
  done
  check "only the node settings were sent (no passwords or tokens)" \
    node_ssh "$addr" "sudo cut -d= -f1 /var/lib/oif/settings.conf | sort | tr '\n' ' ' | grep -qx '$(printf '%s\n' "${NODE_SETTINGS[@]}" | sort | tr '\n' ' ')'"
  check "node keeps its own change record" node_ssh "$addr" "sudo test -s /var/lib/oif/manifest"
  if node_ssh "$addr" "grep -qi 0x10de /sys/bus/pci/devices/*/vendor" 2>/dev/null; then
    check "NVIDIA node: driver loaded, nvidia-smi sees the GPU" node_ssh "$addr" "nvidia-smi -L | grep -q GPU"
    check "NVIDIA node: nouveau blocked" node_ssh "$addr" "! lsmod | grep -q '^nouveau '"
  fi
  if [ "$name" = "$REBOOT_NODE" ]; then   # the same reboot-and-wait the node runner does
    boot=$(node_ssh "$addr" cat /proc/sys/kernel/random/boot_id); t0=$SECONDS
    node_ssh "$addr" 'sudo systemctl reboot' >/dev/null 2>&1 || true
    back=no
    while [ $((SECONDS - t0)) -lt 900 ]; do
      b=$(node_ssh "$addr" cat /proc/sys/kernel/random/boot_id 2>/dev/null) && [ -n "$b" ] && [ "$b" != "$boot" ] && { back=yes; break; }
      sleep 10
    done
    echo "        ($name answered again after $((SECONDS - t0)) s)"
    check "comes back after a reboot within 15 min (a VM must restart, not power off)" test $back = yes
  fi
done 3< <(other_nodes)

echo
if [ $FAILS = 0 ]; then echo "T-120: PASS ($N checks)"; else echo "T-120: FAIL ($FAILS of $N checks failed)"; fi
[ $FAILS = 0 ]
