# T-121 — Highly Available Kubernetes Across Nodes

**Status:** Done (2026-10-26)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-017 · `installer/lib/60-nodes.sh` · `installer/stages/40-kubernetes.sh` · `tests/lab/t121-cluster.sh`

---

## 1. What T-121 delivers

| Capability | Description |
|------------|-------------|
| **HA Control Plane** | Three control-plane nodes sharing a virtual IP via **kube-vip**. The API address survives a node failure. |
| **Clean joins** | Other control-planes and workers join with short-lived tokens. Tokens and uploaded certificates are deleted immediately after use. |
| **Production-ready base** | Calico networking, MetalLB in the node subnet, **no control-plane taint** — workloads can run on every node. |

---

## 2. Lab topology (hybrid-gpu-lab)

```
┌─────────┐  ┌─────────┐  ┌─────────┐
│   cp1   │  │   cp2   │  │   cp3   │   ← Control plane (odd number for etcd majority)
│ (runs   │  │ joined  │  │ joined  │
│  oif)   │  │         │  │         │
└────┬────┘  └────┬────┘  └────┬────┘
     │            │            │
     └────────────┼────────────┘
                  │
           OIF_API_VIP  (kube-vip Lease)
                  │
     ┌────────────┼────────────┐
     │            │            │
┌────▼────┐  ┌────▼────┐
│ gpu-amd │  │gpu-nvidia│   ← Workers
│  W7900  │  │  A6000   │
└─────────┘  └─────────┘
```

- **cp1** is the first control-plane node (admin runs `oif` here).
- **cp2 / cp3** join as additional control-plane nodes.
- **gpu-amd** and **gpu-nvidia** join as pure workers.
- All nodes reach the Kubernetes API at the shared VIP (`OIF_API_VIP`).

---

## 3. End-to-end workflow

Admin runs `sudo ./oif install` on **cp1** only.

| Step | Action |
|------|--------|
| **01 Prepare nodes** | Create cluster SSH key on cp1, install it on every other node (once), run node stages (host packages, kernel, containerd, drivers, etc.) on each remote node. |
| **02 kubeadm init** | On cp1: render `kubeadm.yaml` with API endpoint = VIP, place kube-vip static pod, run `kubeadm init`. |
| **03 Join control planes** | Create short-lived token + upload certs → push join settings over SSH → `kubeadm join` as control-plane → place kube-vip on the new node → delete token. |
| **04 Join workers** | Same token flow, but without the certificate key; workers join as pure workers. |
| **05 Add-ons & cleanup** | Calico, local-path storage, MetalLB, verification. All remaining bootstrap tokens and the `kubeadm-certs` secret are deleted. |

### Design principles (ADR-017)

- **One entry point** — Admin runs `oif` only on the first control-plane node.
- **Same stages everywhere** — Each node keeps its own change record; uninstall is complete and reversible.
- **No long-lived secrets** — Join tokens and uploaded certificates exist only for the join window.

---

## 4. Cluster key & node stages

### SSH model

- `oif` creates its own ed25519 key on cp1 (`$STATE/ssh/id_ed25519`).
- Key is installed once on every other node (via the admin’s forwarded agent or a one-line `authorized_keys` entry).
- All subsequent traffic uses **only** that key (`IdentitiesOnly=yes`, `IdentityAgent=none`).
- Node stages run as `sudo` on the remote node; `oif` itself is copied each time.

### Per-node stages (`NODE_STAGES`)

```
preflight → host-packages → kernel → containerd
→ nvidia-driver / amd-firmware → gpu-isolation → reboot
→ host-verify → k8s-packages
```

---

## 5. kubeadm init + kube-vip

1. Render `kubeadm.yaml` — API endpoint set to `OIF_API_VIP` (or host IP for single-node).
2. Place kube-vip static pod (uses `super-admin.conf` during init).
3. Run `kubeadm init`.
4. Switch kube-vip credentials back to `admin.conf`.
5. Install user kubeconfig so `kubectl` works for the install user.

**Why kube-vip?**  
Pure Layer-2 VIP, no external load balancer required. Runs as a static pod so it starts early and survives etcd membership changes. Ownership is decided by a Kubernetes Lease (`plndr-cp-lock`).  
**Pinned version:** kube-vip v1.2.4

---

## 6. Joining the remaining nodes

### Control-plane join

1. Create short-lived token (TTL 30 min).
2. Upload control-plane certificates (`kubeadm init phase upload-certs`).
3. Push `oif` + join settings over SSH (role, endpoint, token, CA hash, cert key).
4. Remote: `kubeadm join --config` (kubeadm-join-control.yaml).
5. Place kube-vip static pod on the new control-plane node.
6. Delete the token immediately.

### Worker join

1. Create short-lived token.
2. Push join settings (no certificate key).
3. Remote: `kubeadm join --config` (kubeadm-join.yaml).
4. Delete the token.

**Security note**  
Tokens travel over SSH stdin and are never written to disk on the joining node longer than the join itself. After the stage finishes, `k8s-tokens` removes every remaining bootstrap token and the `kubeadm-certs` secret.

---

## 7. Acceptance checks (`tests/lab/t121-cluster.sh`)

| # | Check |
|---|-------|
| 01 | Every node Ready (exact count) |
| 02 | Correct number of control-plane nodes |
| 03 | No workload taints on control plane |
| 04 | One etcd member per control-plane node |
| 05 | One API server per control-plane node |
| 06 | No leftover join tokens |
| 07 | No uploaded control-plane certificates left |
| 08 | kubeconfig points at the API endpoint / VIP |
| 09 | API answers on the shared VIP |
| 10 | One kube-vip per control-plane node |
| + | **Failover** (optional `--failover`): VIP moves to another CP node; API stays answering |

**Lab result (2026-10-26):** 14 checks passed. API address moved from cp1 → cp2; the API answered throughout.

---

## 8. Key source files

| Path | Role |
|------|------|
| `installer/lib/60-nodes.sh` | SSH, node stages, join logic, kube-vip helper |
| `installer/stages/40-kubernetes.sh` | init, tokens, Calico, MetalLB, verify |
| `platform/kubernetes/kube-vip.yaml` | Static pod template (rendered per node) |
| `platform/kubernetes/kubeadm*.yaml` | Init & join configurations |
| `tests/lab/t121-cluster.sh` | 14-check acceptance + optional failover |
| `docs/DECISIONS.md` → ADR-017 | Multi-node design rationale |

---

## 9. Summary

| | |
|---|---|
| **Outcome** | 5 Ready nodes · HA API on a VIP · no leftover join secrets |
| **Mechanism** | kube-vip static pods + short-lived tokens over SSH stdin |
| **Safety** | Odd number of control planes · tokens deleted after use · full uninstall path |
| **Proof** | `tests/lab/t121-cluster.sh --failover` (VIP moved, API stayed up) |
| **Next** | T-122 GPUs on their nodes → T-123 Run:ai node pools |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
