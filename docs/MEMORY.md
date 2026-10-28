# Memory

Current state of the project. Update after every task.

## Status (2026-10-28)

- Phase 0: research and project documents written (T-001). Repository public at github.com/manmohanbrahma/open-inference-fabric (T-002).
- **P1.1** (single-node NVIDIA stack) done through T-107: host prep, kubeadm, NVIDIA GPU Operator, Run:ai 3.0.20, observability, uninstall/reinstall verified on the reference host.
- **P1.2** (AMD on the same node) done through T-115: AMD GPU Operator v1.5.1, dual-vendor recording rules and dashboards, per-vendor ResourceQuota (ADR-015), Run:ai patches so AMD GPUs appear in inventory and UI (ADR-016).
- **P1.3** multi-node hybrid cluster on [hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab) (cp1–3, gpu-amd W7900, gpu-nvidia A6000):
  - [x] T-119 lab VMs with GPU passthrough
  - [x] T-120 node list, cluster SSH key, per-node runner (`tests/lab/t120-nodes.sh`, 63 checks)
  - [x] T-121 HA Kubernetes with kube-vip on `OIF_API_VIP` (`tests/lab/t121-cluster.sh --failover`, 14 checks)
  - [x] T-122 GPUs on their nodes (`tests/lab/t122-gpus.sh`, 20 checks)
  - [ ] T-123 Run:ai node pools `nvidia` / `amd`
  - [ ] T-124 demonstration and multi-node guides
- **P1.4 Topology & Intent** defined (ADR-019 accepted, ADR-020 testing strategy):
  - Design: `docs/design/Vendor-Agnostic-Job-Model.md`
  - Lab acceptance: `docs/design/P1.4-Lab-Acceptance-Checks.md`
  - Tasks T-130 – T-136 in TASKS.md (not started)
- Product docs: PRD v0.1, Product Strategy presentation, AMD pitch deck (artifact), SDLC.md
- Presentations for T-120, T-121, T-122 and product strategy under `presentations/`
- Guide 9 (uninstall) written; guides 1–8 remain single-node focused until T-124

## Plan

Three projects (ADR-010): Project 1 orchestration (Run:ai on NVIDIA, then AMD, then multi-node HA, then topology & intent), Project 2 Dynamo serving and fair benchmark, Project 3 AI gateway and self-service API (ADR-018 proposed).

Process: [docs/SDLC.md](SDLC.md).

## Current task

Next implementation work: **T-123** (Run:ai on several nodes: node pools from oif labels, per-pool quotas, patched images on every node). Then T-124 demonstration and guides.

Still open from earlier slices: T-108 GPU fractions (needs driver ≥ r615), T-116 KAI vendor-aware placement on mixed nodes, T-003 CI.

P1.4 (T-130+) is defined and ready to start after P1.3 checkpoint (or in parallel for design-only work).

## Multi-agent note

- **Claude Code**: implementation (installer, stages, tests, guides from real runs).
- **Grok**: architecture, ADRs, PRD, design docs, presentations, acceptance criteria, SDLC alignment.
- Shared contract: TASKS.md + ADRs + RULES.md + SDLC.md. Claim tasks with `[~]` and agent name.

## Notes

- Multi-node design is ADR-017: one entry point on the first control-plane node; same stages and own change record on every node; cluster key only after initial install; uninstall walks every node.
- Single-node remains the default when `OIF_NODES` is empty.
- Vendor-agnostic job surface and AcceleratorDomain: ADR-019; testing environments ADR-020.
- Lab acceptance scripts: `tests/lab/t120-nodes.sh`, `t121-cluster.sh`, `t122-gpus.sh`. Host clean check: `tests/host/verify-clean.sh`.
- The reference host has no `curl` or `git` out of the box; oif uses Python and `wget`.
- Every step ships with a guide in `docs/guides/` (owner's rule, 2026-10-24).

## Known issues and risks

- Dynamo has no official ROCm support (ADR-002); decided by S-1.
- SGLang ROCm builds target Instinct GPUs; serving on the W7900 (gfx1100) is unproven (S-5).
- Run:ai GPU quotas count both vendors as one; per-vendor caps on a mixed node use ResourceQuota (ADR-015). On multi-node with one vendor per server, real node pools replace that (T-123).
- The KAI scheduler can bind an NVIDIA pod when only the AMD GPU is free on a mixed node; T-116.
- With GPU fractions off (T-108), patched Run:ai shows Missing prerequisites while whole-GPU workloads still run.
- Kernel 7.0 inbox amdgpu reports phantom UMC ECC errors on the W7900; the AMD metrics exporter needs a raised threshold.
- Both GPUs throttle when loaded together on the reference chassis (ADR-009).
- Multi-GPU AMD domains and Instinct-class hardware not yet available for full P1.4 / P2 validation (see AMD pitch).
