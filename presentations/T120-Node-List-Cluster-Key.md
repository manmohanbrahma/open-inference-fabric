# T-120 — Node List, Cluster SSH Key and Per-Node Runner

**Status:** Done (2026-10-26)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-017 · `installer/lib/60-nodes.sh` · `tests/lab/t120-nodes.sh` · `tests/unit/test_nodes.sh`

---

## 1. What T-120 delivers

| Capability | Description |
|------------|-------------|
| **Node list** | `OIF_NODES` describes the cluster (`[label=]address:control\|worker`). First entry must be this host (control-plane). Odd number of control planes. |
| **Cluster SSH key** | oif creates its own ed25519 key on the first node and installs it once on every other node (via admin agent or manual authorized_keys). All later traffic uses only that key. |
| **Per-node runner** | Copies oif to each node and runs the node stages (`oif _node`) with only the settings a node needs. Reboots and resumes when a stage requests it (exit 75). |
| **Own records** | Each node keeps its own change record and uninstall path. Uninstall on the first node cleans every node. |

Single-node installs are unchanged (empty `OIF_NODES`).

---

## 2. End-to-end workflow

Admin runs `sudo ./oif install` (or `--until nodes`) on the first control-plane node only.

| Step | Action |
|------|--------|
| **Questions** | Validate `OIF_NODES` and (when needed) `OIF_API_VIP`. Create cluster key. Install it on other nodes through the forwarded agent, or print the public key for manual addition. Optionally add the admin's key to other control-plane nodes. |
| **nodes stage** | For each other node: copy oif (no `.git`, no settings), push the small node-settings file, run node stages, reboot + resume if exit 75 (at most twice). |
| **Later stages** | Kubernetes, GPU operators, etc. continue on the first node and (via later join logic) on the others. |

### Design principles (ADR-017)

- One entry point — admin runs oif only on the first control-plane node.
- Cluster key only — `IdentitiesOnly=yes`, `IdentityAgent=none`; no agent forwarding after initial key install.
- Minimal data over the wire — node stages receive only `NODE_SETTINGS` (no secrets, empty GPU lists so the node discovers its own hardware).
- Reversible — each node records its own changes; uninstall walks every node.

---

## 3. Node list and validation

```
OIF_NODES="cp1=192.168.120.11:control 192.168.120.12:control 192.168.120.13:control gpu-amd=192.168.120.21:worker gpu-nvidia=192.168.120.22:worker"
```

- Labels are optional (used in logs and records). Kubernetes names nodes by hostname either way.
- First entry must be this host and a control-plane node.
- Odd number of control-plane nodes (etcd majority).
- With ≥3 control planes, `OIF_API_VIP` is required (free address on the first node's subnet).

---

## 4. Cluster key and SSH model

- Key lives at `$STATE/ssh/id_ed25519` (root-only, mode 600).
- Initial install uses the admin's forwarded agent (or prints the public key).
- Subsequent calls: `ssh -i $CLUSTER_KEY -o IdentitiesOnly=yes -o IdentityAgent=none -o ServerAliveInterval=5 …`.
- Stdin is not consumed by default (`-n`) so loops over the node list stay intact; `NODE_SSH_STDIN=1` for the two calls that push data.
- Keep-alives prevent hangs when a node reboots mid-call.

---

## 5. Per-node stages and runner

Node stages (`NODE_STAGES`):

```
preflight → host-packages → kernel → containerd
→ nvidia-driver / amd-firmware → gpu-isolation → reboot
→ host-verify → k8s-packages
```

The runner (`node_install`):

1. Push a clean copy of oif to `/var/lib/oif/src`.
2. Pipe only the node settings.
3. Run `sudo …/oif _node`.
4. On exit 75: reboot the node, wait for a new boot_id (up to 10 min), repeat (max twice).
5. Record `NODE` and `NODEKEY` for later uninstall.

Each node keeps its own `/var/lib/oif/manifest` and done-flags.

---

## 6. Acceptance checks (`tests/lab/t120-nodes.sh`)

| Category | Checks |
|----------|--------|
| List | Multi-node, first node is this host |
| Key | Exists, root-only, mode 600 |
| Per node | Reachable with cluster key only, sudo NOPASSWD, oif copied, every node stage done, only node settings present, own manifest |
| NVIDIA nodes | Driver loaded, nouveau blocked |
| Optional | `--reboot NODE` reboots and waits for return |

**Lab result (2026-10-26):** 63 checks passed. gpu-nvidia came back after reboot in 27 s.

Unit tests cover node-list rules, VIP, settings filtering, authorized_keys add/remove, and the runner (SSH stubbed).

---

## 7. Key source files

| Path | Role |
|------|------|
| `installer/lib/60-nodes.sh` | Node list, cluster key, SSH helpers, node runner, uninstall walker |
| `installer/stages/40-kubernetes.sh` | Registers the `nodes` stage (before kubernetes) |
| `tests/lab/t120-nodes.sh` | Lab acceptance (63 checks + optional reboot) |
| `tests/unit/test_nodes.sh` | Unit coverage of list rules, VIP, settings, runner |
| `docs/DECISIONS.md` → ADR-017 | Multi-node design |

---

## 8. Summary

| | |
|---|---|
| **Outcome** | Every other node prepared with the same node stages, reachable only by the cluster key, ready for HA join and GPU work |
| **Mechanism** | One-time key install + per-node copy-and-run with reboot resume |
| **Safety** | No long-lived admin agent, no secrets on nodes, full uninstall path |
| **Proof** | `tests/lab/t120-nodes.sh` (63 checks) and unit tests |
| **Next** | T-121 HA Kubernetes (kube-vip + joins) → T-122 GPUs on their nodes |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
