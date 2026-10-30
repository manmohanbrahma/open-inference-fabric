#!/bin/bash
# T-107: is the host back to its OS default after 'oif uninstall'? Read-only, no sudo needed.
# Lists every oif trace it finds: packages, files, services, kernel settings, network leftovers, swap,
# data folder, GPU drivers. Exit 0 when none is left, 1 otherwise.
#   tests/host/verify-clean.sh [INSTALL_DIR]        (default: INSTALL_DIR from .env)
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
INSTALL_DIR=${1:-$(sed -n 's/^INSTALL_DIR=\([^ #]*\).*/\1/p' .env 2>/dev/null)}
left=0
trace() { echo "  [left] $*"; left=$((left + 1)); }
clean() { echo "  [ok]   $*"; }
info() { echo "  [info] $*"; }

echo "Packages"
pk=$(dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 ~ /^.i/ {print $2}' \
  | grep -E '^(kubelet|kubeadm|kubectl|cri-tools|kubernetes-cni|containerd|runc|nvidia-|libnvidia-|linux-modules-nvidia-|xserver-xorg-video-nvidia)' | xargs)
[ -z "$pk" ] && clean "no Kubernetes, containerd or NVIDIA packages" || trace "packages: $pk"
info "base tools oif may have added (kept when the OS had them): $(dpkg-query -W -f '${Package} ' conntrack socat ethtool ipset jq 2>/dev/null)"

echo "Files and folders"; n=$left
for p in /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni/net.d /var/lib/cni /var/lib/calico /run/calico \
  /etc/containerd/config.toml /etc/containerd/conf.d /var/lib/containerd /opt/containerd /etc/crictl.yaml \
  /etc/apt/sources.list.d/oif-kubernetes.list /etc/apt/keyrings/oif-kubernetes.gpg \
  /etc/modprobe.d/90-oif-nouveau.conf /etc/modprobe.d/90-oif-vfio.conf /etc/modules-load.d/90-oif.conf \
  /etc/modules-load.d/90-oif-vfio.conf /etc/sysctl.d/90-oif.conf /etc/systemd/system/oif-resume.service \
  /usr/local/bin/helm /usr/local/nvidia /etc/cdi /var/run/cdi /opt/local-path-provisioner /opt/cni \
  /var/lib/amd-metrics-exporter /var/run/exporter /var/log/oif-install.log "$HOME/.kube/config" "$HOME/oif-ca.crt" \
  /var/lib/longhorn /dev/longhorn /etc/modules-load.d/90-oif-longhorn.conf /etc/multipath/conf.d/90-oif-longhorn.conf \n  /.cache/helm /root/.cache/helm; do
  [ -e "$p" ] && trace "$p"
done
sudo -n test -e /var/lib/oif 2>/dev/null && trace /var/lib/oif   # root-only; checked when sudo needs no password
[ -n "$INSTALL_DIR" ] && [ -e "$INSTALL_DIR" ] && trace "data folder $INSTALL_DIR"
grep -q 'disabled by oif' /etc/fstab && trace "/etc/fstab: swap line still commented out by oif"
[ "$left" = "$n" ] && clean "no oif files"

echo "Services"; n=$left
for u in kubelet containerd oif-install oif-resume; do
  s=$(systemctl is-enabled "$u" 2>/dev/null); a=$(systemctl is-active "$u" 2>/dev/null)
  case "$s$a" in *enabled*|active*) trace "service $u: $s, $a" ;; esac
done
echo "Kernel and network"
swapon --show=NAME --noheadings | grep -q . && clean "swap on: $(swapon --show=NAME --noheadings | xargs)" \
  || { grep -qE '^[^#].*\sswap\s' /etc/fstab && trace "swap is in /etc/fstab but off (a reboot or 'swapon -a' turns it on)" || info "no swap configured"; }
for m in br_netfilter vfio_pci; do lsmod | grep -q "^$m " && info "module $m loaded (unloads at the next reboot)"; done
ifs=$(ip -o link show | awk -F': ' '{print $2}' | cut -d@ -f1 | grep -E '^(cali|vxlan\.calico|tunl0|kube-ipvs0|cni0|flannel)')
[ -n "$ifs" ] && trace "$(wc -l <<< "$ifs") Kubernetes network interfaces ($(head -3 <<< "$ifs" | xargs) ...)"
va=$(ip -o -4 addr show | awk '$2 != "lo" && $4 ~ /\/32$/ {print $4 " on " $2}')
[ -n "$va" ] && trace "address left by kube-vip (the cluster's API address): $(xargs <<< "$va")"
rt=$(ip -4 route show proto 80 2>/dev/null)
[ -n "$rt" ] && trace "$(wc -l <<< "$rt") Calico route(s) left ($(head -1 <<< "$rt"))"
ses=(/sys/class/iscsi_session/*); [ -e "${ses[0]}" ] && trace "${#ses[@]} iSCSI session(s) still open (Longhorn volumes): ${ses[*]##*/}"
[ "$left" = "$n" ] && clean "no Kubernetes services, network interfaces or swap changes"
info "firewall rules need root to read: sudo iptables-save | grep -cE 'KUBE-|cali-' should print 0"

echo "GPUs (driver per PCI address)"
for d in /sys/bus/pci/devices/*; do
  c=$(cat "$d/class"); case $c in 0x0300*|0x0302*|0x0380*) ;; *) continue ;; esac
  v=$(cat "$d/vendor"); drv=$(basename "$(readlink "$d/driver" 2>/dev/null)" 2>/dev/null)
  name=$(lspci -s "${d##*/}" 2>/dev/null | cut -d' ' -f2- | cut -c1-70)
  case "$v:$drv" in
    0x10de:nvidia) trace "${d##*/} $name: still on nvidia (the OS default is nouveau)" ;;
    *:vfio-pci)   trace "${d##*/} $name: still on vfio-pci (isolation not undone; a reboot is needed after uninstall)" ;;
    *)            clean "${d##*/} $name: ${drv:-no driver}" ;;
  esac
done

echo
if [ "$left" = 0 ]; then echo "Host is clean: no oif traces."; exit 0; fi
echo "$left oif trace(s) left."; exit 1
