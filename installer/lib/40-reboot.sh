# shellcheck shell=bash
# Reboots: never without consent; the install continues by itself after the reboot.

install_resume_unit() {
  put_file "$RESUME_UNIT" "[Unit]
Description=Continue the Open Inference Fabric install after a reboot
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=$SELF _resume
TimeoutStartSec=0
[Install]
WantedBy=multi-user.target
"
  systemctl daemon-reload; systemctl enable oif-resume.service >/dev/null 2>&1
}

reboot_ask() {   # reason: consent comes from REBOOT_OK (asked with the questions) or from the person at the terminal
  install_resume_unit; warn "a reboot is needed to $1"
  if [ "${REBOOT_OK:-no}" = yes ]; then
    echo "  rebooting in 10 s (agreed at the start); the install continues after the reboot" | tee -a "$TLOG"; sync; sleep 10; systemctl reboot; exit 0
  fi
  echo "  Not rebooting on its own. Reboot when convenient (sudo reboot); the install then continues by itself." | tee -a "$TLOG"
  exit 0
}
