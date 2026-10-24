#!/bin/bash
# .env parsing and input validation
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

cat > "$SANDBOX/a.env" <<'EOF'
# comment
HOST_IP=10.0.0.5          # inline comment
METALLB_RANGE="10.0.0.240-10.0.0.244"
INSTALL_DIR='/data/oif'
export MODEL_ID=Qwen/Qwen3-0.6B
HF_TOKEN='$(touch SANDBOX_PWNED)'
GRAFANA_ADMIN_PASSWORD='p@ss word#1'
UNKNOWN_KEY=x
NVIDIA_GPUS=
EOF
cd "$SANDBOX" || exit 1
env_load "$SANDBOX/a.env" 2>/dev/null
eq "$HOST_IP" 10.0.0.5 "inline comment stripped:"
eq "$METALLB_RANGE" 10.0.0.240-10.0.0.244 "double quotes:"
eq "$INSTALL_DIR" /data/oif "single quotes:"
eq "$MODEL_ID" Qwen/Qwen3-0.6B "export prefix:"
eq "$HF_TOKEN" '$(touch SANDBOX_PWNED)' "command substitution is data, not code:"
[ -e SANDBOX_PWNED ] && fail ".env value was executed"
eq "$GRAFANA_ADMIN_PASSWORD" 'p@ss word#1' "quoted value with space and #:"
eq "${NVIDIA_GPUS-unset}" "" "empty value:"
eq "${UNKNOWN_KEY-unset}" unset "unknown key ignored:"

printf 'not a setting\n' > "$SANDBOX/bad.env"
no_ env_parse "$SANDBOX/bad.env"
printf 'HOST_IP=a b\n' > "$SANDBOX/bad2.env"
no_ env_parse "$SANDBOX/bad2.env"

ok_ check_range 10.0.0.240-10.0.0.244 10.0.0.0/24
ok_ check_range 10.0.0.240 10.0.0.0/24
no_ check_range 10.0.1.240-10.0.1.244 10.0.0.0/24
no_ check_range 10.0.0.244-10.0.0.240 10.0.0.0/24
no_ check_range banana 10.0.0.0/24
ok_ check_email admin@example.com
no_ check_email admin
ok_ check_password abcdefghijkl
no_ check_password short
ok_ check_bdfs ""
ok_ check_bdfs none
no_ check_bdfs c8:00.0
no_ check_bdfs 0000:zz:00.0
ok_ v_dir /data/oif
no_ v_dir data/oif
no_ v_dir /

# saved settings are shell-quoted and mode 600
save GRAFANA_ADMIN_PASSWORD "it's \$secret; rm -rf /"
eq "$(stat -c %a "$CONF")" 600 "settings file mode:"
( . "$CONF"; eq "$GRAFANA_ADMIN_PASSWORD" "it's \$secret; rm -rf /" "round trip:" ; [ "$FAILS" = 0 ] ) || fail "saved settings round trip"
finish
