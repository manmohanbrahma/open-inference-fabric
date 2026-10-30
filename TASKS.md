# Tasks

Work through tasks in order: understand, plan, implement, test, review, commit, update docs. Each step ends with a working vertical slice.

Status: `[ ]` open, `[~]` in progress, `[x]` done, `[-]` dropped.

The work is split into three projects (ADR-010). Each builds on the one before, and each step inside a project is a checkpoint the owner signs off before the next starts.

## Phase 0: Repository

- [x] T-001 Research, PRD, architecture, design, rules, decisions, test plan, security, tasks
- [x] T-002 Public GitHub repository, licence, README; push
- [ ] T-003 CI: shellcheck, yamllint, markdown link check, secret scan (gitleaks) on every push
- [ ] T-004 (Grok) Re-plan from [proposal 0001](docs/proposals/0001-oif-distro-and-selector.md): ADR-022 to ADR-030 (ADR-029 amends ADR-005), PRD and ARCHITECTURE updates, new task list; ChatGPT reviews; the owner accepts. Until then the projects below stand as written.

## Project 1: Orchestration platform

### P1.1 Run:ai on NVIDIA, default stack

Slice: a clean host becomes a Kubernetes cluster where Run:ai schedules work on the A6000.

- [x] T-101 `oif` skeleton: verbs, logging, prompts, state, manifest helpers, `versions.env`
- [x] T-102 Host preparation: packages, swap, sysctls, containerd, NVIDIA driver from the Ubuntu archive, vfio isolation of the W6400
- [x] T-103 kubeadm 1.35 single node, Calico, control-plane taint removed; local-path storage; MetalLB
- [x] T-104 NVIDIA GPU Operator, default settings (toolkit, device plugin, GFD, DCGM exporter)
- [x] T-105 Run:ai open source, default install (control plane, cluster, KAI Scheduler); spike S-3 first decides the install method
- [x] T-106 kube-prometheus-stack; DCGM and Run:ai metrics scraped; Fleet and Scheduling dashboards (both vendors, guide 7; Grafana on grafana.<runai-domain>)
- [x] T-107 `oif uninstall`, `status`, `plan`, `check` for everything above. Passed 2026-10-25: uninstall, clean check, reinstall from the GitHub tarball; a second uninstall needed two re-run fixes (12775ca, edec89e) and then left the host clean (tests/host/verify-clean.sh). Guide 9 written
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

### P1.3 Multi-node hybrid cluster

Slice: NVIDIA and AMD GPUs in separate nodes, as in production (one vendor per server), with a highly available control plane. Tested on the [hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab) VMs: cp1-3 (control plane), gpu-amd (W7900), gpu-nvidia (A6000).

- [x] T-119 KVM lab (separate project hybrid-gpu-lab): 3 control-plane + 2 GPU worker VMs, GPUs passed through, create/destroy/recreate; both drivers initialise in the VMs and survive a recreate (2026-10-26)
- [x] T-120 Node list `OIF_NODES`, cluster SSH key created by oif on cp1 and installed once through the admin's forwarded agent, admin key on the control plane by choice, per-node runner (`oif _node`, node reboots driven by cp1), `install --until`. Passed 2026-10-26 on the lab: `tests/lab/t120-nodes.sh --reboot gpu-nvidia`, 63 checks (gpu-nvidia: NVIDIA 595 driver, reboot back in 27 s). Found and fixed on the way: agent keys masking the cluster key, ssh reading the node list, no keepalive after a node went down, the lab powering VMs off on reboot
- [x] T-121 HA Kubernetes: kube-vip v1.2.4 on `OIF_API_VIP`, `kubeadm init` on cp1, cp2/cp3 join as control planes, workers join (`oif _node-join`, tokens over SSH stdin, deleted after), Calico, MetalLB in the node subnet, no control-plane taint. Passed 2026-10-26 on the lab: `tests/lab/t121-cluster.sh --failover`, 14 checks (5 nodes Ready; API address moved from cp1 to cp2 with the API answering throughout)
- [x] T-122 GPUs on their nodes: cluster GPU inventory over the cluster key, NVIDIA driver with nouveau blocked on NVIDIA nodes, new node stage `amd-firmware` (`linux-firmware-amd-graphics`, amdgpu reload, else reboot), both GPU operators installed when any node has that vendor and checked on the node that has it; AMD operator stages before the platform. Passed 2026-10-26 on the lab: `tests/lab/t122-gpus.sh`, 20 checks. Found on the way: lsmod cut off by an early-exiting awk (pipefail), the AMD exporter Service answering only on AMD nodes (internalTrafficPolicy Local)
- [x] T-123 Run:ai on several nodes: stage `runai-pools` labels GPU nodes `oif.ai/gpu-vendor` and creates the Run:ai node pools `nvidia` and `amd`; project quotas per pool (per-vendor; a third pod queues), ADR-015's ResourceQuota kept for a single node; patch builds pinned to the first node, patched images loaded on every node; quota tests in the vendor's pool. Passed 2026-10-28 on the lab: `tests/lab/t123-runai.sh`, 27 checks; regression T-120 (66), T-121 --failover (14), T-122 (20) pass. Guide 10. Handoff (Grok): presentations/T123-Runai-Node-Pools.md can take these results; T-124 next
- [~] T-124 (Claude) Demonstration and guides: install, stop cp1 (API and Run:ai keep working), workloads in both pools, quotas, dashboards with two GPU nodes, uninstall across nodes, `lab recreate`, install again
- Checkpoint: five Ready nodes; Run:ai shows two pools with one GPU each; a project with quota 1 per pool runs one workload per vendor and queues a third; uninstall leaves every node clean.

### P1.4 Topology & Intent (vendor-agnostic surface)

Slice: the platform discovers high-bandwidth domains and accepts jobs that do not name a vendor, while still preferring GPU Direct domains when available (ADR-019, docs/design/Vendor-Agnostic-Job-Model.md).

- [ ] T-130 Topology discovery: controller (or stage) that labels nodes with vendor, interconnect class and provisional domain membership from NFD + GPU operator labels; publishes `AcceleratorDomain` objects for single-node and multi-node same-vendor groups
- [ ] T-131 `AcceleratorDomain` CRD + status (capacity, allocatable, conditions); basic unit and lab tests on hybrid-gpu-lab
- [ ] T-132 Domain-aware packing: scheduler filter/score (or KAI integration) that prefers packing multi-GPU requests inside one domain; records chosen domain on the workload
- [ ] T-133 `AIJob` CRD (intent surface): model, precision, gpuCount, qos, optional placement preferences (`preferVendor`, `requireSameDomain`, `allowCrossVendor`); controller translates to existing Run:ai / Kubernetes objects so current resource names keep working
- [ ] T-134 PlacementPolicy defaults (namespace or cluster): allowCrossVendor, preferSameDomain, vendorPriority; applied when the AIJob omits fields
- [ ] T-135 Status and observability: AIJob status shows vendor, domain, crossVendor flag; extend `oif:*` with domain utilisation and cross-vendor placement counters; Grafana panel
- [ ] T-136 Guides and presentation: how to submit a vendor-agnostic job, how domains appear, how cross-vendor is requested or forbidden
- Checkpoint: a multi-GPU AIJob with `requireSameDomain: true` lands inside one domain; an AIJob with no vendor preference is placed according to policy; status and dashboards show the chosen vendor and domain; existing direct `nvidia.com/gpu` / `amd.com/gpu` jobs still work.

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

## Project 3: Unified API and AI gateway

One OpenAI-compatible API in front of every model on both vendors, with API keys, token budgets and usage per team, then a self-service API to deploy, serve and benchmark. Starts after P1.3 and P2.1 + S-1 (models served by Dynamo on NVIDIA and on AMD). Design: ADR-018 (proposed).

### P3.1 AI gateway

- [ ] S-6 **Gateway choice.** agentgateway (Linux Foundation, v1.x; the gateway Dynamo documents for GAIE routing) against Agent Router (formerly Envoy AI Gateway, v1.2; mature token rate limits and quotas), both through the Gateway API Inference Extension. Same test on the lab cluster: OpenAI chat and streaming to a Dynamo model on each vendor through an InferencePool with Dynamo's endpoint picker; per-key authentication; a per-key token budget that refuses the request over it; usage metrics in Prometheus; added latency at concurrency 8. Exit: the owner picks one (ADR-018 accepted).
- [ ] T-301 Gateway installed by an oif stage, pinned; its own MetalLB address and `api.<domain>` with the oif CA; Gateway API and GAIE CRDs pinned
- [ ] T-302 One route per model name; an InferencePool per model and vendor (Dynamo's EPP for Dynamo deployments); `/v1/models` lists what is served
- [ ] T-303 Vendor policy per model: pinned to a vendor, preferred with fail-over, or split by weight; a request header can ask for a vendor
- [ ] T-304 API keys per team, mapped to a Run:ai project; keys stored as Kubernetes secrets, created and revoked with `oif api-key`
- [ ] T-305 Token rate limits and budgets per key (input and output tokens), 429 with a clear message when exceeded
- [ ] T-306 Usage and cost dashboard: requests, tokens, errors and latency per key, model and vendor; `oif:` recording rules with promtool tests
- [ ] T-307 Guide and published pages; AIPerf through the gateway vs direct to the frontend (gateway overhead)
- Checkpoint: two teams with their own keys call the same model name; one is served by the A6000, one by the W7900 (or both with fail-over); a team over its token budget gets 429; Grafana shows tokens per team and vendor.

### P3.2 Self-service API

- [ ] T-311 API design (OpenAPI): environments (vendor, GPU, engine, profile), deployments, benchmark runs; authenticated with the P3.1 keys, scoped to the key's Run:ai project
- [ ] T-312 Deploy and remove a model: creates the Dynamo deployment in the project's namespace (scheduled by KAI under the project's quota), its InferencePool and route
- [ ] T-313 Benchmark runs through the API: AIPerf Job with a profile, results as JSON and in the report
- [ ] T-314 Small web UI on the API, or Run:ai workload templates where they are enough
- [ ] T-315 Placement policies: by vendor preference, free capacity, latency target or cost per token

### P3.3 Agents and tools (optional)

- [ ] T-321 MCP tool servers behind the same gateway, with the same keys (both gateway candidates support MCP)

## Release

- [ ] T-901 End-to-end test on the reference host from a clean OS (TEST_PLAN.md)
- [ ] T-902 Install and comparison guides with screenshots on the guides site
- [ ] T-903 Tag v0.1.0 after Project 1, v0.2.0 after Project 2
