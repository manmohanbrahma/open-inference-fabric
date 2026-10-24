# Research (Phase 1)

Findings that shaped the PRD and decisions, collected on 2026-10-24. Re-check versions before pinning them.

## NVIDIA Run:ai (open source)

- On 2026-10-13 NVIDIA released the **full Run:ai platform** as open source (Apache-2.0) in the NVIDIA DSX AI Factory organisation: control plane, cluster services, installer (`runai-installer`), CLI, MCP server, documentation and a Kind-based local development environment. Images and Helm charts are published on NGC (`nvcr.io/nvidia/runai`); the Community Product needs acceptance of NVIDIA's licence terms but no subscription.
  Sources: https://github.com/dsx-ai-factory/run-ai, https://developer.nvidia.com/blog/nvidia-runai-is-now-open-source-as-part-of-nvidia-dsx-ai-factory-platform/
- Four modules can be adopted on their own: **KAI Scheduler** (CNCF Sandbox; gang scheduling, fair share, quotas, topology and bin-packing, GPU sharing, DRA support), **GPU Fractioning Operator** (CUDA 13.4-native fractions), **KAI Resource Management** (projects, departments, quotas, node pools) and **Workload Map** (one contract for workload types such as KServe and Dynamo graphs).
- Related: **Model Streamer** (fast weight loading, `--load-format runai_streamer` in vLLM and SGLang) and **Grove** (gang-scheduled multi-component inference; part of Dynamo).
- Run:ai integrates with KServe, LeaderWorkerSet and Dynamo graph deployments. Documentation is NVIDIA-centric; AMD GPU support in KAI quotas is not documented (spike S-2).

## NVIDIA Dynamo

- Orchestration layer above vLLM, SGLang and TensorRT-LLM: disaggregated prefill/decode, KV-aware routing, KV Block Manager, SLA planner, Grove, fault tolerance; Kubernetes operator with `DynamoGraphDeployment` and zero-config `DynamoGraphDeploymentRequest`. On Kubernetes it needs no etcd or NATS.
  Source: https://github.com/ai-dynamo/dynamo
- Release 1.4.2 (2026-08-28) pins SGLang 0.5.16, TensorRT-LLM 1.3.0rc22 and vLLM 0.26.0, CUDA 13.x, driver 580+; supported GPUs Blackwell, Hopper, Ada Lovelace, Ampere; OS Ubuntu 24.04 and 22.04. Runtime containers at 1.5.1 are referenced in the README quick start.
  Source: https://docs.nvidia.com/dynamo/reference/compatibility
- vLLM has the broadest Dynamo feature coverage (14 of 15 features).
- **No official AMD/ROCm support.** NIXL (Dynamo's transfer library) has early ROCm/HIP build patches. Dynamo's frontend and router are Rust/Python CPU code, so an aggregated vLLM worker on a ROCm vLLM image is the most likely route (spike S-1).
- Dynamo supports two routing topologies: its own frontend, or the Kubernetes Gateway API Inference Extension (GAIE) with the Dynamo endpoint picker.

## AMD serving alternatives (fallback if S-1 fails)

- **llm-d**: Kubernetes-native distributed serving for vLLM and SGLang, publishes ROCm images and is integrated by AMD on Instinct MI300X; uses the Gateway API Inference Extension.
  Sources: https://llm-d.ai/docs/0.7/getting-started/artifacts, https://rocm.blogs.amd.com/artificial-intelligence/llm-d-distributed/README.html
- Plain vLLM or SGLang ROCm engines behind the same gateway (proven in the earlier lab: ROCm vLLM serving on the W7900).

## Performance testing

- **AIPerf** is the successor to GenAI-Perf: client-side, works with any OpenAI-compatible endpoint, reports TTFT, ITL, tokens/s, requests/s and goodput. Dynamo's benchmarking guide uses it.
  Sources: https://github.com/ai-dynamo/aiperf, https://developer.nvidia.com/blog/benchmarking-llm-inference-at-scale-with-aiperf/
- Cross-checks: `vllm bench serve`, `sglang.bench_serving`.

## AMD GPU enablement and telemetry

- AMD GPU Operator 1.5.x: device plugin, node labeller, device metrics exporter, DRA driver support, automated node remediation; ROCm 7.2 operands.
  Source: https://rocm.blogs.amd.com/software-tools-optimization/gpu-operator-1.5.0/README.html
- GPU sharing on AMD: HAMi supports AMD Instinct partitioning; KAI Scheduler has adopted HAMi-core (later versions).

## Lab facts carried over

- Earlier lab work on the same host: AMD GPU Operator 1.5.1 with the in-kernel driver and an ECC-threshold fix for kernel 7.0; ROCm vLLM 0.29 served on the W7900; NVIDIA driver from the Ubuntu archive; thermal limits when both GPUs are loaded.
