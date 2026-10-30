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

## ADR-016: Patch Run:ai open source so it counts and shows AMD GPUs

- **Date:** 2026-10-25. **Decided by:** project owner (T-115: "make NVIDIA Run:ai more inclusive to AMD GPUs; add the modification as a patch by oif").
- **Context:** stock Run:ai 3.0.20 schedules `amd.com/gpu` (S-2) but its inventory reads only NVIDIA node labels: on the reference node it shows 1 GPU and the Overview 0/1 or 1/1 devices; AMD workloads get the generic icon; with fractions off (T-108) the fractioning check reports "available" while no node runs fractions, and every GPU node counts as not ready.
- **Decision:** oif keeps a patch set per Run:ai version in `patches/runai/<version>/` (cluster-sync, frontend, go-operator), builds the patched components from the tagged source in Kubernetes Jobs with pinned build images, layers them onto the stock images with crane, imports them into containerd as `oif.local/runai-oss/*` and switches Run:ai to them (RunaiConfig for cluster-sync, deployment image for the others). `RUNAI_PATCHES=none` restores the stock images. Rejected: a fork of Run:ai (to be kept in step with every release); a container registry for the patched images (one more service; containerd import is enough on one node).
- **Consequences:** Run:ai shows the node as `NVIDIA-RTX-A6000 + AMD-Radeon-Pro-W7900` with 2 GPUs, the AMD logo for ROCm images, and the node Ready. The cluster now shows Missing prerequisites while fractions are off, which is accurate. Each Run:ai upgrade needs the patches re-checked; the first build needs internet access (source, Go modules, npm packages). On a multi-node cluster the images must reach every node that runs the components (a registry or an import per node). The patches are candidates for upstream contributions.

## ADR-017: Multi-node: one entry point, the same stages on every node

- **Date:** 2026-10-26. **Decided by:** project owner (P1.3 design, approved with the key choices: admin key on all VMs, Run:ai on the control-plane VMs).
- **Context:** production clusters keep NVIDIA and AMD GPUs in separate servers; a single node cannot be split into Run:ai node pools (ADR-015). oif installed one host; it needs to install a highly available cluster with GPU workers of either vendor, and still uninstall every node to its OS default.
- **Decision:** the admin runs `sudo ./oif install` on the first control-plane node with a node list (`OIF_NODES`). oif creates its own cluster SSH key there, installs it on each node once through the admin's access, then copies itself to each node and runs the same stages with that node's own change record. Kubernetes uses kube-vip for the API address; cluster add-ons are installed once through the API. GPU stages follow each node's PCI devices. Single-node stays the default when `OIF_NODES` is empty. Rejected: Ansible or another orchestrator (a second tool to install and learn; the stages and their change records already exist in oif); a separate agent on each node (a service to secure and remove).
- **Consequences:** uninstall reverses each node from its own record and removes the cluster key. Run:ai node pools per vendor give real per-vendor quotas on multi-node clusters. Every node needs SSH from the first control-plane node and the same OS. The patched Run:ai images are loaded on every node.

## ADR-018: AI gateway (proposed, decided by spike S-6)

- **Date:** 2026-10-26. **Status:** proposed.
- **Context:** Project 3 needs one OpenAI-compatible API for every model on both vendors, with keys, token budgets and usage per team. The Gateway API Inference Extension (InferencePool and an endpoint picker) is the Kubernetes standard for model-aware routing, and Dynamo provides an endpoint picker for it. Candidates in October 2026: agentgateway (Linux Foundation, v1.x, the implementation Dynamo documents, LLM + MCP + A2A in one proxy) and Agent Router (formerly Envoy AI Gateway, v1.2 on Envoy Gateway, mature token-based rate limiting and quotas). Both implement the inference extension and MCP. LiteLLM-style proxies were set aside: not Gateway API native, and they would sit in front of Dynamo's routing rather than use it.
- **Proposal:** a Gateway API gateway with the inference extension on its own address `api.<domain>`; one InferencePool per model and vendor with Dynamo's endpoint picker; API keys mapped to Run:ai projects; per-key token budgets; usage in the existing Prometheus and Grafana. The implementation is chosen by S-6 on the lab cluster against the same test.
- **Consequences:** the HAProxy ingress keeps serving the UIs (Run:ai, Grafana); inference traffic goes through the AI gateway only. Self-service deployments (P3.2) create a pool and a route next to each Dynamo deployment.

## ADR-019: Vendor-agnostic job surface, AcceleratorDomain and GPU Direct rules

- **Date:** 2026-10-27. **Updated:** 2026-10-28. **Status:** accepted.
- **Context:** The primary product objective is one unified platform for AI job submission that is vendor-agnostic. Clusters will contain multiple servers with a variety of GPUs (one vendor per node in production, occasionally mixed). Users and coding agents should be able to submit work without naming `nvidia.com/gpu` or `amd.com/gpu`, while the platform still extracts maximum performance when a same-vendor high-bandwidth domain (NVLink or Infinity Fabric) is available. Cross-vendor placement must be explicit, never accidental.
- **Decision:**
  1. Introduce an `AcceleratorDomain` CRD (discovered by a topology controller from NFD, GPU operators and fabric information) that represents a high-bandwidth island of same-vendor GPUs.
  2. Introduce a higher-level `AIJob` (and later `InferenceService`) CRD that expresses intent: model, precision, GPU count/class, QoS, optional soft preferences (`preferVendor`, `requireSameDomain`, `allowCrossVendor`). The controller translates these into existing Run:ai / Kubernetes objects so current resource names and projects continue to work.
  3. GPU Direct strategy: prefer packing multi-GPU jobs inside one `AcceleratorDomain`; allow same-vendor multi-domain placement when high-speed fabric (IB/RoCE) is present; permit cross-vendor placement only when the job or PlacementPolicy explicitly allows it, and mark the status `crossVendor: true`.
  4. PlacementPolicy and ProjectQuota extensions supply defaults and vendor/domain ceilings.
- **Why:** Delivers the product goal of a single submission surface while preserving performance for homogeneous high-bandwidth domains and giving operators clear control over cross-vendor behaviour.
- **Migration:** The new CRDs are a façade. Existing Run:ai projects, node pools and direct `nvidia.com/gpu` / `amd.com/gpu` requests remain valid. Topology discovery can be enabled gradually; when domains are not yet present, behaviour falls back to current node-pool logic.
- **Testing (see ADR-020):** Primary proof is on the dual-GPU reference host and hybrid-gpu-lab. NVIDIA DSX may be used for NVIDIA-side topology ideas and serving components, but cannot validate cross-vendor or AMD domain behaviour.
- **Consequences:** New controller and CRDs to implement and test; scheduler scoring/filter extensions (or KAI integration points); additional `oif:*` metrics for domain utilisation and cross-vendor placements. Detailed sketches live in `docs/design/Vendor-Agnostic-Job-Model.md`. Acceptance checks in `docs/design/P1.4-Lab-Acceptance-Checks.md`.
- **Tasks:** P1.4 (T-130 – T-136).

## ADR-020: Testing strategy for multi-vendor and topology features

- **Date:** 2026-10-28. **Status:** accepted.
- **Context:** OIF claims vendor-agnostic job submission, AcceleratorDomains for both NVIDIA and AMD, GPU Direct preference inside same-vendor domains, and explicit cross-vendor policy. These claims cannot be proven on a single-vendor platform.
- **Decision:**
  1. **Primary environments**
     - Dual-GPU reference host (1× NVIDIA A6000 + 1× AMD W7900) for single-node topology, AIJob façade, quotas and clean uninstall.
     - hybrid-gpu-lab (3 control-plane + 2 GPU workers, one vendor per worker, PCI passthrough) for multi-node domains, domain packing, HA regression and cross-node placement.
  2. **Lab script style** continues the existing pattern (`tests/lab/t12x-*.sh`): numbered checks, clear pass/fail counts, optional `--failover` / focused flags.
  3. **NVIDIA DSX / Dynamo / Grove** may be used as a source of NVIDIA-side topology ideas, NVLink domain behaviour and serving components. They are **not** the primary validation environment for OIF multi-vendor claims.
  4. **Regression gate:** every P1.4 change must still pass T-121 (HA), T-122 (GPUs on their nodes) and the clean-uninstall path (`tests/host/verify-clean.sh`).
  5. Concrete acceptance checks for T-130–T-136 live in `docs/design/P1.4-Lab-Acceptance-Checks.md` and will be turned into executable lab scripts as the tasks are implemented.
- **Why:** Only a true dual-vendor environment can prove the product objective. DSX is valuable but NVIDIA-centric; using it as the sole test bed would leave the core claims untested.
- **Consequences:** Lab scripts and documentation stay focused on hybrid-gpu-lab + reference host. DSX experiments are optional and clearly labelled as NVIDIA-side only.

## ADR-021: Platform on the control-plane nodes, its data on Longhorn

- **Date:** 2026-10-30. **Status:** accepted. **Decided by:** project owner (T-124; options were Longhorn, pinning with a single data node, or CloudNativePG for the database only).
- **Context:** ADR-017 put Run:ai on the control-plane nodes, but nothing enforced it: on the lab cluster Run:ai's database and message bus and the monitoring data had landed on the GPU workers, on local-path volumes tied to one node. Losing that node (or rebooting a GPU worker for a driver) took Run:ai down; "stop a control-plane node and Run:ai keeps working" (T-124) passed only by luck.
- **Decision:** on a multi-node cluster oif labels the control-plane nodes with Run:ai's system-node role (`node-role.kubernetes.io/runai-system=true`) and requires it for the platform: Run:ai's control plane and cluster services (the installer's `systemNodes`, mode required, plus the database, metrics store, message bus and login, whose affinity the chart takes from a YAML anchor), monitoring (Prometheus, Grafana, Alertmanager, operator, kube-state-metrics), the ingress (two replicas on different nodes) and the MetalLB controller. With three or more control-plane nodes the platform's volumes use Longhorn 1.12 (newest stable), one copy on each control-plane node (at most three), installed only there; Longhorn deletes a pod stuck on a node that went down so its volume moves with the new pod. local-path stays the default StorageClass for workload volumes; a single node and a cluster with one control-plane node keep local-path for everything.
- **Rejected:** pinning only, with the database node a single point of failure; CloudNativePG (database only, monitoring data still on one node, a larger change to Run:ai's configuration).
- **Consequences:** the control-plane nodes need open-iscsi (kept out of multipath) and disk for three copies; uninstall logs out Longhorn's iSCSI sessions and removes its folders. Pods on a node that went down move after Kubernetes' 5-minute eviction, so Run:ai's UI and API come back within minutes, not instantly; the Kubernetes API (kube-vip, etcd) does not wait. GPU nodes run workloads only. Existing installs keep their placement until reinstalled.
