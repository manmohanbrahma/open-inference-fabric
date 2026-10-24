# shellcheck shell=bash
# Settings: read from .env (never executed), validated, missing values asked, saved to $CONF (mode 600).

CONFIG_KEYS=(HOST_IP METALLB_RANGE INSTALL_DIR NVIDIA_GPUS AMD_GPUS ISOLATE_GPUS
             HF_TOKEN NGC_API_KEY RUNAI_ADMIN_EMAIL RUNAI_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD MODEL_ID)

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

env_load() {   # file: set the known keys from a .env file
  local k v out; [ -f "$1" ] || return 0
  out=$(env_parse "$1") || die "cannot read $1"
  while IFS=$'\t' read -r k v; do [ -n "$k" ] && printf -v "$k" '%s' "$v"; done <<< "$out"
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
    [ -e "/sys/bus/pci/devices/$b" ] || { echo "no PCI device $b on this host"; return 1; }; done; }
check_email() { [[ $1 =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "not an e-mail address"; return 1; }; }
check_password() { [ ${#1} -ge 12 ] || { echo "use at least 12 characters"; return 1; }; }

# ask until valid: VAR question default validator [secret]
ask_valid() { local var=$1 q=$2 def=$3 fn=$4 secret=${5:-} v why n=0
  while :; do
    if [ -n "$secret" ]; then v=$(ask_secret "$q"); else v=$(ask "$q" "$def"); fi
    if why=$($fn "$v" 2>&1); then printf -v "$var" '%s' "$v"; return 0; fi
    echo "   $why" >/dev/tty; n=$((n + 1)); [ $n -ge 3 ] && die "$var: $why"
  done; }
valid_or_ask() {   # VAR question default validator [secret]: keep a valid .env value, else ask
  local var=$1 why
  if [ -n "${!var:-}" ]; then
    if why=$($4 "${!var}" 2>&1); then return 0; fi
    warn "$var in $ENV_FILE: $why"; [ "$INTERACTIVE" = 1 ] || die "$var: $why"
  fi
  [ "$INTERACTIVE" = 1 ] || die "$var is not set in $ENV_FILE and oif is not interactive"
  ask_valid "$@"
}

v_ip_here() { valid_ip "$1" || { echo "not an IPv4 address"; return 1; }; [ -n "$(host_prefix "$1")" ] || { echo "$1 is not an address of this host"; return 1; }; }
v_range() { check_range "$1" "$(host_prefix "$HOST_IP")"; }
v_dir() { [[ $1 == /* && $1 != / ]] || { echo "give an absolute path (not /)"; return 1; }; }
v_any() { return 0; }

config_collect() {   # all questions first; nothing on the host changes here
  [ "$INTERACTIVE" = 1 ] || die "settings are missing: run 'sudo oif install' in a terminal"
  env_load "$ENV_FILE"
  echo; echo "${c_b}Open Inference Fabric $OIF_VERSION${c_0} - all questions first, then it runs unattended."
  [ -f "$ENV_FILE" ] && echo "   Settings file: $ENV_FILE (values there are used; missing ones are asked)" \
    || echo "   No settings file at $ENV_FILE: every value is asked (copy .env.example to .env to skip this)"
  INSTALL_USER=${SUDO_USER:-}; [ -n "$INSTALL_USER" ] && [ "$INSTALL_USER" != root ] || INSTALL_USER=$(ask "   Non-root user who will run kubectl")
  id "$INSTALL_USER" >/dev/null 2>&1 || die "no user $INSTALL_USER"

  echo; echo "${c_b}GPUs on this host${c_0}"; gpu_table
  valid_or_ask NVIDIA_GPUS "   NVIDIA GPUs for Kubernetes (PCI addresses, comma-separated; empty = all)" "" check_bdfs
  valid_or_ask AMD_GPUS "   AMD GPUs for Kubernetes from Project 1.2 (empty = all supported)" "" check_bdfs
  local def_iso; def_iso=$(IFS=,; echo "${OTHER_BDFS[*]}")
  valid_or_ask ISOLATE_GPUS "   GPUs to keep away from Kubernetes with vfio (display cards; 'none' for none)" "${def_iso:-none}" check_bdfs
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
  valid_or_ask RUNAI_ADMIN_PASSWORD "   Run:ai administrator password (12+ characters)" "" check_password secret
  valid_or_ask GRAFANA_ADMIN_PASSWORD "   Grafana admin password (12+ characters)" "" check_password secret
  [ -n "${NGC_API_KEY:-}" ] || NGC_API_KEY=$(ask_secret "   NVIDIA NGC API key (Run:ai images and charts; empty = ask later)")
  [ -n "${HF_TOKEN:-}" ] || HF_TOKEN=$(ask_secret "   Hugging Face token (only for gated models; empty = none)")
  MODEL_ID=${MODEL_ID:-Qwen/Qwen3-0.6B}

  echo; echo "${c_b}Summary${c_0}"
  echo "   Host $HOST_IP, user $INSTALL_USER, MetalLB $METALLB_RANGE, data in $INSTALL_DIR"
  echo "   NVIDIA GPUs: ${NVIDIA_GPUS:-all}; AMD GPUs (from 1.2): ${AMD_GPUS:-all supported}; isolated: ${ISOLATE_GPUS:-none}"
  echo "   Run:ai admin $RUNAI_ADMIN_EMAIL; NGC key $([ -n "$NGC_API_KEY" ] && echo set || echo 'not set'); HF token $([ -n "$HF_TOKEN" ] && echo set || echo 'not set')"
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
