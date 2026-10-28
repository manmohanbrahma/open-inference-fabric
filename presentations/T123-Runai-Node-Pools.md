# T-123 — Run:ai Node Pools per Vendor on Several Nodes

**Status:** In progress (substantial implementation landed 2026-10-28)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-015 · `installer/stages/60-runai.sh` · `installer/tools/runai_api.py` · `tests/lab/t123-runai.sh` · T-113 (single-node ResourceQuota)

---

## 1. What T-123 delivers

| Capability | Description |
|------------|-------------|
| **Vendor node pools** | On a multi-node cluster each GPU node is labelled `oif.ai/gpu-vendor=nvidia\|amd`. Run:ai node pools `nvidia` and `amd` are created from that label. |
| **Real per-vendor quotas** | Projects receive a GPU quota in every vendor's pool. A second request for a vendor whose pool is full waits in the Run:ai queue. |
| **Correct placement** | Workloads carry `runai/node-pool`. An NVIDIA request is never placed in the AMD pool (and vice versa). |
| **Patched images everywhere** | The oif-patched Run:ai images (cluster-sync, operator, frontend) are built on the oif node and loaded into containerd on every node. |
| **Single-node unchanged** | On one node the default pool is used and ADR-015's Kubernetes ResourceQuota still enforces the 1+1 split (T-113). |

A node that has both vendors stays in the default pool (one node cannot belong to two pools — ADR-015).

---

## 2. Architecture

```
┌──────────────────┐     oif.ai/gpu-vendor=nvidia     ┌──────────────────┐
│  gpu-nvidia    │ ──────────────────────────────▶ │  pool: nvidia  │
│  (A6000)       │                                 │  quota per    │
└──────────────────┘                                 │  project      │
                                                      └──────────────────┘
┌──────────────────┐     oif.ai/gpu-vendor=amd        ┌──────────────────┐
│  gpu-amd       │ ──────────────────────────────▶ │  pool: amd     │
│  (W7900)       │                                 │  quota per    │
└──────────────────┘                                 │  project      │
                                                      └──────────────────┘
         ▲
         │  stage runai-pools (after runai-verify, multi-node only)
         │  labels from cluster GPU inventory → creates pools → waits Ready
```

- **Label** `oif.ai/gpu-vendor` is applied by oif from the cluster-wide GPU inventory.
- **Pools** are ordinary Run:ai node pools (label key/value). They become Ready once Run:ai has synced the nodes and counted their GPUs.
- **Projects** created with `project-pools` receive a separate GPU quota in each vendor pool.
- **Pods** are annotated/labelled `runai/node-pool=<vendor>` so the scheduler places them only in that pool.
- **Images** are built in a Job pinned to the oif node (hostPath for source/caches) then imported on every other node via `ctr images import` over SSH.

---

## 3. Workflow steps

Admin runs `sudo ./oif install` on the first control-plane node (cp1).

| Step | Action |
|------|--------|
| **01 GPU inventory** | Cluster-wide discovery of NVIDIA and AMD devices (already done by earlier stages). |
| **02 Label nodes** | For each pure-vendor GPU node: `kubectl label node … oif.ai/gpu-vendor=nvidia\|amd`. Mixed nodes are left unlabelled (stay in default). |
| **03 Create pools** | `runai_api node-pool nvidia oif.ai/gpu-vendor nvidia` (and amd). Waits until each pool is Ready and reports the correct GPU count. |
| **04 Spread patched images** | Build Job is node-selected to the oif host. After the tarball is produced, `runai_patch_spread` loads it into containerd on every other node. |
| **05 Project quotas** | `runai_api project-pools team-c nvidia=1 amd=1` creates (or re-uses) the project with a quota of 1 GPU in each pool. |
| **06 Placement & queueing** | Test pods with `runai/node-pool` land on the matching vendor node. A second NVIDIA pod and an NVIDIA request aimed at pool amd both stay Pending. |

Single-node installs skip the pool stage and continue to use the default pool + ResourceQuota (T-113).

---

## 4. Key source files

| Path | Role |
|------|------|
| `installer/stages/60-runai.sh` | `stage_runai_pools`, `runai_pools_ok`, `pool_for`, image spread helpers, stage ordering after `runai-verify` |
| `installer/tools/runai_api.py` | `node-pool`, `pools`, `project-pools` commands; project creation with per-pool GPU resources |
| `platform/runai/quota-test.yaml` / `quota-test-amd.yaml` | Test pods that set `runai/node-pool: ${NODE_POOL}` |
| `platform/runai/patch-build-job.yaml` | Build Job pinned to the oif node (`nodeSelector: kubernetes.io/hostname`) |
| `installer/stages/70-gpu-amd.sh` | `vendor_quota_pools` (multi-node path of the T-113/T-123 quota test) |
| `tests/lab/t123-runai.sh` | Acceptance test: labels, Ready pools, images on every node, placement, quota queueing, cross-pool rejection |

---

## 5. Verification (`tests/lab/t123-runai.sh`)

Run on the first node after a full multi-node install:

```bash
sudo tests/lab/t123-runai.sh
```

| Check | Meaning |
|-------|---------|
| Node labels | Each GPU node carries the correct `oif.ai/gpu-vendor` |
| No stray labels | Non-GPU nodes are unlabelled |
| Pools Ready | `nvidia` and `amd` pools are Ready with the expected GPU counts |
| Patched images | cluster-sync, operator and frontend images present on every node |
| Placement | NVIDIA pod runs on the NVIDIA node; AMD pod on the AMD node |
| Quota queue | Second NVIDIA pod stays Pending |
| Cross-pool | NVIDIA request submitted to pool amd is never scheduled |

The test creates and deletes temporary pods in the team-c namespace; everything else is read-only.

---

## 6. Summary

| | |
|---|---|
| **Outcome** | Vendor-isolated node pools with real per-pool quotas; patched Run:ai images available cluster-wide |
| **Mechanism** | oif node label → Run:ai node pools → project resources per pool + `runai/node-pool` on workloads |
| **Single-node** | Unchanged (default pool + ResourceQuota, ADR-015) |
| **Mixed nodes** | Stay in the default pool |
| **Proof** | `tests/lab/t123-runai.sh` (labels, pools, images, placement, queueing) |
| **Next** | Finish T-123 acceptance on the hybrid-gpu-lab, then T-124 demonstration and guides |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
