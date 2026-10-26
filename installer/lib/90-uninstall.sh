# shellcheck shell=bash
# status, plan and uninstall: replay the manifest newest first, back to the OS default.

TEARDOWNS=()                                      # names registered by stages; teardown_<name> is called by uninstall
register_teardown() { TEARDOWNS+=("$1"); }

status() {
  echo "oif $OIF_VERSION, state in $STATE"
  [ -d "$STATE" ] || { echo "Nothing installed by oif on this host."; return 0; }
  [ -f "$CONF" ] && echo "Host ${HOST_IP:-?}, data in ${INSTALL_DIR:-?}, MetalLB ${METALLB_RANGE:-?}"
  local s; echo "Stages:"
  for s in "${STAGES[@]}"; do if done_ "$s"; then echo "  [x] $s"; else echo "  [ ] $s"; fi; done
  if multi_node; then local name addr role; echo "Nodes (this host first):"
    while read -r -u 3 name addr role; do
      if [ "$name" = "$(nodes_list | head -1 | cut -d' ' -f1)" ]; then echo "  $name $addr $role: this host"
      elif [ -f "$CLUSTER_KEY" ] && node_ok "$addr"; then echo "  $name $addr $role: reachable with the cluster key"
      else echo "  $name $addr $role: not reachable with the cluster key"; fi
    done 3< <(nodes_list); fi
  if [ -s "$MANIFEST" ]; then echo "Recorded host changes:"; grep -v '^PKG ' "$MANIFEST" | sed 's/^/  /'
    echo "  + $(grep -c '^PKG ' "$MANIFEST" || true) packages"; fi
  systemctl is-active -q oif-install 2>/dev/null && echo "An install job is running: sudo tail -f $LOG"
  return 0
}

plan() {   # read-only preview of uninstall
  [ -s "$MANIFEST" ] || { echo "Nothing recorded: oif has not changed this host."; return 0; }
  echo "Read-only preview of 'oif uninstall' (newest first):"
  tac "$MANIFEST" | grep -v '^PKG ' | describe_records | sed 's/^/  /'
  PLAN=1 safe_purge
}

describe_records() {   # stdin: manifest lines -> what uninstall does with each
  local kind rest
  while read -r kind rest; do case $kind in
    FILE) echo "delete file $rest" ;;  DIR|DATADIR) echo "delete folder $rest" ;;
    RESTORE) echo "restore ${rest#* } from its backup" ;;  BLOCK) echo "remove oif block '${rest#* }' from ${rest%% *}" ;;
    LINE) echo "remove a line from ${rest%% *}" ;;  SWAP) echo "re-enable swap" ;;  GROUP) echo "remove user from group: $rest" ;;
    SERVICE) echo "stop and disable $rest" ;;  ENABLED) echo "disable $rest" ;;  INITRAMFS) echo "rebuild the boot image" ;;
    TEARDOWN) echo "tear down: $rest" ;;  NODE) echo "uninstall node ${rest#* } (${rest%% *}) to its OS default" ;;
    NODEKEY) echo "remove oif's cluster key from ${rest%% *}" ;;  ADMINKEY) echo "remove your SSH key oif added on ${rest%% *}" ;;
    *) echo "$kind $rest" ;;
  esac; done; }

uninstall() {
  local yes=no; [ "${1:-}" = --yes ] && yes=yes
  [ -s "$MANIFEST" ] || { echo "Nothing recorded: oif has not changed this host."; return 0; }
  echo "${c_b}Uninstall${c_0} returns this host to its OS default: it reverses every change below and removes the"
  echo "packages oif installed (never one the OS had before) and the data folder ${INSTALL_DIR:-}."
  tac "$MANIFEST" | grep -v '^PKG ' | describe_records | sed 's/^/   /'
  echo "   ... and $(grep -c '^PKG ' "$MANIFEST" || true) packages"
  local reboot=no
  if [ $yes = no ]; then
    [ "$(ask "Type 'wipe' to continue")" = wipe ] || { echo "aborted"; exit 1; }
    yesno "Reboot automatically when done (unloads removed drivers, clears network rules)" y && reboot=yes
  fi
  printf 'UN_REBOOT=%s\n' "$reboot" > "$STATE/uninstall.conf"
  : > "$UNINSTALL_LOG"; systemctl reset-failed oif-uninstall >/dev/null 2>&1 || true
  systemd-run -q --unit oif-uninstall --collect "$SELF" _uninstall-worker || die "could not start the uninstall job"
  echo "Uninstall running as a background job (survives a dropped SSH session). Follow it with: sudo tail -f $UNINSTALL_LOG"
  follow_job oif-uninstall "$UNINSTALL_LOG"
}

uninstall_run() {
  local UN_REBOOT=no
  # shellcheck source=/dev/null
  [ -f "$STATE/uninstall.conf" ] && . "$STATE/uninstall.conf"
  log "oif uninstall"
  systemctl disable --now oif-install oif-resume >/dev/null 2>&1 || true
  replay_manifest
  safe_purge
  [ -d /run/systemd/system ] && systemctl daemon-reload
  rm -rf "$STATE"; rm -f /var/log/oif-install.log
  echo "Uninstall complete. This log stays at $UNINSTALL_LOG."
  if [ "$UN_REBOOT" = yes ]; then echo "Rebooting in 10 s (as agreed)."; sleep 10; systemctl reboot
  else echo "Reboot when convenient (sudo reboot) to unload removed drivers and clear network rules."; fi
}

replay_manifest() {   # reverse every recorded change, newest first; package removal is separate (safe_purge)
  local kind rest t redo=no datadirs=()
  local i; for (( i=${#TEARDOWNS[@]}-1; i>=0; i-- )); do t=${TEARDOWNS[i]}   # later layers first (Kubernetes before containerd)
    recorded "TEARDOWN $t" && { log "teardown: $t"; "teardown_${t//-/_}"; }; done
  while read -r -u 3 kind rest; do   # records on fd 3: a command in the loop cannot read them away
    case $kind in
      SERVICE)  systemctl disable --now "$rest" >/dev/null 2>&1 || true; ok "stopped $rest" ;;
      ENABLED)  systemctl disable "$rest" >/dev/null 2>&1 || true ;;
      BLOCK)    local bf=${rest%% *} bt=${rest#* }
                if [ "$bf" = /etc/fstab ]; then sed -n "\|^# BEGIN $MARK $bt\$|,\|^# END $MARK $bt\$|p" "$bf" | awk '$1 !~ /^#/ {print $2}' \
                  | sort -r | xargs -r -n1 umount -l 2>/dev/null || true; fi
                if [ -f "$bf" ]; then sed -i "\|^# BEGIN $MARK $bt\$|,\|^# END $MARK $bt\$|d" "$bf"; fi ;;
      LINE)     local lf=${rest%% *} ll=${rest#* }
                if [ -f "$lf" ]; then grep -vxF -- "$ll" "$lf" > "$lf.oif.tmp" || true; cat "$lf.oif.tmp" > "$lf"; rm -f "$lf.oif.tmp"; fi ;;
      SWAP)     sed -i -E 's/^# disabled by oif: //' /etc/fstab; swapon -a 2>/dev/null || true; ok "swap re-enabled" ;;
      RESTORE)  local rb=${rest%% *} rd=${rest#* }; if [ -f "$rb" ]; then cp -p "$rb" "$rd"; fi ;;
      FILE)     rm -f -- "$rest" ;;
      DIR|DATADIR) datadirs+=("$rest") ;;
      GROUP)    gpasswd -d "${rest% *}" "${rest#* }" >/dev/null 2>&1 || true ;;
      INITRAMFS) redo=yes ;;
      NODE)     node_uninstall "${rest%% *}" ;;   # another node of the cluster: its own record, replayed there
      ADMINKEY) node_ssh "${rest%% *}" "$(authorized_del "${rest#* }")" >/dev/null 2>&1 || warn "${rest%% *}: admin key not removed" ;;
      NODEKEY)  OIF_NODE_USER=${rest#* } node_ssh "${rest%% *}" "$(authorized_del "$(cat "$CLUSTER_KEY.pub")")" >/dev/null 2>&1                   && ok "cluster key removed from ${rest%% *}" || warn "${rest%% *}: cluster key not removed (remove the oif-cluster line from authorized_keys)" ;;
      PKG|TEARDOWN) ;;
      *)        warn "unknown manifest record: $kind $rest" ;;
    esac
  done 3< <(tac "$MANIFEST")
  if [ $redo = yes ]; then update-initramfs -u -k "$(uname -r)" >/dev/null 2>&1; ok "boot image rebuilt"; fi
  local d; for d in "${datadirs[@]}"; do   # never delete through a mount that is still attached
    [ -n "$d" ] && [ "$d" != / ] && [ -e "$d" ] || continue
    # grep reads all of findmnt: with -q it would stop at the first match and pipefail could report "no mount"
    if findmnt -rn -o TARGET | grep "^$d\(/\|$\)" >/dev/null; then warn "$d still has a mount under it - left in place"; continue; fi
    rm -rf --one-file-system -- "$d"; ok "removed $d"; done
  return 0
}
