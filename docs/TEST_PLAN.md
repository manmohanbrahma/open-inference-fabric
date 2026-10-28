# Test Plan

What "working" means, layer by layer. Every check is automated in `tests/` unless marked manual.

Related: [SDLC.md](SDLC.md), [ADR-020](DECISIONS.md), [design/P1.4-Lab-Acceptance-Checks.md](design/P1.4-Lab-Acceptance-Checks.md).

---

## Static checks (every commit, CI — T-003)

- `shellcheck` on all shell scripts
- `yamllint` on manifests and values
- `promtool check rules` and `promtool test rules`
- Grafana dashboards are valid JSON and use only `oif:*` series (or documented exceptions)
- Markdown links resolve
- gitleaks finds no secrets

---

## Installer

- `oif check` on a clean host reports OS, CPU, memory, GPUs and drivers and writes nothing (no state folder afterwards).
- `oif install` completes; running it again reports every stage as done and changes nothing.
- Interrupting the install (kill the job) and re-running resumes at the failed stage.
- `oif uninstall` leaves no kubelet/containerd services, Kubernetes folders, mounts, CNI links, fstab entries, or packages the installer added; `tests/host/verify-clean.sh` passes; `oif status` then reports nothing installed.
- Multi-node: uninstall walks every node in `OIF_NODES` and removes the cluster key (ADR-017).

---

## GPU enablement

- Node allocatable shows the expected `nvidia.com/gpu` and/or `amd.com/gpu` counts.
- Node labels give each GPU's product name and memory where the operator provides them.
- A test pod requesting each GPU sees exactly one device (`nvidia-smi -L`, `rocm-smi`); excluded GPUs (vfio) are never visible.
- Multi-node (T-122): operators installed only where that vendor is present; inventory correct over the cluster key.

---

## Orchestration

- With a project quota of one GPU per vendor (single-node ResourceQuota or multi-node pools), the first pod per vendor runs and the second stays pending with a quota reason; deleting the first lets the second run.
- Multi-node (T-123): workloads land only on the node pool of the GPU they request.
- HA (T-121): API VIP survives control-plane node failure; lab script `--failover` passes.

---

## Topology & intent (P1.4 — when implemented)

See [design/P1.4-Lab-Acceptance-Checks.md](design/P1.4-Lab-Acceptance-Checks.md) for numbered checks:

- AcceleratorDomain objects exist and match vendor/capacity
- Domain-aware packing for multi-GPU jobs with `requireSameDomain`
- AIJob vendor-agnostic submit and PlacementPolicy defaults
- Status shows vendor, domain, crossVendor
- Direct `nvidia.com/gpu` / `amd.com/gpu` jobs still work (regression)
- Domain and cross-vendor metrics under `oif:*`

---

## Serving (Project 2)

- Chat completion through the single endpoint for each model name (NVIDIA and AMD), non-streaming and streaming.
- `/v1/models` lists both models.
- 64 concurrent requests per GPU complete without errors (or documented limit).
- Restarting a worker pod: the frontend stops routing to it and resumes when it is Ready.

---

## Performance (Project 2)

- `oif bench` runs the sweep on each GPU, one GPU at a time, after the temperature guard (ADR-009).
- Zero failed requests; results include versions, image digests and the exact AIPerf command.
- Re-running the same profile gives output tokens/s within ±5 % (manual review of the first runs).
- Fair comparison reports list any engine version differences explicitly (ADR-011, ADR-012).

---

## Observability

- Fleet and Scheduling panels show data during load on the reference host / lab.
- `oif:gpu_*` series exist for both vendors with labels `vendor`, `model`, `gpu`, `node` (as applicable).
- Benchmark runs appear as Grafana annotations when bench is implemented.
- The AMD exporter does not mark the W7900 unhealthy on kernel 7.0 (ECC threshold applied).

---

## Regression gate (every significant change)

| Check | Must pass |
|-------|-----------|
| T-121 HA (lab) | Control plane failover |
| T-122 GPUs on nodes (lab) | Operators and inventory |
| verify-clean (reference host) | Uninstall cleanliness |
| Dual-vendor quota / dashboard behaviour | No regression in T-113 / T-114 |

---

## Environments

| Environment | Primary use |
|-------------|-------------|
| Reference host (A6000 + W7900) | Single-node install/uninstall, mixed-node quotas, dual-vendor telemetry |
| hybrid-gpu-lab | Multi-node HA, one vendor per worker, topology, failover |
| NVIDIA DSX | Optional NVIDIA-side only — not a multi-vendor gate (ADR-020) |

---

## Responsive output (reports and docs)

- Benchmark report and guides render at 375 px, 768 px and 1440 px without horizontal scrolling (manual).
