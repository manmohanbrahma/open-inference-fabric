# Product Requirements Document

## Product

**Open Inference Fabric (OIF)**: an open-source suite that turns one or more Linux GPU servers with NVIDIA and AMD GPUs into a single, scheduled, observable LLM serving platform.

## Problem

Teams that own both NVIDIA and AMD GPUs run a separate stack per vendor:

- Each vendor has its own device plugin, metrics exporter and dashboards, so GPU health and load cannot be seen or compared in one place.
- Models are served differently on each vendor, behind different endpoints, so applications must know which GPU they are using.
- There is no shared scheduling or quota layer across vendors: whoever deploys first takes the GPU.
- Performance claims ("the W7900 is as fast as the A6000") are made with different tools and settings, so results are not comparable.

NVIDIA has open-sourced the pieces needed to solve this on Kubernetes (Run:ai with the KAI Scheduler, and Dynamo with vLLM, SGLang and TensorRT-LLM back ends), but they target NVIDIA hardware and are not assembled into one installable suite that also covers AMD.

## Target users

| User | Need |
| --- | --- |
| Platform engineer / AI infrastructure admin (primary) | Install, operate and remove the platform on on-prem GPU servers; share GPUs between teams with quotas |
| ML / application engineer | One OpenAI-compatible API, whatever GPU vendor serves the model |
| Performance engineer | Repeatable, comparable benchmarks across GPUs and engines, with hardware telemetry next to the results |

## Goal

From a clean Ubuntu server, one installer builds a Kubernetes platform where:

1. **Orchestration**: the open-source Run:ai platform (KAI Scheduler, projects, quotas, node pools) decides which workload gets which GPU, for NVIDIA and AMD.
2. **Serving**: NVIDIA Dynamo serves models with vLLM (and later SGLang and TensorRT-LLM) behind one OpenAI-compatible endpoint, on NVIDIA GPUs and, through a ROCm build, on AMD GPUs.
3. **Performance**: AIPerf runs standard benchmark profiles against any endpoint and produces a comparable report.
4. **Observability**: one Prometheus and Grafana show the hardware layer (utilisation, memory, power, temperature, clocks, errors, throttling) and the software layer (scheduling, queueing, TTFT, inter-token latency, throughput, KV cache, errors) for both vendors with the same metric names.

## Core features

1. Installer and uninstaller (`oif`)
2. GPU enablement for NVIDIA and AMD
3. Orchestration with Run:ai / KAI
4. Model serving with Dynamo (NVIDIA, and AMD via ROCm)
5. Performance testing with AIPerf
6. Hardware and software telemetry with vendor-neutral dashboards

## MVP (v0.1)

Prove one model on both GPUs, scheduled, served, measured and observed.

- `oif install`: single-node upstream Kubernetes 1.35 on Ubuntu, NVIDIA GPU Operator and AMD GPU Operator, local storage, load balancer; every host change recorded.
- `oif uninstall`: returns the host to its OS default, as `nai-on-nkp.sh` does.
- Run:ai open-source control plane and cluster with the KAI Scheduler; one project with a quota of one NVIDIA and one AMD GPU; one node pool per vendor.
- Dynamo platform; the same small model (Qwen3-0.6B) served on the RTX A6000 (Dynamo + vLLM, CUDA) and on the Radeon PRO W7900 (Dynamo + vLLM, ROCm), both answering through one Dynamo frontend.
- `oif bench`: AIPerf sweep (concurrency 1, 8, 32, 64; fixed input and output lengths) per GPU, JSON results and an HTML comparison report.
- Prometheus, Grafana, DCGM exporter, AMD device metrics exporter, node exporter, Dynamo and vLLM metrics; recording rules that give both vendors the same metric names; a "Fleet" dashboard and a "Serving" dashboard.

## Out of scope for v0.1

- Multi-node clusters, high availability, air-gapped installation
- Disaggregated prefill/decode, KV Block Manager, SLA planner and autoscaling
- GPU fractions and sharing (CUDA fractions, MIG, AMD partitioning, HAMi)
- SGLang and TensorRT-LLM back ends (TensorRT-LLM never runs on AMD)
- Logs (Loki) and distributed tracing (Tempo); metrics only in v0.1
- Authentication on the inference endpoint beyond network placement, multi-tenant self-service, billing

## Success criteria

On the reference host (1x RTX A6000, 1x Radeon PRO W7900, Ubuntu 26.04):

1. `oif install` completes unattended after its questions, and a second run changes nothing.
2. Both GPUs are allocatable; a third GPU workload in the project stays pending because of the quota.
3. `POST /v1/chat/completions` on the single endpoint is answered by the model on the A6000 and on the W7900 (selected by model name), including streaming.
4. `oif bench` finishes the sweep on each GPU with no failed requests and writes one report comparing TTFT, inter-token latency, output tokens/s and requests/s.
5. During the benchmark, the Fleet dashboard shows utilisation, memory, power and temperature for both GPUs, and the Serving dashboard shows request rate, TTFT and inter-token latency per GPU.
6. `oif uninstall` leaves no Kubernetes services, mounts, network links or packages behind.

## Gate for the AMD path

Serving on AMD through Dynamo is a research track (no official ROCm support in Dynamo as of October 2026). Spike S-1 in TASKS.md decides it. If its exit criteria are not met, the project stops and the owner chooses the AMD fallback: llm-d, or plain vLLM ROCm behind the same API.

## Constraints

- Reference hardware: AMD EPYC 9684X, 751 GiB RAM; RTX A6000 (Ampere, 48 GB) and Radeon PRO W7900 (RDNA3 gfx1100, 48 GB); a Radeon PRO W6400 display card isolated with vfio.
- Host OS Ubuntu 26.04 (Dynamo documents Ubuntu 22.04 and 24.04; its user space comes from containers).
- Thermals: the chassis cannot cool both GPUs under full load at once; benchmarks load one GPU at a time.
- Everything is open source; lab-specific values live only in an untracked `.env`.
