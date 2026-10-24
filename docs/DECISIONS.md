# Decisions

Architecture decision records. Change a decision only with a new ADR that supersedes it.

## ADR-001: Upstream Kubernetes (kubeadm) as the base

- **Date:** 2026-10-24. **Decided by:** project owner.
- **Decision:** single-node kubeadm Kubernetes 1.35 with containerd, installed and removed by `oif`.
- **Why:** fully open source, no licences, and within the support matrices of Run:ai and Dynamo. Avoids NKP/Kommander's footprint and licence.
- **Alternatives:** NKP 2.18 (proven in the lab, but licensed), Kind (development only).

## ADR-002: Dynamo serves both vendors; AMD through a ROCm build

- **Date:** 2026-10-24. **Decided by:** project owner.
- **Decision:** use NVIDIA Dynamo for NVIDIA and AMD GPUs. For AMD, build a Dynamo worker image on a ROCm vLLM base, starting with aggregated serving (no NIXL, no KV Block Manager).
- **Why:** one serving layer, one frontend and one set of serving metrics for both vendors.
- **Risk:** Dynamo officially supports NVIDIA GPUs only (Ampere and newer) as of v1.4/1.5; NIXL has early ROCm patches. Spike S-1 is the gate. If it fails, the owner chooses between llm-d and plain vLLM ROCm behind the same API.

## ADR-003: Public GitHub repository under Apache-2.0

- **Date:** 2026-10-24. **Decided by:** project owner.
- **Decision:** develop in a public repository from the start, licensed Apache-2.0 like Run:ai, KAI Scheduler and Dynamo.
- **Consequence:** no lab addresses, host names or secrets in Git; values come from `.env`. CI runs a secret scan.

## ADR-004: MVP proves one model on both GPUs, measured and observed

- **Date:** 2026-10-24. **Decided by:** project owner.
- **Decision:** v0.1 serves one small model (Qwen3-0.6B) on the A6000 and the W7900 through one endpoint, scheduled with quotas, benchmarked with AIPerf, observed in one Grafana. Everything else (multi-node, disaggregation, autoscaling, fractions, logs, tracing) comes later.

## ADR-005: Full open-source Run:ai platform, KAI Scheduler at its core

- **Date:** 2026-10-24. **Proposed.**
- **Decision:** install the complete open-source Run:ai platform (control plane, cluster services, KAI Scheduler) rather than KAI alone, for projects, quotas, node pools, UI and API.
- **Fallback:** if S-3 shows the control plane is too heavy or does not install on single-node kubeadm, use KAI Scheduler plus KAI Resource Management only.

## ADR-006: AIPerf as the benchmark tool

- **Date:** 2026-10-24. **Proposed.**
- **Decision:** NVIDIA AIPerf (successor of GenAI-Perf) drives all benchmarks against the OpenAI-compatible endpoint; `vllm bench serve` only as a cross-check.
- **Why:** engine-neutral, works with any OpenAI-compatible server, reports TTFT, ITL, throughput and goodput; Dynamo's own benchmarking guide uses it.

## ADR-007: Prometheus and Grafana with vendor exporters and a normalised schema

- **Date:** 2026-10-24. **Proposed.**
- **Decision:** kube-prometheus-stack; DCGM exporter for NVIDIA, AMD device metrics exporter for AMD; recording rules map both onto `oif:gpu_*` so dashboards are vendor-neutral.
- **Later:** Loki for logs and OpenTelemetry with Tempo for traces (out of scope for v0.1).

## ADR-008: Keep Ubuntu 26.04 on the reference host

- **Date:** 2026-10-24. **Proposed.**
- **Decision:** keep the installed Ubuntu 26.04 (kernel 7.0). Engines and Dynamo run from containers that carry their own user space; the NVIDIA driver comes from the Ubuntu archive, AMD uses the in-kernel amdgpu driver.
- **Risk:** Dynamo documents Ubuntu 22.04/24.04 only; host-side issues are handled as in the earlier lab work (package aliases, cloud-init shim).

## ADR-009: One GPU under load at a time in benchmarks

- **Date:** 2026-10-24. **Proposed.**
- **Decision:** `oif bench` runs vendors sequentially and waits until both GPUs are below a temperature threshold before each run.
- **Why:** on the reference chassis both GPUs throttle when loaded together, which would make results meaningless.

## ADR-010: Three projects, built in order

- **Date:** 2026-10-24. **Decided by:** project owner. **Refines** ADR-004.
- **Decision:** Project 1 builds the orchestration platform (Run:ai on NVIDIA with the default stack, then AMD GPUs with the AMD GPU Operator and its metrics exporter). Project 2 adds Dynamo serving on NVIDIA (vLLM, SGLang, TensorRT-LLM), then on AMD (vLLM and SGLang), then engine overlays for a fair comparison. Project 3 (unified API and AI gateway, self-service scheduling) is planned after Project 2.
- **Why:** each project is useful on its own and proves the layer below before the next is built on it.

## ADR-011: Engine overlays for a fair cross-vendor comparison

- **Date:** 2026-10-24. **Decided by:** project owner.
- **Decision:** besides Dynamo's default engine versions, build overlay images that keep the Dynamo runtime pinned and replace the engine with the latest vLLM or SGLang release, using the same engine version and the same serving profile on CUDA and ROCm.
- **Why:** Dynamo's NVIDIA images and any ROCm image would otherwise carry different engine versions, so differences in results could come from software rather than hardware.
- **How:** the engine runs in the worker process (`dynamo.vllm`, `dynamo.sglang`), so the overlay is a layered image, not a Kubernetes sidecar container. A separate engine container behind the frontend would lose KV-aware routing and engine metrics in Dynamo.
- **Risk:** a newer engine may break Dynamo's worker integration; each overlay is checked (T-222) and the result recorded.

## ADR-012: Rules of the fair comparison

- **Date:** 2026-10-24. **Decided by:** project owner.
- **Decision:** a result is comparable only if the model weights and dtype, Dynamo version, engine version, serving profile, benchmark profile (AIPerf, input and output lengths, concurrency, warm-up, 3 repeats) and the one-GPU-at-a-time rule (ADR-009) are the same. Every report lists versions, image digests, flags, power limits and clocks. TensorRT-LLM results are an NVIDIA-only reference column.
