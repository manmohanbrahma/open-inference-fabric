# shellcheck shell=bash
# Host facts and GPU discovery (read-only). Sourced by oif.

AMD_COMPUTE_IDS=${AMD_COMPUTE_IDS:-"7448 744a 7449 745e 744c 7551 74a1 74a5 75a3"}   # W7900/W7800/RX 7900/R9700/MI300-355

valid_ip() { python3 -c "import ipaddress,sys;ipaddress.IPv4Address(sys.argv[1])" "$1" 2>/dev/null; }
host_ip() { ip -4 route get "${1:-1.1.1.1}" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'; }
host_prefix() { ip -4 -o addr show | awk -v ip="$1" '$4 ~ "^"ip"/" {print $4; exit}'; }
user_home() { getent passwd "$1" | cut -d: -f6; }
free_gb() { local d=$1; while [ ! -d "$d" ]; do d=$(dirname "$d"); done; df -BG --output=avail "$d" | tail -1 | tr -dc 0-9; }
largest_fs() { df -BG --output=avail,target -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null \
  | tail -n +2 | sort -n | tail -1 | awk '{print $2}'; }

# ---------------------------------------------------------------- GPUs
pci_ids() { local v d; v=$(<"/sys/bus/pci/devices/$1/vendor"); d=$(<"/sys/bus/pci/devices/$1/device"); echo "${v#0x}:${d#0x}"; }
pci_name() { lspci -vmm -s "$1" 2>/dev/null | awk -F'\t' '/^Device:/{print $2; exit}'; }
drv() { local l; l=$(readlink "/sys/bus/pci/devices/$1/driver" 2>/dev/null) || true; echo "${l##*/}"; }
slot_functions() { local f; for f in "/sys/bus/pci/devices/${1%.*}".*; do echo "${f##*/}"; done; }
amd_compute() { [[ " $AMD_COMPUTE_IDS " == *" $(pci_ids "$1" | cut -d: -f2) "* ]]; }

discover_gpus() {   # NV_BDFS, AMD_BDFS (compute targets), OTHER_BDFS (other AMD GPUs: AMD's device plugin would claim
  # them, so they are isolated), IGNORED_BDFS (other vendors, e.g. the BMC's display chip: never touched)
  NV_BDFS=(); AMD_BDFS=(); OTHER_BDFS=(); IGNORED_BDFS=(); local p b cls
  for p in /sys/bus/pci/devices/*; do
    b=${p##*/}; cls=$(<"$p/class")
    [[ $cls == 0x0300* || $cls == 0x0302* || $cls == 0x0380* || $cls == 0x1200* ]] || continue
    case $(pci_ids "$b") in
      10de:*) NV_BDFS+=("$b") ;;
      1002:*) if amd_compute "$b"; then AMD_BDFS+=("$b"); else OTHER_BDFS+=("$b"); fi ;;
      *) IGNORED_BDFS+=("$b") ;;
    esac
  done
}

gpu_table() {
  discover_gpus; local b
  for b in "${NV_BDFS[@]}";      do printf "  %-12s %-7s %-30s %-9s %s\n" "$b" NVIDIA "$(pci_name "$b")" "$(drv "$b")" "compute"; done
  for b in "${AMD_BDFS[@]}";     do printf "  %-12s %-7s %-30s %-9s %s\n" "$b" AMD "$(pci_name "$b")" "$(drv "$b")" "compute"; done
  for b in "${OTHER_BDFS[@]}";   do printf "  %-12s %-7s %-30s %-9s %s\n" "$b" AMD "$(pci_name "$b")" "$(drv "$b")" "display only (isolate)"; done
  for b in "${IGNORED_BDFS[@]}"; do printf "  %-12s %-7s %-30s %-9s %s\n" "$b" other "$(pci_name "$b")" "$(drv "$b")" "ignored"; done
  [ $(( ${#NV_BDFS[@]} + ${#AMD_BDFS[@]} + ${#OTHER_BDFS[@]} )) -gt 0 ] || echo "  no GPUs found"
}

reachable() {   # url: any HTTP answer counts (401/404 too); fails on DNS, TLS or connection errors
  python3 - "$1" <<'PY' 2>/dev/null
import sys, urllib.request, urllib.error
try: urllib.request.urlopen(urllib.request.Request(sys.argv[1], method="HEAD"), timeout=10)
except urllib.error.HTTPError: pass
PY
}

host_check() {   # read-only: never changes the host
  echo "${c_b}Host${c_0}"
  # shellcheck source=/dev/null
  . /etc/os-release
  echo "  OS        : $PRETTY_NAME, kernel $(uname -r)"
  echo "  CPU       : $(lscpu | awk -F: '/Model name/{gsub(/^ +/,"",$2);print $2; exit}'), $(nproc --all) threads"
  echo "  Memory    : $(free -g | awk '/Mem:/{print $2" GB total, "$7" GB available"}')"
  echo "  Swap      : $(swapon --noheadings --show=NAME 2>/dev/null | paste -sd' ' | sed 's/^$/off/')"
  echo "  IOMMU     : $([ -n "$(ls /sys/kernel/iommu_groups 2>/dev/null)" ] && echo on || echo off)"
  echo "  Secure Boot: $(mokutil --sb-state 2>/dev/null | head -1 || echo unknown)"
  echo "  Largest filesystem: $(largest_fs) ($(free_gb "$(largest_fs)") GB free); /var/lib: $(free_gb /var/lib) GB free"
  echo; echo "${c_b}GPUs${c_0}"; gpu_table
  echo; echo "${c_b}Checks${c_0}"
  local bad=0
  [[ ${ID:-} == ubuntu && ${VERSION_ID:-} =~ ^(22\.04|24\.04|26\.04)$ ]] && ok "Ubuntu $VERSION_ID" || { warn "$PRETTY_NAME: oif is tested on Ubuntu 26.04 (22.04 and 24.04 expected to work)"; bad=1; }
  [ "$(nproc --all)" -ge 16 ] && ok "$(nproc --all) CPU threads" || { warn "$(nproc --all) CPU threads: Run:ai and the platform need about 16"; bad=1; }
  [ "$(free -g | awk '/Mem:/{print $2}')" -ge 64 ] && ok "memory" || { warn "less than 64 GB memory"; bad=1; }
  [ "$(free_gb /var/lib)" -ge 150 ] && ok "/var/lib: $(free_gb /var/lib) GB free" || { warn "/var/lib has $(free_gb /var/lib) GB free; container images need about 150 GB"; bad=1; }
  [ ${#NV_BDFS[@]} -gt 0 ] && ok "${#NV_BDFS[@]} NVIDIA GPU(s)" || warn "no NVIDIA GPU (Project 1.1 needs one)"
  [ ${#AMD_BDFS[@]} -gt 0 ] && ok "${#AMD_BDFS[@]} AMD compute GPU(s)" || warn "no supported AMD compute GPU (needed from Project 1.2)"
  local b; for b in "${NV_BDFS[@]}"; do case $(drv "$b") in
    nvidia) ok "$b on the nvidia driver" ;; nouveau) warn "$b on nouveau: oif install replaces it with the NVIDIA driver (one reboot, asked first)" ;;
    *) warn "$b on driver '$(drv "$b")'" ;; esac; done
  [ ${#OTHER_BDFS[@]} -gt 0 ] && warn "display-only AMD GPU(s) ${OTHER_BDFS[*]}: oif install isolates them with vfio so Kubernetes cannot claim them (one reboot)"
  swapon --noheadings | grep -q . && warn "swap is on: oif install turns it off for Kubernetes (uninstall turns it back on)"
  local u; for u in https://registry.k8s.io https://nvcr.io https://ghcr.io https://huggingface.co https://archive.ubuntu.com; do
    reachable "$u" && ok "reachable: $u" || { warn "cannot reach $u (proxy or firewall?)"; bad=1; }; done
  for u in kubelet containerd docker k3s rke2-server; do
    systemctl is-enabled -q "$u" 2>/dev/null && { warn "$u is already installed and enabled: oif expects a clean host"; bad=1; }; done
  echo; [ $bad = 0 ] && echo "${c_g}Host is ready for oif install.${c_0}" || echo "${c_y}Review the warnings above before oif install.${c_0}"
  return 0
}
