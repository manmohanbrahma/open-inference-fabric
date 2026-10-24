# shellcheck shell=bash
# T-102 container runtime: containerd from the Ubuntu archive, systemd cgroups, images and layers in the data folder
# (model-serving images are tens of GB each; the root disk is kept free).

register_stage containerd
register_teardown containerd
stage_containerd() {
  local d; for d in /var/lib/containerd /opt/containerd /run/containerd; do [ -e "$d" ] || rec "DIR $d"; done
  rec "TEARDOWN containerd"
  apt_install containerd
  mkdir -p "$INSTALL_DIR/containerd"
  local cfg; cfg=$(containerd config default) || die "containerd config default failed"
  cfg=$(printf '%s\n' "$cfg" | sed -E "s|^root = .*|root = '$INSTALL_DIR/containerd'|; s|SystemdCgroup = false|SystemdCgroup = true|")
  grep -q 'SystemdCgroup = true' <<< "$cfg" \
    || cfg=$(printf '%s\n' "$cfg" | sed -E "/runtimes\.runc\.options\]\$/a\\            SystemdCgroup = true")
  grep -q "^root = '$INSTALL_DIR/containerd'" <<< "$cfg" || die "could not set the containerd data folder (config format changed?)"
  grep -q 'SystemdCgroup = true' <<< "$cfg" || die "could not enable systemd cgroups in the containerd config (config format changed?)"
  put_file /etc/containerd/config.toml "# oif: generated from 'containerd config default'; data in $INSTALL_DIR/containerd
$cfg
"
  systemctl enable containerd >/dev/null 2>&1; systemctl restart containerd
  wait_for "containerd running" 60 2 ctr version || die "containerd did not start (journalctl -u containerd)"
  ok "containerd $(containerd --version | awk '{print $3}'), data in $INSTALL_DIR/containerd"
}

teardown_containerd() {   # stop containers and detach their mounts before the data folder is deleted
  systemctl disable --now containerd >/dev/null 2>&1 || true
  pkill -f containerd-shim 2>/dev/null || true; sleep 2
  local t; findmnt -rn -o TARGET | grep -E "^(/run/containerd|/var/lib/containerd|${INSTALL_DIR:-/nonexistent}/containerd)(/|$)" | sort -r \
    | while read -r t; do umount "$t" 2>/dev/null || umount -l "$t" 2>/dev/null || true; done
  ok "containerd stopped"
}
