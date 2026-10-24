# shellcheck shell=bash
# Settings: read from .env (never executed), validated, missing values asked, saved to $CONF (mode 600).

CONFIG_KEYS=(HOST_IP METALLB_RANGE INSTALL_DIR NVIDIA_GPUS AMD_GPUS ISOLATE_GPUS
             HF_TOKEN RUNAI_DOMAIN RUNAI_ADMIN_EMAIL RUNAI_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD MODEL_ID)

env_parse() {   # file: print KEY<TAB>VALUE for the known keys; values are data, never evaluated
  python3 - "$1" "${CONFIG_KEYS[@]}" <<'PY'
import re, shlex, sys
path, keys = sys.argv[1], set(sys.argv[2:])
for n, line in enumerate(open(path, encoding="utf-8"), 1):
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    m = re.match(r"(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$", line)
    if not m:
        sys.exit(f"{path}:{n}: not KEY=VALUE")
    k, v = m.groups()
    if k not in keys:
        print(f"{path}:{n}: unknown key {k} (ignored)", file=sys.stderr); continue
    try:
        parts = shlex.split(v, comments=True)
    except ValueError as e:
        sys.exit(f"{path}:{n}: {e}")
    if len(parts) > 1:
        sys.exit(f"{path}:{n}: quote values that contain spaces")
    val = parts[0] if parts else ""
    if "\t" in val or "\n" in val:
        sys.exit(f"{path}:{n}: tabs and newlines are not allowed")
    print(f"{k}\t{val}")
PY
}

env_load() {   # file: set the known keys from a .env file; empty values there do not override saved ones
  local k v out; [ -f "$1" ] || return 0
  out=$(env_parse "$1") || die "cannot read $1"
  while IFS=$'\t' read -r k v; do [ -n "$k" ] && [ -n "$v" ] && printf -v "$k" '%s' "$v"; done <<< "$out"
  return 0
}

config_load_saved() { if [ -f "$CONF" ]; then
  # shellcheck source=/dev/null
  . "$CONF"; fi; set_paths; }
set_paths() { INSTALL_USER=${INSTALL_USER:-${SUDO_USER:-root}}; UHOME=$(user_home "$INSTALL_USER"); export PATH="/usr/local/bin:$PATH"; }

# ---------------------------------------------------------------- validation (each prints the reason on failure)
check_range() {   # first-last on the host's subnet
  python3 - "$1" "$2" <<'PY'
import ipaddress as a, sys
r, pfx = sys.argv[1], sys.argv[2]
f, _, l = r.partition("-"); l = l or f
try:
    f, l, net = a.ip_address(f), a.ip_address(l), a.ip_network(pfx, strict=False)
except ValueError as e:
    sys.exit(f"not an address range: {e}")
if f not in net or l not in net: sys.exit(f"range must be inside {net}")
if l < f: sys.exit("last address is before the first")
if int(l) - int(f) > 255: sys.exit("range is larger than 256 addresses")
PY
}
check_bdfs() {   # comma-separated PCI addresses that exist on this host
  local b; [ -z "$1" ] || [ "$1" = none ] && return 0
  for b in ${1//,/ }; do [[ $b =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]] || { echo "bad PCI address '$b' (form 0000:c8:00.0)"; return 1; }
    [ -e "$PCI_ROOT/$b" ] || { echo "no PCI device $b on this host"; return 1; }; done; }
gpu_vendor_check() {   # list vendor-id label: every address exists and belongs to that vendor
  local b; [ -z "$1" ] || [ "$1" = none ] && return 0
  check_bdfs "$1" || return 1
  for b in ${1//,/ }; do [ "$(pci_ids "$b" | cut -d: -f1)" = "$2" ] || { echo "$b is not an $3 GPU ($(pci_name "$b"))"; return 1; }; done; }
v_nv() { gpu_vendor_check "$1" 10de NVIDIA; }
v_amd() { local b; gpu_vendor_check "$1" 1002 AMD || return 1; [ "$1" = none ] && return 0
  for b in ${1//,/ }; do amd_compute "$b" || { echo "$b is not a supported AMD compute GPU"; return 1; }; done; }
v_iso() { local b; gpu_vendor_check "$1" 1002 AMD || return 1; [ "$1" = none ] && return 0
  for b in ${1//,/ }; do
    [[ ",${AMD_GPUS:-}," == *",$b,"* ]] && { echo "$b is also in AMD_GPUS: a GPU is either used or isolated"; return 1; }
    [ -z "${AMD_GPUS:-}" ] && amd_compute "$b" && { echo "$b is a compute GPU and AMD_GPUS (empty) means all of them: list AMD_GPUS explicitly"; return 1; }
  done; return 0; }
check_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "not an e-mail address"; return 1; }; }
check_password() { [ ${#1} -ge 12 ] || { echo "use at least 12 characters"; return 1; }; }
check_runai_password() {   # Run:ai's policy on top: upper and lower case, a digit and one of - ! @ # $ % ^ & * ( ) _ + =
  check_password "$1" || return 1
  local sym='[-!@#$%^&*()_+=]'
  [[ $1 =~ [A-Z] && $1 =~ [a-z] && $1 =~ [0-9] && $1 =~ $sym ]] \
    || { echo "Run:ai needs an upper-case and a lower-case letter, a digit and one of - ! @ # \$ % ^ & * ( ) _ + ="; return 1; }; }

# ask until valid: VAR question default validator [secret]
ask_valid() { local var=$1 q=$2 def=$3 fn=$4 secret=${5:-} v why n=0
  while :; do
    if [ -n "$secret" ]; then v=$(ask_secret "$q"); else v=$(ask "$q" "$def"); fi
    if why=$($fn "$v" 2>&1); then printf -v "$var" '%s' "$v"; return 0; fi
    echo "   $why" >/dev/tty; n=$((n + 1)); [ $n -ge 3 ] && die "$var: $why"
  done; }
valid_or_ask() {   # VAR question default validator [secret]: keep a valid value (.env or saved), else ask
  local var=$1 why
  if [ -n "${!var:-}" ]; then
    if why=$($4 "${!var}" 2>&1); then return 0; fi
    warn "$var: $why"; [ "$INTERACTIVE" = 1 ] || die "$var: $why"
  fi
  [ "$INTERACTIVE" = 1 ] || die "$var is not set in $ENV_FILE and oif is not interactive"
  ask_valid "$@"
}

v_ip_here() { valid_ip "$1" || { echo "not an IPv4 address"; return 1; }; [ -n "$(host_prefix "$1")" ] || { echo "$1 is not an address of this host"; return 1; }; }
v_range() { check_range "$1" "$(host_prefix "$HOST_IP")"; }
v_dir() { [[ $1 == /* && $1 != / ]] || { echo "give an absolute path (not /)"; return 1; }; }
v_any() { return 0; }
v_domain() { [ -z "$1" ] || [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,}$ ]] || { echo "not a domain name"; return 1; }; }
first_ip() { echo "${1%%-*}"; }   # first address of a range
runai_domain() { echo "${RUNAI_DOMAIN:-runai.$(first_ip "$METALLB_RANGE" | tr . -).sslip.io}"; }

CONFIG_CHECKS=(HOST_IP:v_ip_here METALLB_RANGE:v_range INSTALL_DIR:v_dir NVIDIA_GPUS:v_nv AMD_GPUS:v_amd ISOLATE_GPUS:v_iso
               RUNAI_DOMAIN:v_domain RUNAI_ADMIN_EMAIL:check_email RUNAI_ADMIN_PASSWORD:check_runai_password GRAFANA_ADMIN_PASSWORD:check_password)
config_validate() {   # saved settings still valid on this host (secret values are never printed)
  local kv k f why bad=0
  for kv in "${CONFIG_CHECKS[@]}"; do k=${kv%%:*}; f=${kv#*:}
    [ -n "${!k:-}" ] || continue
    why=$($f "${!k}" 2>&1) || { warn "setting $k: $why"; bad=1; }
  done
  [ $bad = 0 ] || die "the saved settings are not valid on this host: correct them with 'sudo $SELF install --reconfigure'"
}

config_collect() {   # all questions first; nothing on the host changes here
  [ "$INTERACTIVE" = 1 ] || die "settings are missing: run 'sudo oif install' in a terminal"
  env_load "$ENV_FILE"
  echo; echo "${c_b}Open Inference Fabric $OIF_VERSION${c_0} - all questions first, then it runs unattended."
  [ -f "$ENV_FILE" ] && echo "   Settings file: $ENV_FILE (values there are used; missing ones are asked)" \
    || echo "   No settings file at $ENV_FILE: every value is asked (copy .env.example to .env to skip this)"
  INSTALL_USER=${SUDO_USER:-}; [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != root ] || INSTALL_USER=$(ask "   Non-root user who will run kubectl")
  id "$INSTALL_USER" >/dev/null 2>&1 || die "no user $INSTALL_USER"

  echo; echo "${c_b}GPUs on this host${c_0}"; gpu_table
  valid_or_ask NVIDIA_GPUS "   NVIDIA GPUs for Kubernetes (addresses from the NVIDIA lines, comma-separated; empty = all)" "" v_nv
  valid_or_ask AMD_GPUS "   AMD GPUs for Kubernetes from Project 1.2 (addresses from the AMD compute lines; empty = all)" "" v_amd
  local def_iso; def_iso=$(IFS=,; echo "${OTHER_BDFS[*]}")
  valid_or_ask ISOLATE_GPUS "   AMD display cards to keep away from Kubernetes with vfio ('none' for none)" "${def_iso:-none}" v_iso
  [ "$ISOLATE_GPUS" = none ] && ISOLATE_GPUS=""

  echo; echo "${c_b}Network${c_0}"
  HOST_IP=${HOST_IP:-}; [ -n "$HOST_IP" ] || HOST_IP=$(host_ip)
  valid_or_ask HOST_IP "   This host's IP address (Kubernetes API)" "$(host_ip)" v_ip_here
  echo "   MetalLB gives service addresses on $(host_prefix "$HOST_IP"); pick free ones (Run:ai, Grafana, inference endpoint)."
  valid_or_ask METALLB_RANGE "   Free address range for MetalLB (first-last)" "" v_range
  local used ip; used=""
  for ip in $(python3 -c "import ipaddress as a,sys;f,_,l=sys.argv[1].partition('-');l=l or f;print(*[a.ip_address(i) for i in range(int(a.ip_address(f)),int(a.ip_address(l))+1)])" "$METALLB_RANGE"); do
    ping -c1 -W1 "$ip" >/dev/null 2>&1 && used="$used $ip"; done
  [ -z "$used" ] && ok "MetalLB range $METALLB_RANGE: no address answers ping" || warn "these addresses answer ping and may be in use:$used"

  echo; echo "${c_b}Storage${c_0}"
  local base; base=$(largest_fs); base=${base%/}
  valid_or_ask INSTALL_DIR "   Data folder (images, volumes, models, results; removed by uninstall)" "$base/oif" v_dir
  INSTALL_DIR=${INSTALL_DIR%/}
  [ "$(free_gb "$INSTALL_DIR")" -ge 200 ] && ok "$INSTALL_DIR: $(free_gb "$INSTALL_DIR") GB free" || warn "$INSTALL_DIR has $(free_gb "$INSTALL_DIR") GB free (about 200 GB recommended)"

  echo; echo "${c_b}Accounts and tokens${c_0} (stored only in $CONF, mode 600, and later as Kubernetes Secrets)"
  valid_or_ask RUNAI_ADMIN_EMAIL "   Run:ai administrator e-mail" "" check_email
  valid_or_ask RUNAI_ADMIN_PASSWORD "   Run:ai administrator password (12+ characters: upper and lower case, a digit, a symbol)" "" check_runai_password secret
  valid_or_ask GRAFANA_ADMIN_PASSWORD "   Grafana admin password (12+ characters)" "" check_password secret
  [ -n "${HF_TOKEN:-}" ] || HF_TOKEN=$(ask_secret "   Hugging Face token (only for gated models; empty = none)")
  MODEL_ID=${MODEL_ID:-Qwen/Qwen3-0.6B}

  echo; echo "${c_b}Summary${c_0}"
  echo "   Host $HOST_IP, user $INSTALL_USER, MetalLB $METALLB_RANGE, data in $INSTALL_DIR"
  echo "   NVIDIA GPUs: ${NVIDIA_GPUS:-all}; AMD GPUs (from 1.2): ${AMD_GPUS:-all supported}; isolated: ${ISOLATE_GPUS:-none}"
  echo "   Run:ai admin $RUNAI_ADMIN_EMAIL; HF token $([ -n "$HF_TOKEN" ] && echo set || echo 'not set')"
  echo "   Stages: ${STAGES[*]}"
  REBOOT_OK=no
  local b need=""; for b in "${NV_BDFS[@]}"; do [ "$(drv "$b")" = nvidia ] || need="the NVIDIA driver"; done
  for b in ${ISOLATE_GPUS//,/ }; do [ "$(drv "$b")" = vfio-pci ] || need="${need:+$need and }GPU isolation"; done
  if [ -n "$need" ]; then
    echo; echo "${c_b}Reboot${c_0}: $need need one reboot, after the packages are installed."
    yesno "   May oif reboot this host by itself at that point (the install then continues on its own)" y && REBOOT_OK=yes
  fi
  yesno "Start with these settings" y || { echo "Nothing changed."; exit 0; }
  save REBOOT_OK "$REBOOT_OK"
  local k; save INSTALL_USER "$INSTALL_USER"; for k in "${CONFIG_KEYS[@]}"; do save "$k" "${!k:-}"; done
  ok "settings saved to $CONF"
}
