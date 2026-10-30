# shellcheck shell=bash
# Multi-node (ADR-017): the admin runs oif on the first control-plane node; it reaches the other nodes over SSH with
# its own cluster key, copies itself there and runs the node stages, each node keeping its own change record.
# OIF_NODES="192.168.120.11:control 192.168.120.12:control ... 192.168.120.21:worker" (empty: single node); an entry may
# carry a label for logs and records, "cp1=192.168.120.11:control". Kubernetes names each node by its hostname anyway.

NODE_STAGES=(preflight host-packages kernel storage-host containerd nvidia-driver amd-firmware gpu-isolation reboot host-verify k8s-packages)
NODE_SETTINGS=(INSTALL_DIR INSTALL_USER NVIDIA_GPUS AMD_GPUS ISOLATE_GPUS REBOOT_OK LONGHORN_NODE)   # all a node stage reads
NODE_SRC=/var/lib/oif/src           # oif's copy on a node; inside the node's state folder, so uninstall removes it
CLUSTER_KEY=$STATE/ssh/id_ed25519   # oif's own key, created on the first node (root only)
NODE_REBOOT_RC=75                   # a node stage needs a reboot: the first node reboots the node and runs it again
JOINED_MARK=/etc/kubernetes/kubelet.conf      # a node that has it is in the cluster already

multi_node() { [ -n "${OIF_NODES:-}" ]; }
nodes_list() {   # print "label address role" per node, in the order given; the label is the address when none is given
  local e a; for e in ${OIF_NODES:-}; do a=${e#*=}; a=${a%%:*}
    if [[ $e == *=* ]]; then printf '%s %s %s\n' "${e%%=*}" "$a" "${e##*:}"; else printf '%s %s %s\n' "$a" "$a" "${e##*:}"; fi; done; }
other_nodes() { nodes_list | tail -n +2; }   # every node but the first, which runs oif
node_user() { echo "${OIF_NODE_USER:-$INSTALL_USER}"; }
control_count() { nodes_list | awk '$3 == "control"' | wc -l; }

# The platform (Run:ai, monitoring, ingress, storage) runs on the control-plane nodes, labelled with Run:ai's system-node
# role; with three or more of them its data lives on Longhorn volumes with a copy on each, so it survives losing one
# (ADR-021). GPU nodes run workloads only.
SYSTEM_LABEL=node-role.kubernetes.io/runai-system
platform_ha() { multi_node && [ "$(control_count)" -ge 3 ]; }
platform_sc() { if platform_ha; then echo longhorn; else echo local-path; fi; }   # StorageClass of the platform's data
longhorn_here() {   # does this node hold Longhorn replicas? (the first node decides; a node reads its setting)
  if [ "${OIF_NODE:-0}" = 1 ]; then [ "${LONGHORN_NODE:-no}" = yes ]; else platform_ha; fi; }
platform_render() {   # template under platform/: into the state folder, with the platform's node label and StorageClass
  export SYSTEM_LABEL PLATFORM_SC; PLATFORM_SC=$(platform_sc)
  render "$OIF_HOME/platform/$1" > "$STATE/${1##*/}" || die "cannot render platform/$1"; }
node_name_of() {   # address: the Kubernetes node name of the node with that address
  kc get nodes -o jsonpath="{range .items[*]}{.metadata.name} {.status.addresses[?(@.type=='InternalIP')].address}{'\n'}{end}" \
    | awk -v a="$1" '$2 == a {print $1}'; }

v_nodes() {   # [label=]address:role ..., the first one this host and a control-plane node
  [ -z "$1" ] && return 0
  local e name addr role n=0 ctl=0 seen=" "
  for e in $1; do
    [[ $e =~ ^(([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)=)?([0-9.]+):(control|worker)$ ]] || { echo "'$e' is not [label=]address:control|worker"; return 1; }
    addr=${BASH_REMATCH[4]} role=${BASH_REMATCH[5]} name=${BASH_REMATCH[2]:-${BASH_REMATCH[4]}}
    valid_ip "$addr" || { echo "$name: '$addr' is not an IPv4 address"; return 1; }
    [[ $seen == *" $name "* || $seen == *" $addr "* ]] && { echo "$name or $addr is listed twice"; return 1; }
    seen+="$name "; [ "$name" = "$addr" ] || seen+="$addr "
    if [ $n = 0 ]; then
      [ "$role" = control ] || { echo "the first node ($name) runs oif and must be a control-plane node"; return 1; }
      [ -n "$(host_prefix "$addr")" ] || { echo "the first node ($name, $addr) must be this host: run oif there"; return 1; }
    fi
    [ "$role" = control ] && ctl=$((ctl + 1)); n=$((n + 1))
  done
  [ $n -ge 2 ] || { echo "list at least two nodes, or leave OIF_NODES empty for a single node"; return 1; }
  [ $((ctl % 2)) = 1 ] || { echo "$ctl control-plane nodes: use an odd number (1 or 3) so etcd keeps a majority"; return 1; }
}
v_vip() {   # the API address of a highly available control plane: free, on the first node's subnet
  local nctl; nctl=$(nodes_list | awk '$3 == "control"' | wc -l)
  if [ "$nctl" -le 1 ]; then [ -z "$1" ] && return 0; fi
  [ -n "$1" ] || { echo "$nctl control-plane nodes need an API address (OIF_API_VIP)"; return 1; }
  valid_ip "$1" || { echo "not an IPv4 address"; return 1; }
  nodes_list | awk -v a="$1" '$2 == a {f=1} END {exit !f}' && { echo "$1 is a node's address"; return 1; }
  check_range "$1" "$(host_prefix "$HOST_IP")" >/dev/null || { echo "$1 is not on $(host_prefix "$HOST_IP")"; return 1; }
}
v_yesno() { case "$1" in yes|no) ;; *) echo "answer yes or no"; return 1 ;; esac; }

# ---------------------------------------------------------------- SSH with the cluster key
NODE_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o LogLevel=ERROR
               -o IdentitiesOnly=yes -o IdentityAgent=none     # only oif's own key, never a forwarded agent's
               -o ServerAliveInterval=5 -o ServerAliveCountMax=3)   # a node that goes down mid-call (reboot) fails the call
node_ssh() {   # address command...: run on a node as the node user (the command uses sudo itself)
  # stdin is not read (-n), so loops over the node list keep theirs; NODE_SSH_STDIN=1 passes stdin to the node
  local a=$1 no_stdin=(-n); shift; [ "${NODE_SSH_STDIN:-0}" = 1 ] && no_stdin=()
  ssh "${no_stdin[@]}" -i "$CLUSTER_KEY" "${NODE_SSH_OPTS[@]}" -o UserKnownHostsFile="$STATE/ssh/known_hosts" "$(node_user)@$a" "$@"
}
node_ok() { node_ssh "$1" 'sudo -n true' >/dev/null 2>&1; }   # reachable with the cluster key, sudo without a password

cluster_key_init() {
  [ -f "$CLUSTER_KEY" ] && return 0
  mkdir -p "${CLUSTER_KEY%/*}"; chmod 700 "${CLUSTER_KEY%/*}"
  ssh-keygen -q -t ed25519 -N '' -C "oif-cluster@$(hostname -s)" -f "$CLUSTER_KEY"
  ok "cluster SSH key created (${CLUSTER_KEY}.pub)"
}

# Interactive, before the background job: the admin's forwarded SSH agent is only available here.
nodes_prepare() {
  multi_node || return 0
  echo; echo "${c_b}Nodes${c_0}"
  cluster_key_init
  local name addr role pub missing=() agent=${SSH_AUTH_SOCK:-}
  pub=$(cat "$CLUSTER_KEY.pub")
  while read -r -u 3 name addr role; do   # the node list on fd 3: nothing in the loop can read it away
    if node_ok "$addr"; then ok "$name ($addr, $role): reachable with the cluster key"; continue; fi
    if [ -S "$agent" ] && admin_ssh "$addr" "$(authorized_add "$pub")" && node_ok "$addr"; then
      rec "NODEKEY $addr $(node_user)"; ok "$name ($addr): cluster key installed through your SSH agent"; continue; fi
    missing+=("$name=$addr")
  done 3< <(other_nodes)
  if [ ${#missing[@]} -gt 0 ]; then
    warn "no access yet to: ${missing[*]}"
    echo "   oif installs its own key on each node once, using your access. Either log in to this node with your"
    echo "   agent forwarded and keep it through sudo:   ssh -A $(node_user)@<this node>;  sudo --preserve-env=SSH_AUTH_SOCK $SELF install"
    echo "   or add this line to ~$(node_user)/.ssh/authorized_keys on each node yourself:"
    echo "   $pub"
    die "the cluster key is not on every node yet (the user on each node needs sudo without a password)"
  fi
  admin_key_control
}
admin_ssh() {   # address command: as the admin, with the admin's forwarded agent (only during the questions)
  ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o IdentityAgent="$SSH_AUTH_SOCK" -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="$STATE/ssh/known_hosts" -o LogLevel=ERROR "$(node_user)@$1" "$2"; }
authorized_add() {   # key line -> remote shell that adds it to the user's authorized_keys once
  printf 'umask 077; mkdir -p ~/.ssh; grep -qxF %q ~/.ssh/authorized_keys 2>/dev/null || echo %q >> ~/.ssh/authorized_keys' "$1" "$1"; }
authorized_del() { printf 'f=~/.ssh/authorized_keys; [ -f "$f" ] && grep -vxF %q "$f" > "$f.oif" ; [ -f "$f.oif" ] && cat "$f.oif" > "$f" && rm -f "$f.oif"; true' "$1"; }

admin_key_control() {   # the admin's choice: their public key(s) on the other control-plane nodes too
  [ "${ADMIN_KEY_ON_CONTROL:-yes}" = yes ] || { ok "admin key: not added to the control-plane nodes (ADMIN_KEY_ON_CONTROL=no)"; return 0; }
  local keys k name addr role n=0
  keys=$({ [ -S "${SSH_AUTH_SOCK:-}" ] && SSH_AUTH_SOCK=$SSH_AUTH_SOCK ssh-add -L 2>/dev/null; } | grep -E '^(ssh-|ecdsa-|sk-)' || true)
  [ -n "$keys" ] || keys=$(grep -E '^(ssh-|ecdsa-|sk-)' "$UHOME/.ssh/authorized_keys" 2>/dev/null || true)
  [ -n "$keys" ] || { warn "admin key: none found (forwarded agent or ~/.ssh/authorized_keys): not added"; return 0; }
  while read -r -u 3 name addr role; do [ "$role" = control ] || continue
    while read -r -u 4 k; do
      node_ssh "$addr" "grep -qxF $(printf %q "$k") ~/.ssh/authorized_keys 2>/dev/null" && continue
      node_ssh "$addr" "$(authorized_add "$k")" && rec "ADMINKEY $addr $k" && n=$((n + 1))
    done 4<<< "$keys"
  done 3< <(other_nodes)
  ok "admin key on the control-plane nodes ($n added; keys already there are left as they are)"
}

# ---------------------------------------------------------------- running the node stages on another node
node_push() {   # address: copy this oif (without settings, .git or test caches) to the node
  tar -C "$OIF_HOME" --exclude=.git --exclude=.env --exclude=tests/.cache -czf - . \
    | NODE_SSH_STDIN=1 node_ssh "$1" "sudo mkdir -p $NODE_SRC && sudo tar -xzf - -C $NODE_SRC && sudo chown -R root:root $NODE_SRC" \
    || die "cannot copy oif to $1"
}
node_settings() {   # role: what a node needs, its share of the settings, never the cluster's secrets
  local k ln=no; [ "${1:-}" = control ] && platform_ha && ln=yes
  for k in "${NODE_SETTINGS[@]}"; do
    case $k in NVIDIA_GPUS|AMD_GPUS|ISOLATE_GPUS) printf '%s=%q\n' "$k" "" ;;   # every GPU of the node, none isolated
               INSTALL_USER) printf '%s=%q\n' "$k" "$(node_user)" ;;
               REBOOT_OK) printf '%s=%q\n' "$k" no ;;                          # the first node reboots it (NODE_REBOOT_RC)
               LONGHORN_NODE) printf '%s=%q\n' "$k" "$ln" ;;                   # a control-plane node of an HA platform
               *) printf '%s=%q\n' "$k" "${!k:-}" ;; esac; done; }
node_install() {   # name address role: node stages until done, rebooting the node when a stage asks for it
  local name=$1 addr=$2 role=${3:-worker} rc boot n=0
  rec "NODE $addr $name"
  while :; do
    node_push "$addr"
    rc=0; node_settings "$role" | NODE_SSH_STDIN=1 node_ssh "$addr" "sudo $NODE_SRC/oif _node" 2>&1 | sed -u "s/^/  [$name] /" | tee -a "$TLOG" || rc=${PIPESTATUS[1]}
    [ "$rc" = 0 ] && { ok "$name: node stages done"; return 0; }
    [ "$rc" = "$NODE_REBOOT_RC" ] || die "$name: node stages failed (exit $rc; on the node: sudo tail -50 $LOG)"
    n=$((n + 1)); [ $n -le 2 ] || die "$name: still asks for a reboot after two"
    boot=$(node_ssh "$addr" cat /proc/sys/kernel/random/boot_id)
    log "$name: rebooting it for its GPU driver"
    node_ssh "$addr" 'sudo systemctl reboot' >/dev/null 2>&1 || true
    wait_for "$name back after the reboot" 600 10 bash -c \
      "b=\$(ssh -n -i '$CLUSTER_KEY' -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile='$STATE/ssh/known_hosts' -o LogLevel=ERROR '$(node_user)@$addr' cat /proc/sys/kernel/random/boot_id) && [ -n \"\$b\" ] && [ \"\$b\" != '$boot' ]" \
      || die "$name did not come back after the reboot"
  done
}


stage_nodes() {   # the node stages on every other node, before the cluster is formed (registered in 40-kubernetes.sh)
  multi_node || { ok "single node"; return 0; }
  local name addr role
  while read -r -u 3 name addr role; do node_ok "$addr" || die "$name ($addr) is not reachable with the cluster key: run 'sudo $SELF install --reconfigure' in a terminal"
  done 3< <(other_nodes)
  while read -r -u 3 name addr role; do log "node $name ($addr, $role)"; node_install "$name" "$addr" "$role"; done 3< <(other_nodes)
}

node_worker() {   # on a node: settings on stdin, then the node stages; exit NODE_REBOOT_RC when a reboot is due
  local k v line
  state_init; : > "$CONF.new"; chmod 600 "$CONF.new"
  while IFS= read -r line; do k=${line%%=*}
    [[ " ${NODE_SETTINGS[*]} " == *" $k "* ]] || die "unexpected setting '$k' from the first node"
    printf '%s\n' "$line" >> "$CONF.new"; done
  mv "$CONF.new" "$CONF"; config_load_saved
  OIF_NODE=1; log "oif $OIF_VERSION node stages (state in $STATE)"
  for v in "${NODE_STAGES[@]}"; do stage "$v"; done
  log "node stages finished"
}

node_uninstall() {   # address user: the node's own uninstall, then oif's copy and key (called by the first node's uninstall)
  local a=$1
  if node_ok "$a"; then
    node_ssh "$a" "sudo test -x $NODE_SRC/oif && sudo $NODE_SRC/oif _node-uninstall" 2>&1 | sed -u "s/^/  [$a] /" || warn "$a: node uninstall reported errors"
    ok "node $a: back to its OS default"
  else warn "node $a is not reachable: uninstall it there (sudo $NODE_SRC/oif uninstall) when it is back"; fi
}

# ---------------------------------------------------------------- the cluster across nodes (T-121)
api_endpoint() { echo "${OIF_API_VIP:-$HOST_IP}"; }   # where every node reaches the Kubernetes API
iface_of() { ip -o -4 addr show | awk -v a="$1" '{split($4, p, "/")} p[1] == a {print $2; exit}'; }
kube_vip_manifest() {   # kubeconfig node-address: the kube-vip static pod for this control-plane node
  local f=/etc/kubernetes/manifests/kube-vip.yaml
  VIP_INTERFACE=$(iface_of "$2"); [ -n "$VIP_INTERFACE" ] || die "no network interface holds $2"
  KUBE_VIP_KUBECONFIG=$1; export VIP_INTERFACE KUBE_VIP_KUBECONFIG KUBE_VIP_IMAGE OIF_API_VIP
  mkdir -p "${f%/*}"
  render "$K8S_TEMPLATES/kube-vip.yaml" > "$f.oif" || die "cannot render the kube-vip manifest"
  mv "$f.oif" "$f"   # /etc/kubernetes goes with the Kubernetes teardown
}


stage_k8s_join() {   # registered in 40-kubernetes.sh, after kubernetes: every other node joins the cluster
  multi_node || { ok "single node"; return 0; }
  local name addr role token key hash host rc
  hash=sha256:$(openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform der | sha256sum | cut -d' ' -f1)
  while read -r -u 3 name addr role; do
    host=$(node_ssh "$addr" hostname) || die "$name ($addr) is not reachable with the cluster key"
    if kc get node "$host" >/dev/null 2>&1; then ok "$name ($host) is already in the cluster"; continue; fi
    log "$name ($addr) joins as $role"
    token=$(kubeadm token create --ttl 30m --kubeconfig "$KCFG") || die "cannot create a join token"
    key=""
    if [ "$role" = control ]; then   # the control-plane certificates, encrypted, for two hours; k8s-tokens deletes them
      key=$(kubeadm init phase upload-certs --upload-certs --config "$STATE/kubeadm.yaml" 2>>"$LOG" | tail -1)
      [[ $key =~ ^[0-9a-f]{64}$ ]] || die "could not upload the control-plane certificates"
    fi
    node_push "$addr"
    rc=0
    { printf 'JOIN_ROLE=%s\nAPI_ENDPOINT=%s\nJOIN_TOKEN=%s\nJOIN_CA_HASH=%s\nJOIN_CERT_KEY=%s\nNODE_IP=%s\nOIF_API_VIP=%s\n' \
        "$role" "$(api_endpoint)" "$token" "$hash" "$key" "$addr" "${OIF_API_VIP:-}"; } \
      | NODE_SSH_STDIN=1 node_ssh "$addr" "sudo $NODE_SRC/oif _node-join" 2>&1 | redact | sed -u "s/^/  [$name] /" | tee -a "$TLOG" \
      || rc=${PIPESTATUS[1]}
    kubeadm token delete --kubeconfig "$KCFG" "${token%%.*}" >/dev/null 2>&1 || true
    [ "$rc" = 0 ] || die "$name could not join (on the node: sudo tail -50 $LOG)"
    wait_for "$name ($host) registered" 180 5 kc get node "$host" || die "$name joined but is not listed (kubectl get nodes)"
  done 3< <(other_nodes)
}

node_join() {   # on a node: join settings on stdin, then kubeadm join (recorded, so the node's uninstall reverses it)
  local line k
  state_init; config_load_saved
  local v ip='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  while IFS= read -r line; do k=${line%%=*} v=${line#*=}
    case $k in   # each value checked for its exact form, never evaluated
      JOIN_ROLE) [[ $v =~ ^(control|worker)$ ]] ;;
      API_ENDPOINT|NODE_IP) [[ $v =~ $ip ]] ;;
      OIF_API_VIP) [[ -z $v || $v =~ $ip ]] ;;
      JOIN_TOKEN) [[ $v =~ ^[a-z0-9]{6}\.[a-z0-9]{16}$ ]] ;;
      JOIN_CA_HASH) [[ $v =~ ^sha256:[0-9a-f]{64}$ ]] ;;
      JOIN_CERT_KEY) [[ -z $v || $v =~ ^[0-9a-f]{64}$ ]] ;;
      *) false ;;
    esac || die "unexpected join setting '$k'"
    printf -v "$k" '%s' "$v"
  done
  if [ -f "$JOINED_MARK" ]; then ok "already joined"; return 0; fi
  rec "TEARDOWN kubernetes"
  systemctl enable kubelet >/dev/null 2>&1
  export API_ENDPOINT JOIN_TOKEN JOIN_CA_HASH JOIN_CERT_KEY NODE_IP
  local tpl=kubeadm-join.yaml cfg=$STATE/kubeadm-join.yaml
  [ "$JOIN_ROLE" = control ] && tpl=kubeadm-join-control.yaml
  ( umask 077; render "$K8S_TEMPLATES/$tpl" > "$cfg" ) || die "cannot render the join configuration"
  log "kubeadm join as $JOIN_ROLE (pulls the images, 1-3 min)"
  if ! kubeadm join --config "$cfg" > "$STATE/kubeadm-join.log" 2>&1; then
    rm -f "$cfg"; grep -E '^\[|error|ERROR' "$STATE/kubeadm-join.log" | tail -20 | redact
    kubeadm reset -f >> "$STATE/kubeadm-join.log" 2>&1 || true
    die "kubeadm join failed (sudo less $STATE/kubeadm-join.log; journalctl -u kubelet)"
  fi
  rm -f "$cfg"
  grep -E '^\[(preflight|kubelet-start|control-plane-join|mark-control-plane)\]' "$STATE/kubeadm-join.log" | redact | tail -6
  [ "$JOIN_ROLE" = control ] && [ -n "$OIF_API_VIP" ] && kube_vip_manifest /etc/kubernetes/admin.conf "$NODE_IP"
  ok "joined the cluster at $API_ENDPOINT:6443 as $JOIN_ROLE"
}

# ---------------------------------------------------------------- GPUs across the cluster (T-122)
# The display-class PCI devices of one machine: "bdf vendor device driver" (sh, so the same text runs on every node)
GPU_SCAN='for d in /sys/bus/pci/devices/*; do case $(cat $d/class) in 0x03*) l=$(readlink $d/driver); echo "${d##*/} $(cat $d/vendor) $(cat $d/device) ${l##*/}";; esac; done'
gpu_inventory() {   # "label address kind bdf device driver" per NVIDIA or supported AMD compute GPU of every node
  local name addr role out bdf v d drv kind
  if ! multi_node; then   # one host: the GPUs chosen in the settings
    local b; for b in $(nv_targets); do echo "$(hostname -s) $HOST_IP nvidia $b $(pci_ids "$b" | cut -d: -f2) $(drv "$b")"; done
    for b in $(amd_targets); do echo "$(hostname -s) $HOST_IP amd $b $(pci_ids "$b" | cut -d: -f2) $(drv "$b")"; done
    return 0
  fi
  while read -r -u 3 name addr role; do
    if [ -n "$(host_prefix "$addr")" ]; then out=$(sh -c "$GPU_SCAN"); else out=$(node_ssh "$addr" "$GPU_SCAN") || die "cannot list the GPUs of $name ($addr)"; fi
    while read -r bdf v d drv; do
      [ -n "$bdf" ] || continue
      case $v in 0x10de) kind=nvidia ;; 0x1002) [[ " $AMD_COMPUTE_IDS " == *" ${d#0x} "* ]] || continue; kind=amd ;; *) continue ;; esac
      echo "$name $addr $kind $bdf ${d#0x} ${drv:-none}"
    done <<< "$out"
  done 3< <(nodes_list)
}
gpu_count() { gpu_inventory | awk -v k="$1" '$3 == k {n++} END {print n + 0}'; }   # nvidia | amd
allocatable_sum() {   # resource name: the sum over all nodes, e.g. nvidia.com/gpu
  kc get nodes -o json | python3 -c 'import json,sys; r=sys.argv[1]; print(sum(int(n["status"].get("allocatable",{}).get(r,"0")) for n in json.load(sys.stdin)["items"]))' "$1"; }
node_with() {   # resource name: the first node that offers it
  kc get nodes -o json | python3 -c 'import json,sys; r=sys.argv[1]; print(next((n["metadata"]["name"] for n in json.load(sys.stdin)["items"] if int(n["status"].get("allocatable",{}).get(r,"0"))>0), ""))' "$1"; }
on_gpu_node() {   # address command: run where that GPU is (this host or another node)
  if [ -n "$(host_prefix "$1")" ]; then bash -c "$2"; else node_ssh "$1" "$2"; fi; }
gpu_resource_is() { [ "$(allocatable_sum "$1")" = "$2" ]; }   # resource count: the cluster offers exactly that many
nodes_rev() {   # the node stages' list and code: a change reaches every node on the next install
  { echo "${NODE_STAGES[*]}"; cat "$OIF_HOME"/installer/stages/[0-3]0-*.sh; } | sha256sum | cut -c1-12; }
nvidia_driver_oldest() {   # the oldest NVIDIA driver version on any node with an NVIDIA GPU (empty: none)
  local name addr kind _r v out=""
  while read -r name addr kind _r; do
    [ "$kind" = nvidia ] || continue
    v=$(on_gpu_node "$addr" "nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1" 2>/dev/null) || v=""
    [ -n "$v" ] && out+="$v"$'\n'
  done < <(gpu_inventory)
  sort -V <<< "$out" | grep . | head -1 || true
}
