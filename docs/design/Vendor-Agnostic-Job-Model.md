# Open Inference Fabric — Vendor-Agnostic Job & Topology Model

**Status:** Design sketch (v0.2)  
**Date:** 2026-10-28  
**Related:** docs/PRD.md, presentations/OIF-Product-Strategy.md, TASKS.md, ADR-019, ADR-020

---

## 1. Design Goals

1. A user or coding agent can submit an AI job **without naming a vendor**.
2. The platform still extracts maximum performance when a **same-vendor high-bandwidth domain** (NVLink / Infinity Fabric) is available.
3. Cross-vendor placement is first-class and explicit, never accidental.
4. Operators retain full control via policies, quotas and topology constraints.

---

## 2. Supported vs unsupported placement (contract)

These cases are **not** equivalent. Implementation and acceptance tests must treat them separately.

| Case | Description | Default policy | Current lab (hybrid-gpu-lab) | Notes |
|------|-------------|----------------|------------------------------|-------|
| **A. Independent workloads on different vendors** | Separate pods/jobs, each requesting one vendor (or no preference). One lands on NVIDIA pool, another on AMD pool. | **Supported** | **Provable today** (T-123 pools + quotas) | Already implemented via Run:ai node pools `nvidia` / `amd`. |
| **B. Same-vendor multi-GPU packing** | One workload needs `gpuCount > 1` and must stay inside one high-bandwidth domain (NVLink or Infinity Fabric). | **Supported when domain exists** | **Not provable** on current lab (1 GPU per worker) | Requires multi-GPU same-vendor nodes or multi-node same-vendor fabric. |
| **C. Cross-vendor independent replicas** | Multiple replicas of the same model, allowed on different vendors (e.g. InferenceService backends). | **Supported only if `allowCrossVendor: true`** | Partially provable as separate workloads | Routing/failover is a higher-level concern (gateway / InferenceService). |
| **D. Single distributed execution spanning NVIDIA and AMD** | One model-parallel / tensor-parallel / pipeline-parallel run that places ranks across both vendors. | **Unsupported by default** | Not supported | CUDA and ROCm devices are not interchangeable inside a collective. Requires an engine and communication library that explicitly support heterogeneous ranks. Opt-in only after validation; status must mark `crossVendor: true` and the failure mode must be clear if rejected. |
| **E. Mixed node (both vendors on one host)** | One physical node advertises both `nvidia.com/gpu` and `amd.com/gpu`. | Treated as two single-GPU domains; no cross-device GPU Direct | Reference host only | ADR-015: cannot split one node into two Run:ai pools; ResourceQuota used for per-vendor caps. |

**Rules of the contract**

1. Mixed-vendor *distributed* execution (case D) is **rejected by default**. It may be enabled only by an explicit placement flag **and** a validated engine/configuration pair.
2. `requireSameDomain: true` must never silently split a multi-GPU request across domains or vendors.
3. Acceptance tests must name which case they prove. A successful single-GPU-per-vendor run does **not** prove case B or D.
4. Any change that promotes case D from unsupported to supported requires a new or superseding ADR and human acceptance.

---

## 3. Core Concepts

| Concept | Meaning |
|---------|---------|
| **Accelerator Domain** | A set of GPUs that can communicate at high bandwidth via GPU Direct (NVLink domain, Infinity Fabric / xGMI domain, or single-node multi-GPU). |
| **Vendor Pool** | Logical pool of all GPUs of one vendor (`nvidia`, `amd`, …). Already realised as Run:ai node pools on multi-node (T-123). |
| **Intent** | High-level request: model, precision, GPU count/class, latency/throughput target, optional preferences. |
| **Placement Policy** | Rules that decide whether a job may cross vendors or must stay inside a domain. |

---

## 4. CRD Sketches

### 4.1 AcceleratorDomain (cluster-scoped, discovered)

```yaml
apiVersion: oif.io/v1alpha1
kind: AcceleratorDomain
metadata:
  name: nvlink-rack-a-0
spec:
  vendor: nvidia                    # nvidia | amd | mixed
  interconnect: nvlink              # nvlink | infinity-fabric | pcie | unknown
  bandwidthClass: high              # high | medium | low
  nodes:
    - name: gpu-node-01
      gpuIndexes: [0, 1, 2, 3]
    - name: gpu-node-02
      gpuIndexes: [0, 1, 2, 3]
status:
  capacity:
    gpu: 8
    memoryGiB: 640
  allocatable:
    gpu: 6
    memoryGiB: 480
  conditions: [...]
```

Domains are created by a topology controller that watches Node Feature Discovery, GPU operator labels, and (later) fabric managers.

### 4.2 AIJob (namespaced) — the primary submission object

```yaml
apiVersion: oif.io/v1alpha1
kind: AIJob
metadata:
  name: llama-70b-tp4
  namespace: team-research
spec:
  # --- Intent (vendor-agnostic) ---
  model:
    name: meta-llama/Llama-3.1-70B-Instruct
    revision: main
    precision: fp8
  workloadType: inference          # inference | training | notebook | batch
  resources:
    gpuCount: 4
    minMemoryGiBPerGPU: 40
    gpuClass: "80GB"
  engine:
    name: auto                      # auto | vllm | sglang | trtllm | ...
  qos: latency-sensitive

  # --- Placement preferences (all optional) ---
  placement:
    preferVendor: nvidia
    requireSameDomain: true
    allowCrossVendor: false         # default false; case D stays off unless true *and* engine supports it
    topologyHint: nvlink

  replicas: 1
  scaling:
    minReplicas: 1
    maxReplicas: 4

status:
  phase: Running
  placement:
    vendor: nvidia
    domain: nvlink-rack-a-0
    nodes: ["gpu-node-01"]
    crossVendor: false
  endpoints:
    openai: https://api.example.com/v1
  conditions: [...]
```

### 4.3 InferenceService (multi-backend)

```yaml
apiVersion: oif.io/v1alpha1
kind: InferenceService
metadata:
  name: llama-70b
spec:
  model:
    name: meta-llama/Llama-3.1-70B-Instruct
    precision: fp8
  backends:
    - name: nvidia-pool
      vendor: nvidia
      minReplicas: 1
      maxReplicas: 4
      resources:
        gpuCount: 2
      placement:
        requireSameDomain: true
    - name: amd-pool
      vendor: amd
      minReplicas: 0
      maxReplicas: 4
      resources:
        gpuCount: 2
      placement:
        requireSameDomain: true
  routing:
    strategy: latency-and-cache
    preferVendor: nvidia
  gateway:
    public: true
    apiKeyPolicy: project
status:
  endpoints:
    openai: https://api.example.com/v1/models/llama-70b
  backends:
    - name: nvidia-pool
      readyReplicas: 2
      domain: nvlink-rack-a-0
    - name: amd-pool
      readyReplicas: 1
      domain: infinity-rack-b-1
```

### 4.4 PlacementPolicy (cluster or namespace)

```yaml
apiVersion: oif.io/v1alpha1
kind: PlacementPolicy
metadata:
  name: default-team-research
spec:
  allowCrossVendor: false           # default false for case D safety
  preferSameDomain: true
  crossVendorWarning: true
  vendorPriority:
    - nvidia
    - amd
  domainPacking: binpack
  costWeight:
    nvidia: 1.0
    amd: 0.85
```

---

## 5. Scheduler & Topology Requirements

### 5.1 Topology Controller
- Watches nodes, GPU operators, NFD labels, and (later) fabric managers.
- Creates / updates `AcceleratorDomain` objects.
- Publishes domain membership as node labels + annotations for the scheduler.

### 5.2 Scheduler Plugin / Extension Points
(Works with KAI / Run:ai or as a Kubernetes scheduler plugin)

1. **Filter** — Respect `requireSameDomain`, `allowCrossVendor`, resource requests. Filter domains that cannot satisfy GPU count + memory. Reject case D unless explicitly allowed and supported.
2. **Score** — Prefer high-bandwidth domains, preferred vendor, domains that already hold model weights / KV cache. Optional cost / power score.
3. **Reserve / Bind** — Atomically reserve GPUs inside a domain (gang for multi-GPU). Record chosen domain and vendor on AIJob status.
4. **Preemption** — Domain-aware and vendor-aware preemption rules.

### 5.3 GPU Direct Strategy Rules

| Placement | GPU Direct | Action |
|-----------|------------|--------|
| All GPUs inside one AcceleratorDomain of same vendor | Full (NVLink / Infinity Fabric + NCCL/RCCL) | Preferred path; expose topology to engine |
| Same vendor, multiple domains, high-speed fabric (IB/RoCE) | GPUDirect RDMA possible | Allowed; lower score than single domain |
| Cross-vendor (case D) | No GPU Direct | Only if `allowCrossVendor: true` **and** engine supports heterogeneous ranks; otherwise reject with a clear condition |
| Mixed node (both vendors on one host) | Treated as two separate single-GPU domains | No cross-device GPU Direct assumed |

---

## 6. Quota Model Extensions

```yaml
apiVersion: oif.io/v1alpha1
kind: ProjectQuota
metadata:
  name: team-research
spec:
  totalGPUs: 32
  vendors:
    nvidia:
      hard: 24
      soft: 16
    amd:
      hard: 16
      soft: 8
  maxDomains: 4
  maxGPUsPerDomain: 8
```

On multi-node with pure-vendor workers, Run:ai per-pool quotas (T-123) already provide the practical per-vendor hard limit.

---

## 7. Observability Additions

Extend the existing `oif:*` schema:

- `oif:domain_gpu_util_ratio`
- `oif:domain_memory_used_bytes`
- `oif:placement_cross_vendor_total`
- `oif:gpudirect_achieved_bandwidth_ratio`
- `oif:job_placement_vendor`
- `oif:job_placement_domain`

Dashboards: domain utilisation heatmap, cross-vendor placement events, cost-per-token by vendor.

---

## 8. Revised Roadmap Section (for PRD)

### Phase 1.5 — Topology & Intent (insert after current P1)

- Topology controller + `AcceleratorDomain` CRD
- Node labels / domain discovery for NVIDIA and AMD
- Basic domain-aware packing in the scheduler
- `AIJob` CRD (vendor-agnostic surface) that translates to existing Run:ai / Kubernetes objects

### Phase 2 (extended)

- Multi-backend `InferenceService`
- PlacementPolicy and cross-vendor fallback (cases A and C)
- GPU Direct domain constraints + status reporting
- Fair-benchmark jobs that can request exclusive same-domain placement on both vendors (case B, when hardware allows)

### Phase 3 (extended)

- Gateway routing across backends (latency, cache, prefer-vendor)
- ProjectQuota with vendor + domain dimensions
- Cost / power scoring (optional)

### Later

- Live migration of inference replicas across vendors
- Experimental heterogeneous tensor / expert parallelism (case D, only after explicit validation)
- Carbon-aware and power-aware policies

---

## 9. Migration Path from Current OIF

1. Keep existing Run:ai projects and resource names working.
2. Introduce `AIJob` / `InferenceService` as a higher-level façade that still creates the underlying Run:ai / Kubernetes objects.
3. Topology controller can be enabled gradually; when domains are not yet discovered, behaviour falls back to current node-pool logic (T-123).
4. All new features remain optional — pure vendor-specific jobs continue to work.

---

*This document is the placement contract for P1.4. Implementation claims must stay within the supported cases and the hardware that has actually been tested.*
