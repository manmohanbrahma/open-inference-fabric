# shellcheck shell=bash
# Output, prompts, state and the host-change manifest. Sourced by oif.

STATE=${OIF_STATE:-/var/lib/oif}          # settings, manifest, logs, done markers (root only)
CONF=$STATE/settings.conf
MANIFEST=$STATE/manifest
DONE=$STATE/done
LOG=/var/log/oif-install.log              # readable by the installing user: no secrets (see redact)
UNINSTALL_LOG=/var/log/oif-uninstall.log
TLOG=$LOG                                 # where on-screen lines are copied (/dev/null when stdout is the log)
RESUME_UNIT=/etc/systemd/system/oif-resume.service
MARK=oif                                  # marker for blocks oif adds to shared files
INTERACTIVE=1; [ -t 0 ] || INTERACTIVE=0

c_b=$'\e[1m'; c_g=$'\e[32m'; c_y=$'\e[33m'; c_r=$'\e[31m'; c_0=$'\e[0m'
[ -t 1 ] || { c_b=; c_g=; c_y=; c_r=; c_0=; }
log()  { echo "${c_b}$(date '+%F %T') == $*${c_0}" | tee -a "$TLOG"; }
ok()   { echo "  ${c_g}[ok]${c_0} $*" | tee -a "$TLOG"; }
warn() { echo "  ${c_y}[!]${c_0} $*" | tee -a "$TLOG"; }
die()  { echo "${c_r}ERROR: $*${c_0}" | tee -a "$TLOG" >&2; exit 1; }
ask()  { local v=""; [ "$INTERACTIVE" = 1 ] && read -r -p "$1${2:+ [$2]}: " v </dev/tty; echo "${v:-${2:-}}"; }
ask_secret() { local v=""; [ "$INTERACTIVE" = 1 ] && { read -r -s -p "$1: " v </dev/tty; echo >/dev/tty; }; echo "$v"; }
yesno() { local a; a=$(ask "$1 (y/n)" "${2:-y}"); [[ $a =~ ^[Yy] ]]; }

# bootstrap tokens (abcdef.0123456789abcdef) and 64-hex keys such as kubeadm's certificate key
redact() { sed -E 's/\b[a-z0-9]{6}\.[a-z0-9]{16}\b/<redacted>/g; s/\b[0-9a-f]{64}\b/<redacted>/g'; }
redact_file() {   # rewrite only when needed, in the same file so open log handles keep working
  grep -qE '\b[a-z0-9]{6}\.[a-z0-9]{16}\b|\b[0-9a-f]{64}\b' "$1" || return 0
  local t; t=$(mktemp); redact < "$1" > "$t" && cat "$t" > "$1"; rm -f "$t"; }

state_init() { mkdir -p "$STATE" "$DONE"; chmod 700 "$STATE"; touch "$MANIFEST" "$LOG"; chmod 644 "$LOG"; }

# settings saved by the questions, shell-quoted, mode 600 (they include secrets)
save() { touch "$CONF"; chmod 600 "$CONF"; grep -v "^$1=" "$CONF" > "$CONF.tmp" || true
  printf '%s=%q\n' "$1" "$2" >> "$CONF.tmp"; chmod 600 "$CONF.tmp"; mv "$CONF.tmp" "$CONF"; }

# ---------------------------------------------------------------- manifest: every host change, reversed by uninstall
# Record kinds (one per line, replayed newest first):
#   PKG name | FILE path | DIR path | DATADIR path | RESTORE backup target | BLOCK file tag | LINE file text
#   SWAP | GROUP user group | SERVICE unit | ENABLED unit | INITRAMFS | TEARDOWN name (calls teardown_<name>)
rec() { grep -qxF "$*" "$MANIFEST" 2>/dev/null || echo "$*" >> "$MANIFEST"; }
recorded() { grep -qxF "$*" "$MANIFEST" 2>/dev/null; }

# keep a copy of a file before changing it (restored by uninstall); a new file is recorded as FILE
backup_file() { local f=$1 b; b=$STATE/backup$(echo "$f" | tr / _)
  [ -e "$b" ] && return 0
  if [ -e "$f" ]; then cp -p "$f" "$b"; rec "RESTORE $b $f"; else rec "FILE $f"; fi; }

# write a whole file oif owns (recorded as new, or backed up first if it existed)
put_file() { local f=$1 mode=${3:-644}; backup_file "$f"; mkdir -p "$(dirname "$f")"; printf '%s' "$2" > "$f"; chmod "$mode" "$f"; }

# marker-delimited block in a shared file (fstab, sysctl files): added once, removed exactly by uninstall
block_set() { local f=$1 tag=$2 body=$3
  touch "$f"; sed -i "\|^# BEGIN $MARK $tag\$|,\|^# END $MARK $tag\$|d" "$f"
  printf '# BEGIN %s %s\n%s\n# END %s %s\n' "$MARK" "$tag" "$body" "$MARK" "$tag" >> "$f"; rec "BLOCK $f $tag"; }

# ---------------------------------------------------------------- stages: idempotent steps, skipped once done
STAGES=()
declare -A STAGE_PIN=()
# name [VERSION_VAR]: the function is stage_<name with - as _>. A stage pinned to a variable from versions.env
# runs again when that version changes (its done marker holds the version it ran with).
register_stage() { STAGES+=("$1"); [ -z "${2:-}" ] || STAGE_PIN[$1]=$2; }
stage_want() {   # the pinned value: a variable, or a function evaluated when the stage runs (after the settings are loaded)
  local v=${STAGE_PIN[$1]:-}; [ -z "$v" ] && return 0
  if declare -F "$v" >/dev/null; then "$v"; else echo "${!v}"; fi; }
done_() { [ -f "$DONE/$1" ] && [ "$(cat "$DONE/$1")" = "$(stage_want "$1")" ]; }
stage() { local s=$1; done_ "$s" && return 0
  if [ -s "$DONE/$s" ]; then log "stage: $s ($(cat "$DONE/$s") -> $(stage_want "$s"))"; else log "stage: $s"; fi
  "stage_${s//-/_}"; stage_want "$s" > "$DONE/$s"; }
run_stages() { local s; for s in "${STAGES[@]}"; do stage "$s"; done; }

# ---------------------------------------------------------------- small helpers
retry() {   # cmd...: up to 4 tries, 15/30/45 s apart
  local n=1; until "$@"; do [ $n -ge 4 ] && return 1; warn "attempt $n failed, retrying in $((n * 15)) s: $*"; sleep $((n * 15)); n=$((n + 1)); done; }
wait_for() {   # description timeout-seconds interval command...
  local d=$1 t=$2 i=$3 s=$SECONDS; shift 3
  until "$@" >/dev/null 2>&1; do
    [ $((SECONDS - s)) -ge "$t" ] && { warn "$d: not reached within $((t / 60)) min"; return 1; }
    sleep "$i"
  done; ok "$d"; }
follow_job() {   # unit log [first-line]: show a background job's log until it ends (Ctrl+C stops only the viewing)
  tail -n +"${3:-1}" -f "$2" & local t=$!
  while systemctl is-active -q "$1" 2>/dev/null || [ "$(systemctl show -p ActiveState --value "$1" 2>/dev/null)" = activating ]; do sleep 3; done
  sleep 2; kill $t 2>/dev/null || true; }
