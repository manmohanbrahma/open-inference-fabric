# T-122 — GPUs on Their Nodes

**Status:** Done (2026-10-26)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-017 · `installer/stages/30-gpu-host.sh` · `installer/lib/60-nodes.sh` · `tests/lab/t122-gpus.sh`

---

## 1. What T-122 delivers

| Capability | Description |
|------------|-------------|
| **Per-node GPU inventory** | Cluster-wide discovery of NVIDIA and supported AMD compute GPUs over the cluster SSH key. |
| **Vendor-correct drivers** | NVIDIA driver (Ubuntu archive, nouveau blacklisted) only on NVIDIA nodes; AMD firmware + amdgpu reload on AMD nodes. |
| **Conditional operators** | NVIDIA GPU Operator and AMD GPU Operator install only when at least one node has that vendor's GPU; checks target the correct nodes. |
| **Clean placement** | GPU resources (`nvidia.com/gpu`, `amd.com/gpu`) appear only on nodes that have the matching hardware. |

---

## 2. Lab topology reminder

Same hybrid-gpu-lab as T-121:

- **gpu-nvidia** — A6000 (NVIDIA)
- **gpu-amd** — W7900 (AMD)
- Control-plane nodes have no GPUs

Production intent: one vendor per server.

---

## 3. End-to-end workflow

Admin still runs `sudo ./oif install` only on **cp1**.

| Step | Action |
|------|--------|
| **Node stages** | On each remote node (via cluster key): `nvidia-driver` (if NVIDIA GPUs), new `amd-firmware` (if AMD compute GPUs), `gpu-isolation`, `reboot` if needed, `host-verify`. |
| **GPU inventory** | `gpu_inventory` lists every node's GPUs (BDF, driver, device) over SSH. |
| **Operators** | Install NVIDIA GPU Operator if any NVIDIA GPU exists; install AMD GPU Operator if any AMD GPU exists. Stages ordered so AMD operator runs before platform components that depend on it. |
| **Verification** | Resource counts match inventory; test pods land only on the correct vendor's node and see only that GPU. |

### Design notes

- Minimal images (lab VMs) lack AMD GPU firmware → `amd-firmware` installs `linux-firmware-amd-graphics` and reloads amdgpu when it holds no device.
- Full Ubuntu installs already have the firmware; the stage is a no-op.
- AMD exporter Service uses `internalTrafficPolicy: Local`, so metrics checks query the exporter pod via EndpointSlice.

---

## 4. New node stage: `amd-firmware`

From `installer/stages/30-gpu-host.sh`:

- Detects AMD compute targets.
- If already on amdgpu with `/dev/kfd`, skip.
- Installs firmware package.
- Reloads `amdgpu` if it is loaded but holds no devices (pipefail-safe lsmod read).
- Falls back to reboot request if still down.

NVIDIA path continues to blacklist nouveau and install the headless open driver.

---

## 5. Acceptance checks (`tests/lab/t122-gpus.sh`)

| Category | Checks |
|----------|--------|
| Inventory | ≥1 NVIDIA + ≥1 AMD GPU |
| Per-node | Correct driver, nvidia-smi / /dev/kfd, node offers matching resource |
| Cluster | Exactly N nvidia.com/gpu and M amd.com/gpu; non-GPU nodes offer none |
| Operators | ClusterPolicy ready; AMD device plugin desired == ready |
| Placement | NVIDIA pod on NVIDIA node sees GPU and no /dev/kfd; AMD pod on AMD node sees /dev/kfd + renderD and no /dev/nvidia0 |
| Exporters | DCGM reports NVIDIA temp; AMD exporter reports edge temperature |

**Lab result (2026-10-26):** 20 checks passed. W7900 on amdgpu with /dev/kfd on gpu-amd; A6000 on nvidia on gpu-nvidia; exactly one of each resource; pods on the correct nodes.

---

## 6. Key source files

| Path | Role |
|------|------|
| `installer/stages/30-gpu-host.sh` | nvidia-driver, amd-firmware, gpu-isolation, reboot, host-verify |
| `installer/lib/60-nodes.sh` | Cluster SSH, gpu_inventory, on_gpu_node helpers |
| `installer/stages/50-gpu-nvidia.sh` | NVIDIA GPU Operator (conditional) |
| `installer/stages/70-gpu-amd.sh` | AMD GPU Operator (conditional, staged early) |
| `tests/lab/t122-gpus.sh` | 20-check acceptance (creates short-lived test pods) |
| `docs/DECISIONS.md` → ADR-017 | Multi-node design |

---

## 7. Summary

| | |
|---|---|
| **Outcome** | GPUs appear only on their nodes with the correct drivers and operators; resources match hardware |
| **Mechanism** | Cluster inventory + conditional stages + vendor-specific node stages |
| **Safety** | No GPU resources on control-plane or non-GPU nodes; full uninstall path preserved |
| **Proof** | `tests/lab/t122-gpus.sh` (20 checks, pods land correctly) |
| **Next** | T-123 Run:ai node pools (`nvidia` / `amd`) for real per-vendor quotas |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
