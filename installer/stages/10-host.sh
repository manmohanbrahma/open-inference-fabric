# shellcheck shell=bash
# T-102 host preparation: base packages, kernel settings for Kubernetes, swap off.

register_stage host-packages
stage_host_packages() {
  apt_install ca-certificates curl gpg conntrack socat ethtool ipset jq pciutils
  ok "base packages ($(grep -c '^PKG ' "$MANIFEST" || true) recorded for uninstall)"
}

register_stage kernel
stage_kernel() {
  put_file /etc/modules-load.d/90-oif.conf $'# oif: Kubernetes networking\noverlay\nbr_netfilter\n'
  modprobe overlay; modprobe br_netfilter
  put_file /etc/sysctl.d/90-oif.conf $'# oif: Kubernetes networking and many watched files (operators, Grafana)\nnet.ipv4.ip_forward = 1\nnet.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nfs.inotify.max_user_instances = 8192\nfs.inotify.max_user_watches = 1048576\n'
  sysctl -q --system
  if swapon --noheadings | grep . >/dev/null; then
    backup_file /etc/fstab
    swapoff -a
    sed -i -E 's|^([^#].*[[:space:]]swap[[:space:]].*)$|# disabled by oif: \1|' /etc/fstab
    rec "SWAP"; ok "swap off (uninstall turns it back on)"
  fi
  ok "kernel modules overlay, br_netfilter; IP forwarding and bridge filtering on"
}

register_stage storage-host
register_teardown storage-host
stage_storage_host() {   # a control-plane node of an HA platform holds Longhorn replicas (ADR-021): iSCSI, multipath off them
  longhorn_here || { ok "no platform volumes on this node"; return 0; }
  apt_install open-iscsi
  local v; v=$(dpkg-query -W -f '${Version}' open-iscsi)
  case $v in 2.1.12*) die "open-iscsi $v breaks Longhorn volumes (longhorn/longhorn#13733): use 2.1.11, or 2.1.13 and newer" ;; esac
  put_file /etc/modules-load.d/90-oif-longhorn.conf $'# oif: Longhorn volumes are attached over iSCSI\niscsi_tcp\n'
  modprobe iscsi_tcp
  if command -v multipathd >/dev/null; then   # multipathd would claim Longhorn's disks and their mounts would fail
    [ -d /etc/multipath/conf.d ] || rec "DIR /etc/multipath/conf.d"
    put_file /etc/multipath/conf.d/90-oif-longhorn.conf $'# oif: Longhorn volumes (iSCSI disks "IET VIRTUAL-DISK") are not multipath devices\nblacklist {\n  device {\n    vendor "IET"\n    product "VIRTUAL-DISK"\n  }\n}\n'
    systemctl reload multipathd >/dev/null 2>&1 || systemctl restart multipathd >/dev/null 2>&1 || true
  fi
  [ -e /var/lib/longhorn ] || rec "DIR /var/lib/longhorn"   # Longhorn's engine binaries; the replicas go to INSTALL_DIR
  rec "TEARDOWN storage-host"
  ok "Longhorn prerequisites: open-iscsi $v, iscsi_tcp loaded$(command -v multipathd >/dev/null && echo ', Longhorn disks kept out of multipath')"
}
teardown_storage_host() {   # after Kubernetes stopped the pods: Longhorn's iSCSI logins and device nodes
  local t ts; ts=$({ iscsiadm -m node 2>/dev/null || true; } | { grep -o 'iqn\.[^ ,]*longhorn[^ ,]*' || true; } | sort -u)
  for t in $ts; do
    timeout 30 iscsiadm -m node -T "$t" -u >/dev/null 2>&1 || true
    iscsiadm -m node -T "$t" -o delete >/dev/null 2>&1 || true
  done
  rm -rf /dev/longhorn
  ok "Longhorn iSCSI logins ($(wc -w <<< "$ts")) and devices removed"
}
