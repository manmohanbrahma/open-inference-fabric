# Tasks

Work through tasks in order: understand, plan, implement, test, review, commit, update docs. Each step ends with a working vertical slice.

Status: `[ ]` open, `[~]` in progress, `[x]` done, `[-]` dropped.

The work is split into three projects (ADR-010). Each builds on the one before, and each step inside a project is a checkpoint the owner signs off before the next starts.

## Phase 0: Repository

- [x] T-001 Research, PRD, architecture, design, rules, decisions, test plan, security, tasks
- [x] T-002 Public GitHub repository, licence, README; push
- [ ] T-003 CI: shellcheck, yamllint, markdown link check, secret scan (gitleaks) on every push

## Project 1: Orchestration platform

### P1.1 Run:ai on NVIDIA, default stack

Slice: a clean host becomes a Kubernetes cluster where Run:ai schedules work on the A6000.

- [x] T-101 `oif` skeleton: verbs, logging, prompts, state, manifest helpers, `versions.env`
- [x] T-102 Host preparation: packages, swap, sysctls, containerd, NVIDIA driver from the Ubuntu archive, vfio isolation of the W6400
- [x] T-103 kubeadm 1.35 single node, Calico, control-plane taint removed; local-path storage; MetalLB
- [x] T-104 NVIDIA GPU Operator, default settings (toolkit, device plugin, GFD, DCGM exporter)
- [x] T-105 Run:ai open source, default install (control plane, cluster, KAI Scheduler); spike S-3 first decides the install method
- [x] T-106 kube-prometheus-stack; DCGM and Run:ai metrics scraped; Fleet and Scheduling dashboards (both vendors, guide 7; Grafana on grafana.<runai-domain>)
- [x] T-107 `oif uninstall`, `status`, `plan`, `check` for everything above. Passed 2026-10-25: uninstall, clean check, reinstall from the GitHub tarball; a second uninstall needed two re-run fixes (47de19a, f9199e4) and then left the host clean (tests/host/verify-clean.sh). Guide 9 to write
- [ ] T-108 GPU fractions: Run:ai 3.0 needs NVIDIA driver r615 or later (Ubuntu's archive has 595). Options: a newer Ubuntu driver package when published, or the GPU Operator's driver container. Until then the fractioning daemons are kept off the GPU nodes (stage runai-fractions).
- Checkpoint: project `team-a` with a quota of 1 NVIDIA GPU; a GPU pod runs, a second waits on quota; the dashboards show it; uninstall returns the host to the OS default.

### P1.2 Add AMD GPUs

Slice: the same cluster also schedules the W7900, with AMD telemetry next to NVIDIA's.

- [x] S-2 **KAI quotas for `amd.com/gpu`.** Passed 2026-10-25 (stage amd-quota): a pod requesting `amd.com/gpu` waits in team-b (quota 0, `NonPreemptibleOverQuota`) on a free GPU and runs in team-a (quota 1). A project's GPU quota is one count across vendors; the per-vendor 1+1 check moves to T-113.
- [x] T-111 AMD GPU Operator v1.5.1 (in-kernel driver, device plugin, node labeller, ECC threshold for kernel 7.0); guide 6
- [x] T-112 `oif:gpu_*` recording rules for both vendors with `promtool` unit tests (pinned Prometheus 3.15.0); also oif:node_*, per-vendor allocatable/requested/caps and Run:ai project series
- [x] T-113 Per-vendor GPU quotas (ADR-015: a single node cannot be split into node pools, so a Kubernetes ResourceQuota caps each vendor inside one Run:ai project): project team-c, quota 2 = 1 NVIDIA + 1 AMD; one pod per vendor runs, a third GPU pod is refused. Passed 2026-10-25 (stage vendor-quota)
- [x] T-114 Fleet dashboard shows both vendors on the same panels (tested 2026-10-25)
- [x] T-115 Run:ai counts and shows AMD GPUs (ADR-016, guide 8): oif patch set for Run:ai 3.0.20 built on the cluster (cluster-sync counts AMD GPUs on mixed nodes, web UI AMD logo for ROCm images, operator reports fractions unavailable when no node runs them); ROCm templates pytorch-rocm-1-gpu and jupyter-lab-rocm-1-gpu; the same PyTorch check printed the W7900 and the A6000. Passed 2026-10-25: Overview 1/1 nodes, 2/2 GPU devices
- [ ] T-116 KAI scheduler patch: vendor-aware placement on a node with both vendors (an NVIDIA pod must not be bound when only the AMD GPU is free)
- Checkpoint: one project with quota 1+1; both GPUs allocatable; a third GPU pod waits on quota; uninstall still clean.

## Project 2: Serving and a fair benchmark

The goal is an apples-to-apples comparison: same model, same Dynamo version, same engine version and flags, same benchmark profile, one GPU under load at a time (ADR-011, ADR-012).

### P2.1 Dynamo on NVIDIA with the default engines

- [ ] T-201 Dynamo platform (operator, CRDs) pinned and installed; pods scheduled by KAI under the Run:ai project (spike S-4 first)
- [ ] T-202 Qwen3-0.6B on the A6000 with Dynamo's default vLLM image; chat completion through the Dynamo frontend
- [ ] T-203 Same model with Dynamo's default SGLang image
- [ ] T-204 Same model with Dynamo's default TensorRT-LLM image (NVIDIA-only reference; check Ampere support first)
- [ ] T-205 AIPerf runner as a Kubernetes Job; `oif bench` with profiles, temperature guard, Grafana annotations; JSON results
- [ ] T-206 Serving dashboard (request rate, TTFT, ITL, KV cache, queue) for Dynamo frontend and workers
- Checkpoint: a report for the A6000 with three engines.

### P2.2 Dynamo on AMD with equivalent engines

- [ ] S-1 **Dynamo on ROCm (W7900).** ROCm vLLM base plus the Dynamo runtime (no NIXL, no KVBM), aggregated, in podman. Exit: worker registers, chat completion works (streaming and not), 10 minutes of AIPerf at concurrency 8 without errors. Fail: owner chooses llm-d or plain vLLM ROCm.
- [ ] S-5 **SGLang ROCm on gfx1100.** SGLang's ROCm builds target Instinct GPUs; prove it serves on the W7900. Fail: the AMD SGLang column is marked "not supported" in reports.
- [ ] T-211 `images/dynamo-vllm-rocm`: the vLLM version that matches Dynamo's NVIDIA default as closely as ROCm allows
- [ ] T-212 `images/dynamo-sglang-rocm` (if S-5 passes)
- [ ] T-213 Qwen3-0.6B on the W7900 through the same Dynamo frontend, selected by model name
- [ ] T-214 Same `oif bench` profiles on the W7900
- Checkpoint: one report, A6000 vs W7900, per engine, with any version difference shown on the report.

### P2.3 Engine overlays: latest vLLM and SGLang on both vendors

- [ ] T-221 Overlay build: Dynamo runtime pinned, engine replaced by the latest vLLM or SGLang release; the same engine version for the CUDA and ROCm images (ADR-011)
- [ ] T-222 Compatibility check per overlay (worker registers, metrics exported, KV events if the engine supports them); results recorded in `docs/COMPATIBILITY.md`
- [ ] T-223 One serving profile file (`profiles/*.yaml`) applied to both vendors: dtype, max model length, max batch, prefix caching, chunked prefill, scheduler settings
- [ ] T-224 Benchmark matrix: {A6000, W7900} x {vLLM, SGLang} x {Dynamo default, latest overlay}; 3 repeats; HTML comparison report with versions, image digests, flags, power and clocks
- Checkpoint: a fair-comparison report the owner signs off for publication.

## Project 3: Unified API and AI gateway (planning only)

Not yet planned in detail. Starting points to research and decide with the owner:

- One OpenAI-compatible API and gateway in front of every environment (Dynamo frontend, GAIE with the Dynamo endpoint picker, or a separate AI gateway); API keys and rate limits.
- A self-service "pick an environment and schedule a job" API and UI on top of Run:ai projects: choose vendor, GPU, engine and profile, then deploy, serve or benchmark.
- Placement policies: by cost, latency, availability or vendor preference.

## Release

- [ ] T-901 End-to-end test on the reference host from a clean OS (TEST_PLAN.md)
- [ ] T-902 Install and comparison guides with screenshots on the guides site
- [ ] T-903 Tag v0.1.0 after Project 1, v0.2.0 after Project 2
