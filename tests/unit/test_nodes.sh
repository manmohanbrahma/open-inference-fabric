#!/bin/bash
# Multi-node (ADR-017): node list checks, what a node is sent, the per-node runner with SSH stubbed out
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"

host_prefix() { [ "$1" = 192.168.120.11 ] && echo 192.168.120.11/24; }   # this host is cp1
HOST_IP=192.168.120.11

GOOD="cp1=192.168.120.11:control cp2=192.168.120.12:control cp3=192.168.120.13:control gpu-amd=192.168.120.21:worker gpu-nvidia=192.168.120.22:worker"
ok_ v_nodes "$GOOD"
ok_ v_nodes ""                                                            # single node
ok_ v_nodes "cp1=192.168.120.11:control gpu=192.168.120.21:worker"        # one control plane
no_ v_nodes "cp1=192.168.120.11:control"                                  # a list of one
no_ v_nodes "gpu=192.168.120.21:worker cp1=192.168.120.11:control"        # first must be a control-plane node
no_ v_nodes "cp2=192.168.120.12:control cp1=192.168.120.11:control"       # first must be this host
no_ v_nodes "cp1=192.168.120.11:control cp2=192.168.120.12:control"       # two control planes: no etcd majority
no_ v_nodes "cp1=192.168.120.11:control cp1=192.168.120.12:worker"        # name twice
no_ v_nodes "cp1=192.168.120.11:control cp2=192.168.120.11:worker"        # address twice
no_ v_nodes "cp1=192.168.120.11:master gpu=192.168.120.21:worker"         # unknown role
no_ v_nodes "CP1=192.168.120.11:control gpu=192.168.120.21:worker"        # not a host name
no_ v_nodes "cp1=192.168.120.300:control gpu=192.168.120.21:worker"       # not an address

OIF_NODES=$GOOD
eq "$(nodes_list | head -1)" "cp1 192.168.120.11 control" "first node:"
eq "$(other_nodes | wc -l | tr -d ' ')" 4 "other nodes:"
eq "$(other_nodes | tail -1)" "gpu-nvidia 192.168.120.22 worker" "last node:"
ok_ multi_node

ok_ v_vip 192.168.120.10
no_ v_vip ""                       # three control planes need an API address
no_ v_vip 192.168.120.12           # a node's address
no_ v_vip 10.0.0.10                # another subnet
OIF_NODES="cp1=192.168.120.11:control gpu=192.168.120.21:worker"
ok_ v_vip ""                       # one control plane: the node's own address serves the API
OIF_NODES=$GOOD

# a node gets its share of the settings, never the cluster's secrets
INSTALL_DIR=/data/oif INSTALL_USER=oif RUNAI_ADMIN_PASSWORD='S3cret!pw-xyz' HF_TOKEN=hf_secret NVIDIA_GPUS=0000:82:00.0 REBOOT_OK=yes
s=$(node_settings)
eq "$(echo "$s" | cut -d= -f1 | paste -sd' ')" "${NODE_SETTINGS[*]}" "settings sent to a node:"
case $s in *S3cret*|*hf_secret*) fail "a secret was sent to a node" ;; esac
echo "$s" | grep -qx "REBOOT_OK=no" || fail "a node must not reboot itself"
echo "$s" | grep -qx "NVIDIA_GPUS=''" || fail "a node uses every GPU it has"
echo "$s" | grep -qx "INSTALL_DIR=/data/oif" || fail "data folder not sent"

# authorized_keys: added once, removed exactly
H=$SANDBOX/home; mkdir -p "$H"
K='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOifTestKey00000000000000000000000000000 oif-cluster@cp1'
printf 'ssh-ed25519 AAAAadmin admin@pc\n' > "$SANDBOX/ak"; mkdir -p "$H/.ssh"; cp "$SANDBOX/ak" "$H/.ssh/authorized_keys"
HOME=$H bash -c "$(authorized_add "$K")"; HOME=$H bash -c "$(authorized_add "$K")"
eq "$(grep -cxF "$K" "$H/.ssh/authorized_keys")" 1 "key added once:"
HOME=$H bash -c "$(authorized_del "$K")"
eq "$(cat "$H/.ssh/authorized_keys")" "ssh-ed25519 AAAAadmin admin@pc" "only oif's key removed:"

# oif's SSH uses only its own key (a forwarded agent made a node look ready before the key was on it) and does not read
# stdin unless asked (ssh read the rest of the node list, so only the first node was checked)
ssh() { printf '%s\n' "$*"; }
a=$(node_ssh 192.168.120.12 true)
case " $a " in *" -n "*) ;; *) fail "node_ssh must not read stdin: $a" ;; esac
case $a in *IdentitiesOnly=yes*IdentityAgent=none*) ;; *) fail "node_ssh must not use an agent: $a" ;; esac
case $a in *ServerAliveInterval=*) ;; *) fail "node_ssh needs keepalives (a node going down mid-call hung the caller): $a" ;; esac
a=$(NODE_SSH_STDIN=1 node_ssh 192.168.120.12 true)
case " $a " in *" -n "*) fail "NODE_SSH_STDIN=1 must pass stdin" ;; esac
seen=$(while read -r -u 3 name addr role; do node_ssh "$addr" true >/dev/null; echo "$name"; done 3< <(other_nodes) | paste -sd' ')
eq "$seen" "cp2 cp3 gpu-amd gpu-nvidia" "every node visited in a loop:"
unset -f ssh

# the runner: a node that asks for a reboot once, then finishes
CALLS=$SANDBOX/calls; : > "$CALLS"; RUNS=$SANDBOX/runs; : > "$RUNS"   # the stub runs in a pipeline: count in a file
node_push() { echo "push $1" >> "$CALLS"; }
node_ssh() { local a=$1; shift; echo "ssh $a $*" >> "$CALLS"
  case "$*" in
    *"oif _node"*) cat >/dev/null; echo run >> "$RUNS"; echo "node log line"; [ "$(wc -l < "$RUNS")" = 1 ] && return "$NODE_REBOOT_RC"; return 0 ;;
    *boot_id*) echo old-boot ;;
  esac; }
wait_for() { echo "wait $1" >> "$CALLS"; }
( node_install gpu-nvidia 192.168.120.22 >/dev/null 2>&1 ) || fail "node_install did not finish"
eq "$(grep -c '^push 192.168.120.22' "$CALLS")" 2 "oif copied before each run:"
grep -q "ssh 192.168.120.22 sudo systemctl reboot" "$CALLS" || fail "node not rebooted after exit $NODE_REBOOT_RC"
grep -q "^wait gpu-nvidia back after the reboot" "$CALLS" || fail "no wait for the node to come back"
recorded "NODE 192.168.120.22 gpu-nvidia" || fail "node not recorded for uninstall"

# a node that asks for a reboot every time is given two, then the install stops
: > "$CALLS"; : > "$RUNS"
node_ssh() { local a=$1; shift; echo "ssh $a $*" >> "$CALLS"
  case "$*" in *"oif _node"*) cat >/dev/null; return "$NODE_REBOOT_RC" ;; *boot_id*) echo old-boot ;; esac; }
( node_install gpu-amd 192.168.120.21 >/dev/null 2>&1 ) && fail "endless reboots must stop the install"
eq "$(grep -c 'sudo systemctl reboot' "$CALLS")" 2 "reboots before giving up:"

# a failing node stops the install
node_ssh() { cat >/dev/null; return 1; }
( node_install gpu-amd 192.168.120.21 >/dev/null 2>&1 ) && fail "a failing node must stop the install"

# where every node reaches the API: the shared address with three control planes, else the first node
OIF_API_VIP=192.168.120.10; eq "$(api_endpoint)" 192.168.120.10 "API endpoint with a VIP:"
OIF_API_VIP=""; eq "$(api_endpoint)" 192.168.120.11 "API endpoint without a VIP:"

# the join settings a node accepts: each value in its exact form, nothing executed
J='JOIN_ROLE=control
API_ENDPOINT=192.168.120.10
JOIN_TOKEN=abcdef.0123456789abcdef
JOIN_CA_HASH=sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
JOIN_CERT_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
NODE_IP=192.168.120.12
OIF_API_VIP=192.168.120.10'
for bad in 'JOIN_ROLE=master' 'JOIN_TOKEN=$(touch /tmp/oif-pwned)' 'NODE_IP=1.2.3' 'JOIN_CA_HASH=md5:00' 'HF_TOKEN=x'; do
  ( printf '%s\n' "$bad" | node_join >/dev/null 2>&1 ) && fail "join setting accepted: $bad"
done
[ -e /tmp/oif-pwned ] && fail "a join value was executed"
# valid settings reach kubeadm join (stubbed, like systemctl: nothing on this host changes); a worker writes no kube-vip pod
kubeadm() { echo "kubeadm $*" >> "$SANDBOX/kubeadm"; return 0; }
systemctl() { :; }
K8S_TEMPLATES=$ROOT/platform/kubernetes
( printf '%s\n' "${J/JOIN_ROLE=control/JOIN_ROLE=worker}" | node_join >/dev/null 2>&1 ) || fail "valid join settings refused"
grep -q "join --config" "$SANDBOX/kubeadm" 2>/dev/null || fail "valid join settings did not reach kubeadm join"
recorded "TEARDOWN kubernetes" || fail "a joined node must record its Kubernetes teardown"
[ -e "$OIF_STATE/kubeadm-join.yaml" ] && fail "the join configuration (token) must be deleted after the join"
unset -f kubeadm systemctl

# a node refuses settings it does not expect
( printf 'RUNAI_ADMIN_PASSWORD=x\n' | node_worker >/dev/null 2>&1 ) && fail "node accepted an unexpected setting"

finish
