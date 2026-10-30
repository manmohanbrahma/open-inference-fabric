# shellcheck shell=bash
# T-102 GPUs on the host: NVIDIA driver from the Ubuntu archive (replaces nouveau), AMD display cards isolated with
# vfio-pci, one reboot (asked first), then a check that both took effect. AMD compute GPUs are not touched here.

nv_targets() { discover_gpus; if [ -n "${NVIDIA_GPUS:-}" ]; then echo "${NVIDIA_GPUS//,/ }"; else echo "${NV_BDFS[*]}"; fi; }
nv_driver_ok() { nvidia-smi -L >/dev/null 2>&1; }
iso_list() { echo "${ISOLATE_GPUS//,/ }"; }
iso_ok() { local b f; for b in $(iso_list); do for f in $(slot_functions "$b"); do [ "$(drv "$f")" = vfio-pci ] || return 1; done; done; }

register_stage nvidia-driver
stage_nvidia_driver() {
  [ -n "$(nv_targets)" ] || { warn "no NVIDIA GPU: driver skipped"; return 0; }
  if nv_driver_ok; then ok "NVIDIA driver already loaded: $(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)"; return 0; fi
  local br=$NVIDIA_DRIVER_BRANCH
  [ "${br%%-*}" -ge "$NVIDIA_DRIVER_MIN" ] || die "NVIDIA_DRIVER_BRANCH $br is older than $NVIDIA_DRIVER_MIN"
  log "installing the NVIDIA $br driver (headless, open kernel modules, prebuilt for kernel $(uname -r))"
  # the modules built for the running kernel: the -generic package follows the newest kernel in the archive and would
  # install that kernel too, which the node then boots and uninstall later removes from under it
  local mods; mods="linux-modules-nvidia-$br-open-$(uname -r)"
  if ! apt-cache show "$mods" >/dev/null 2>&1; then
    mods="linux-modules-nvidia-$br-open-generic"
    warn "no prebuilt NVIDIA modules for kernel $(uname -r): $mods brings the newest kernel too (uninstall keeps whichever kernel runs)"
  fi
  apt_install "nvidia-headless-no-dkms-$br-open" "$mods" "nvidia-utils-$br" "nvidia-compute-utils-$br"
  put_file /etc/modprobe.d/90-oif-nouveau.conf $'# oif: the NVIDIA driver replaces nouveau\nblacklist nouveau\noptions nouveau modeset=0\n'
  rec "INITRAMFS"; update-initramfs -u -k "$(uname -r)" >/dev/null
  ok "NVIDIA $br driver installed; it loads after the reboot"
}

# AMD compute GPUs run on the kernel's own amdgpu driver; it needs the GPU firmware files, which minimal images (cloud
# images, e.g. a lab VM) leave out. A full Ubuntu install has them, so there this stage changes nothing.
amd_gpu_up() { local b; for b in $(amd_targets); do [ "$(drv "$b")" = amdgpu ] || return 1; done; [ -e /dev/kfd ]; }
register_stage amd-firmware
stage_amd_firmware() {
  [ -n "$(amd_targets)" ] || { ok "no AMD compute GPU"; return 0; }
  if amd_gpu_up; then ok "AMD GPU $(amd_targets) on amdgpu, /dev/kfd present"; return 0; fi
  if apt-cache show linux-firmware-amd-graphics >/dev/null 2>&1; then apt_install linux-firmware-amd-graphics; else apt_install linux-firmware; fi
  ok "AMD GPU firmware installed"
  # amdgpu loaded but holding no device (it failed without firmware): load it again now; otherwise a reboot starts it.
  # lsmod is read whole: an awk that exits at the first match cuts lsmod off, and pipefail then reads that as failure.
  local users; users=$(lsmod | awk '$1 == "amdgpu" {print $3}')
  if [ -z "$users" ] || [ "$users" = 0 ]; then
    { modprobe -r amdgpu 2>/dev/null || true; } && modprobe amdgpu && wait_for "AMD GPU started by amdgpu" 60 3 amd_gpu_up || true
  fi
  amd_gpu_up || reboot_ask "start the AMD GPU with its firmware"
}

register_stage gpu-isolation
stage_gpu_isolation() {
  [ -n "$(iso_list)" ] || { ok "no GPUs to isolate"; return 0; }
  if iso_ok; then ok "already on vfio-pci: $(iso_list)"; return 0; fi
  [ -n "$(ls /sys/kernel/iommu_groups 2>/dev/null)" ] || die "IOMMU is off: enable it in the BIOS (AMD-Vi or VT-d) to isolate $(iso_list)"
  local b f ids=""
  for b in $(iso_list); do for f in $(slot_functions "$b"); do ids="${ids:+$ids,}$(pci_ids "$f")"; done; done
  ids=$(echo "$ids" | tr ',' '\n' | awk '!s[$0]++' | paste -sd,)
  local p mine   # vfio-pci binds by device id: no other device may share one
  mine=" $(for b in $(iso_list); do slot_functions "$b"; done | paste -sd' ') "
  for p in "$PCI_ROOT"/*; do
    [[ $mine == *" ${p##*/} "* ]] && continue
    [[ ",$ids," == *",$(pci_ids "${p##*/}"),"* ]] && die "${p##*/} has the same device id as a GPU to isolate; vfio-pci would take it too"
  done
  # vfio-pci claims these device ids at boot, before amdgpu and the HDMI audio driver
  put_file /etc/modprobe.d/90-oif-vfio.conf "# oif: GPU(s) $(iso_list) kept away from Kubernetes
options vfio-pci ids=$ids
softdep amdgpu pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
"
  put_file /etc/modules-load.d/90-oif-vfio.conf $'vfio\nvfio_iommu_type1\nvfio_pci\n'
  rec "INITRAMFS"; update-initramfs -u -k "$(uname -r)" >/dev/null
  ok "vfio-pci set for device ids $ids; it takes effect after the reboot"
}

register_stage reboot
stage_reboot() {   # one reboot for the driver and the isolation; never a second one for the same reason
  local why=() b
  [ -n "$(nv_targets)" ] && ! nv_driver_ok && why+=("load the NVIDIA driver instead of nouveau")
  iso_ok || why+=("bind $(iso_list) to vfio-pci")
  [ -n "$(amd_targets)" ] && ! amd_gpu_up && why+=("start the AMD GPU with its firmware")
  [ ${#why[@]} = 0 ] && { ok "no reboot needed"; return 0; }
  if [ -f "$DONE/reboot-asked" ] && [ "$(cat "$DONE/reboot-asked")" != "$(cat /proc/sys/kernel/random/boot_id)" ]; then
    for b in $(nv_targets); do warn "$b: driver '$(drv "$b")' (lsmod | grep -E 'nvidia|nouveau'; journalctl -k | grep -i nvidia)"; done
    die "still needed after the reboot: $(printf '%s; ' "${why[@]}")not rebooting again"
  fi
  cat /proc/sys/kernel/random/boot_id > "$DONE/reboot-asked"
  local msg; msg=$(printf '%s; ' "${why[@]}"); reboot_ask "${msg%; }"
}

register_stage host-verify
stage_host_verify() {
  local b v
  if [ -n "$(nv_targets)" ]; then
    v=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -1)
    [ "${v%%.*}" -ge "$NVIDIA_DRIVER_MIN" ] || die "NVIDIA driver $v is older than $NVIDIA_DRIVER_MIN"
    for b in $(nv_targets); do [ "$(drv "$b")" = nvidia ] || die "$b is on driver '$(drv "$b")', not nvidia"; done
    ok "NVIDIA driver $v: $(nvidia-smi --query-gpu=name --format=csv,noheader | paste -sd, -)"
  fi
  if [ -n "$(amd_targets)" ]; then
    amd_gpu_up || die "AMD GPU $(amd_targets) not started by amdgpu (sudo dmesg | grep -i amdgpu)"
    ok "AMD GPU $(amd_targets) on amdgpu, /dev/kfd present"
  fi
  iso_ok || die "not on vfio-pci: $(iso_list) (lspci -nnk -s $(iso_list | cut -d' ' -f1))"
  [ -n "$(iso_list)" ] && ok "isolated on vfio-pci: $(iso_list)"
  swapon --noheadings | grep . >/dev/null && die "swap is on again (check /etc/fstab and systemd swap units)"
  ok "swap off"
  systemctl is-active -q containerd || die "containerd is not running (journalctl -u containerd)"
  ok "containerd running"
}
