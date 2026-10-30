# shellcheck shell=bash
# Packages: every package oif adds is recorded; uninstall purges only those, never one the OS had before.

pkg_list() { dpkg-query -W -f='${Package}\n' | LC_ALL=C sort -u; }

apt_install() {   # pkg...: install without recommends or upgrades, record what was new
  local before p; before=$(mktemp)
  pkg_list > "$before"; export DEBIAN_FRONTEND=noninteractive
  retry apt-get update -qq || die "apt-get update failed (network or apt sources?)"
  apt-get install -y -qq --no-install-recommends --no-upgrade "$@" >> "$LOG" 2>&1 || die "apt-get install failed: $* (see $LOG)"
  pkg_list | LC_ALL=C comm -13 "$before" - | while read -r p; do rec "PKG $p"; done
  rm -f "$before"
}

safe_purge() {   # purge recorded packages, but never one whose removal would also take a package the OS had before
  local want=() keep=() final=() p extra
  for p in $(awk '$1=="PKG"{print $2}' "$MANIFEST" | sort -u); do dpkg -s "$p" >/dev/null 2>&1 && want+=("$p"); done
  [ ${#want[@]} = 0 ] && return 0
  local set=" ${want[*]} " k; k=$(uname -r)
  for p in "${want[@]}"; do
    # never the kernel this host runs: without its modules nothing can be loaded until a reboot
    case $p in linux-image-$k|linux-image-unsigned-$k|linux-modules-$k|linux-modules-extra-$k)
      keep+=("$p: the running kernel (boot the OS kernel, then run oif uninstall again)"); continue ;; esac
    extra=$({ apt-get -s --allow-change-held-packages purge "$p" 2>/dev/null || true; } | awk '/^Purg /{print $2}' \
      | while read -r x; do [[ $set == *" $x "* ]] || echo "$x"; done | head -3) || true   # head stops reading early: not a failure
    if [ -n "$extra" ]; then keep+=("$p: removing it would also remove $(echo "$extra" | paste -sd' ')"); else final+=("$p"); fi
  done
  if [ "${PLAN:-0}" = 1 ]; then
    echo "  packages to remove (${#final[@]}): ${final[*]}"
    [ ${#keep[@]} = 0 ] || printf '  kept (the OS depends on them): %s\n' "${keep[@]}"
    return 0
  fi
  [ ${#final[@]} -gt 0 ] && { DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq --allow-change-held-packages "${final[@]}" >> "$LOG" 2>&1 \
    || warn "some packages could not be removed (see $LOG)"; }
  ok "removed ${#final[@]} packages oif installed"
  [ ${#keep[@]} = 0 ] || printf '  kept (the OS depends on them): %s\n' "${keep[@]}"
}
