# Architecture

## Layers

```text
 Clients ─ OpenAI-compatible API ─ AIPerf (oif bench) ─ Grafana / Run:ai UI
                                   │
 ┌─────────────────────────────────▼─────────────────────────────────────────┐
 │ Serving        Dynamo Frontend + Router  (one endpoint, routes by model)  │
 │                ├─ worker: dynamo.vllm  on CUDA  (RTX A6000)               │
 │                └─ worker: dynamo.vllm  on ROCm  (Radeon PRO W7900)        │
 │                Dynamo operator (DynamoGraphDeployment CRDs)               │
 ├───────────────────────────────────────────────────────────────────────────┤
 │ Orchestration  Run:ai control plane + cluster services                    │
 │                KAI Scheduler (queues, quotas, gang, bin-packing)          │
 │                node pools: nvidia, amd  (multi-node; T-123)               │
 ├───────────────────────────────────────────────────────────────────────────┤
 │ Observability  Prometheus + Grafana + Alertmanager (kube-prometheus-stack)│
 │                DCGM exporter · AMD device metrics exporter · node exporter│
 │                Dynamo / vLLM / KAI metrics · OIF recording rules          │
 ├───────────────────────────────────────────────────────────────────────────┤
 │ GPU enablement NVIDIA GPU Operator (host driver, toolkit, device plugin)  │
 │                AMD GPU Operator (in-kernel amdgpu, device plugin,         │
 │                labeller, metrics exporter)                                │
 ├───────────────────────────────────────────────────────────────────────────┤
 │ Kubernetes     kubeadm 1.35, containerd, Calico, local-path storage,      │
 │                MetalLB; single node, or multi-node HA with kube-vip       │
 │                (OIF_API_VIP) and no control-plane taint (ADR-017)         │
 ├───────────────────────────────────────────────────────────────────────────┤
 │ Host           Ubuntu 26.04, NVIDIA driver (Ubuntu archive), amdgpu       │
 │                (in kernel), vfio for GPUs kept out of Kubernetes          │
 └───────────────────────────────────────────────────────────────────────────┘
```

## Multi-node topology (P1.3)

When `OIF_NODES` is set, the admin runs `oif` only on the first control-plane node. oif creates a cluster SSH key, prepares every other node with the same node stages (each node keeps its own change record), then forms an HA control plane and joins workers.

```text
  cp1 (runs oif) ──┐
  cp2              ├── OIF_API_VIP (kube-vip Lease) ── API clients
  cp3              ┘
  gpu-amd   (W7900, amd.com/gpu)
  gpu-nvidia (A6000, nvidia.com/gpu)
```

- GPU inventory and drivers follow PCI devices on each node (T-122).
- Operators install only when at least one node has that vendor.
- Uninstall on cp1 walks every node and removes the cluster key (and any admin key oif added).

Single-node installs are unchanged: empty `OIF_NODES` keeps the original path.

## Request flow

`client → Dynamo Frontend (HTTP, OpenAI API) → Router → worker on the GPU that serves the requested model → engine (vLLM) → GPU`

The model name selects the vendor in v0.1, for example `qwen3-0.6b-nvidia` and `qwen3-0.6b-amd`. A later version can register both workers under one model name and let the router balance across vendors.

## Scheduling flow

`DynamoGraphDeployment (or Run:ai inference workload) → pods labelled with the Run:ai project / KAI queue → KAI Scheduler checks the queue's quota and the node pool → pod bound to a node with nvidia.com/gpu or amd.com/gpu → device plugin assigns the GPU`

On a single mixed node, per-vendor caps use a Kubernetes ResourceQuota (ADR-015). On multi-node with one vendor per server, Run:ai node pools provide real per-vendor quotas (T-123).

## Telemetry flow

| Layer | Source | Examples |
| --- | --- | --- |
| Hardware, NVIDIA | DCGM exporter (GPU Operator) | `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP`, clocks, XID errors |
| Hardware, AMD | AMD device metrics exporter (GPU Operator) | `gpu_gfx_activity`, `gpu_used_vram`, `gpu_power_usage`, `gpu_edge_temperature`, `gpu_junction_temperature`, clocks, ECC |
| Hardware, host | node exporter | CPU, memory, NUMA, disk, network, PCIe-adjacent host load |
| Software, scheduling | KAI Scheduler, Run:ai | queue allocation, pending pods, scheduling latency |
| Software, serving | Dynamo frontend and workers, vLLM | request rate, TTFT, inter-token latency, end-to-end latency, tokens/s, KV cache usage, queue depth, errors |
| Software, benchmark | AIPerf | per-run TTFT, ITL, throughput percentiles (JSON artifacts, optionally pushed as metrics) |

**Normalisation.** Prometheus recording rules map both vendors onto one schema, `oif:gpu_*{vendor, model, gpu, node}`: `oif:gpu_util_ratio`, `oif:gpu_mem_used_bytes`, `oif:gpu_mem_total_bytes`, `oif:gpu_power_watts`, `oif:gpu_temp_celsius`, `oif:gpu_sm_clock_hz`. Dashboards use only `oif:*` series, so one panel shows both vendors.

## Repository layout

```text
open-inference-fabric/
├── oif                     # CLI entry point (bash): install, uninstall, status, bench, ...
├── installer/
│   ├── lib/                # output, settings, host facts, packages, reboots, nodes, manifest
│   └── stages/             # NN-name.sh: one install stage each, registered in order
├── versions.env            # every pinned version and image tag
├── platform/               # Helm values and manifests per component
│   ├── kubernetes/  gpu-nvidia/  gpu-amd/  runai/  dynamo/  observability/
├── images/
│   └── dynamo-vllm-rocm/   # Containerfile: ROCm vLLM base + Dynamo runtime
├── serving/                # DynamoGraphDeployment examples per GPU
├── bench/                  # AIPerf profiles, runner Job, report generator
├── observability/
│   ├── rules/              # oif:* recording rules
│   └── dashboards/         # Fleet, Serving, Scheduling (Grafana JSON)
├── presentations/          # workflow decks for completed major tasks
├── tests/                  # unit, lab (multi-node), host clean checks
├── docs/                   # PRD, ARCHITECTURE, DESIGN, RULES, DECISIONS, MEMORY
│   └── guides/             # install and deployment guide per step
├── TASKS.md  CLAUDE.md  README.md  .env.example
```

## Architectural rules

- Every component is installed by a stage of `oif install` from pinned versions in `versions.env`; nothing is applied by hand.
- Every host change is recorded so `oif uninstall` can reverse it (pattern proven in `nai-on-nkp.sh`). On multi-node, each node keeps its own record; uninstall from the first control-plane node walks the others.
- Vendor differences stay in `platform/gpu-*`, `images/` and `observability/rules/`. Higher layers (scheduling, serving manifests, dashboards, benchmarks) are vendor-neutral.
- Workloads request GPUs only through the scheduler and node pools; no pod pins a node by name.
- Benchmarks run inside the cluster as Jobs, so results exclude laptop and VPN latency, and record the exact image, engine flags and versions with the results.
- Lab-specific values (addresses, host names, tokens) come from `.env`, never from tracked files.
