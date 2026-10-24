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

## ADR-013: Run:ai open source through its own installer, on oif-prepared prerequisites

- **Date:** 2026-10-24. **Decided by:** project owner (S-3 plan). **Settles** ADR-005's install method.
- **Decision:** install Run:ai 3.0 with `runai-installer` (`full_installation`, connected, `registry.type: ngc` without credentials). oif installs what the installer would otherwise install or expects to exist, pinned and reversible: GPU Operator (`mode: skip`), kube-prometheus-stack (`mode: skip`), HAProxy ingress controller, the domain and TLS.
- **GPU Operator pinned to v26.7.1**, the newest version inside Run:ai 3.0's support matrix (25.10-26.7.1); v26.7.2 was installed first and is downgraded by the version-pinned stage.
- **Why:** the installer is NVIDIA's recommended path and runs preflight checks; keeping prerequisites in oif keeps every version pinned and the uninstall complete.

## ADR-014: sslip.io domain and a private CA for Run:ai

- **Date:** 2026-10-24. **Decided by:** project owner (no DNS server in the lab).
- **Decision:** Run:ai's domain defaults to `runai.<first-MetalLB-address-with-dashes>.sslip.io`; sslip.io's public DNS answers any name containing an address with that address, so the domain and its wildcards (`*.runai...`, `*.inference.runai...`) resolve without a DNS server. TLS comes from a private CA created on the host; users import its public certificate once. `RUNAI_DOMAIN` in `.env` replaces sslip.io with an organisation's own domain.
- **Consequences:** clients and pods need public DNS resolution; the lab address appears in DNS names (not secret, but visible to the public resolver). The CA key never leaves the root-only state folder.

## ADR-015: Per-vendor GPU quotas through Kubernetes ResourceQuota

- **Date:** 2026-10-25. **Decided by:** project owner, after T-113 research.
- **Context:** a Run:ai (KAI) node pool is one node label, so a node belongs to one pool; the reference host has both GPUs in one node, so `nvidia` and `amd` pools cannot be split. KAI queues have a single `gpu` quota, which counts `nvidia.com/gpu` and `amd.com/gpu` alike (S-2). Run:ai's GPU inventory (GPU type and device count per node and node pool, per-GPU metrics) lists only NVIDIA GPUs (`gpuCount: 1` on the reference host), while its allocation figures count AMD GPUs inconsistently: with one GPU of each vendor in use by team-c, the Nodes page shows 1 A6000 with 2 GPUs allocated and the queue, workload and project metrics say 2, but the Projects page shows team-c with 1.
- **Decision:** Run:ai keeps one total GPU quota per project; oif adds a Kubernetes ResourceQuota (`oif-gpu-vendor`) in the project's namespace that caps `requests.nvidia.com/gpu` and `requests.amd.com/gpu` separately. Rejected: a second Kubernetes node as a VM with the W7900 passed through (much larger host change; Run:ai would still not count the AMD GPU); accepting a shared quota with no per-vendor cap.
- **Consequences:** a pod over a vendor cap is refused when it is created instead of waiting in the queue, and there is no borrowing per vendor between projects. Run:ai shows no vendor split: its project and node figures add both vendors into one number and its inventory names only the NVIDIA GPU; oif's Grafana dashboards show the vendors side by side (T-114). On a multi-node cluster with one vendor per node, real node pools replace this.
