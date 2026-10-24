# shellcheck shell=bash
# Stage preflight: host check and the data folder. Later stages (host, kubernetes, GPUs, Run:ai, ...) follow in
# installer/stages/NN-*.sh and register themselves in order.

register_stage preflight
stage_preflight() {
  host_check
  mkdir -p "$INSTALL_DIR"; rec "DATADIR $INSTALL_DIR"
  ok "data folder $INSTALL_DIR"
}
