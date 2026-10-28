# Presentations

Living documentation decks for major features and tasks in Open Inference Fabric.

Each completed (or substantial) T-xxx task gets a presentation that explains the workflow, architecture decisions, and how it was verified. These decks are updated as the modules evolve.

## Product-level

| Deck | Description |
|------|-------------|
| [Product Strategy](OIF-Product-Strategy.md) | Positioning, market, uniqueness, roadmap and success metrics |
| [PRD](../docs/PRD.md) | Formal Product Requirements Document (v0.1) |

## Feature / Task decks

| Deck | Task | Status | Description |
|------|------|--------|-------------|
| [T-119 KVM Hybrid GPU Lab](T119-KVM-Hybrid-GPU-Lab.md) | T-119 | Done | Repeatable KVM lab (hybrid-gpu-lab): 3 control-plane + 2 GPU workers with PCI passthrough |
| [T-120 Node List & Cluster Key](T120-Node-List-Cluster-Key.md) | T-120 | Done | Node list (`OIF_NODES`), cluster SSH key, per-node stage runner with reboot resume |
| [T-121 HA Kubernetes](T121-HA-Kubernetes-Workflow.md) | T-121 | Done | Highly available control plane with kube-vip, multi-node joins, Calico & MetalLB |
| [T-122 GPUs on Their Nodes](T122-GPUs-On-Their-Nodes.md) | T-122 | Done | Per-node GPU inventory, vendor drivers/firmware, conditional GPU Operators, correct resource placement |
| [T-123 Run:ai Node Pools](T123-Runai-Node-Pools.md) | T-123 | Done | Per-vendor Run:ai node pools (`nvidia`/`amd`) from oif labels, pool quotas, patched images on every node (27 checks PASS) |

## Conventions

- **Primary format**: Markdown (renders natively on GitHub, easy to keep in sync with code).
- PPTX / PDF versions may be attached in Releases or generated on request.
- Filenames follow `Txxx-Short-Name.md` for task decks; product-level decks use descriptive names.
- Every deck links back to the relevant section of `TASKS.md`, `docs/DECISIONS.md` (ADRs), and the key source files.

## How these stay current

An automation watches the repository. When significant development lands (especially updates to `TASKS.md` or the installer modules), the corresponding presentation is regenerated or updated and committed here.

---

*Maintained as part of the open-inference-fabric documentation set.*
