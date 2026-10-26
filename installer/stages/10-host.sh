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
