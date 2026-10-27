# Presentations

Living documentation decks for major features and tasks in Open Inference Fabric.

Each completed (or substantial) T-xxx task gets a presentation that explains the workflow, architecture decisions, and how it was verified. These decks are updated as the modules evolve.

## Current decks

| Deck | Task | Status | Description |
|------|------|--------|-------------|
| [T-121 HA Kubernetes](T121-HA-Kubernetes-Workflow.md) | T-121 | Done | Highly available control plane with kube-vip, multi-node joins, Calico & MetalLB |

## Conventions

- **Primary format**: Markdown (renders natively on GitHub, easy to keep in sync with code).
- PPTX / PDF versions may be attached in Releases or generated on request.
- Filenames follow `Txxx-Short-Name.md`.
- Every deck links back to the relevant section of `TASKS.md`, `docs/DECISIONS.md` (ADRs), and the key source files.

## How these stay current

An automation watches the repository. When significant development lands (especially updates to `TASKS.md` or the installer modules), the corresponding presentation is regenerated or updated and committed here.

---

*Maintained as part of the open-inference-fabric documentation set.*
