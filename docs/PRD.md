# Open Inference Fabric — Product Requirements Document (PRD)

**Version:** 0.2  
**Date:** 2026-10-28  
**Status:** Draft  
**Owner:** Manmohan Brahma  
**Related:** TASKS.md, docs/ARCHITECTURE.md, docs/DECISIONS.md, docs/SDLC.md, presentations/, docs/design/

---

## 1. Overview

### 1.1 Product Name
Open Inference Fabric (OIF)

### 1.2 One-line description
An open-source, AI-native platform that lets teams schedule, serve, benchmark and observe LLMs on both NVIDIA and AMD GPUs through one consistent stack — with a clean, reversible installer and a vendor-agnostic job surface.

### 1.3 Problem Statement
Organisations that run both NVIDIA and AMD GPUs today face fragmented stacks:
- Different operators, resource names, schedulers and dashboards per vendor
- No shared quotas or fair comparison of the same model/engine across vendors
- High operational cost of maintaining two parallel platforms
- Difficulty proving which accelerator is better for a given workload
- Install and uninstall processes that leave residual state

The result is vendor lock-in risk, higher TCO, and slow decision-making when choosing or expanding accelerator fleets.

### 1.4 Solution Summary
OIF provides a layered, pluggable fabric:
- One reversible installer (`oif`) that prepares hosts, builds or attaches to Kubernetes, installs GPU operators, scheduler, telemetry and (later) serving + gateway
- Vendor-neutral upper layers: workloads ask for a model or GPU count; lower layers decide the accelerator (AIJob / PlacementPolicy / AcceleratorDomain — ADR-019)
- Unified telemetry schema (`oif:*`) and fair benchmarking
- Change records that enable a complete uninstall back to the OS default

---

## 2. Goals and Non-Goals

### 2.1 Goals (v0.1 – v0.2)
- Run the same LLM workload on NVIDIA and AMD GPUs under one scheduler with per-vendor quotas
- Provide one set of dashboards that show both vendors side-by-side
- Deliver fair, repeatable benchmarks (same model, engine version, flags, one GPU under load)
- Support single-node and multi-node HA clusters built by oif (kubeadm + kube-vip)
- Make install and uninstall fully reversible
- Accept vendor-agnostic job intent (no required vendor resource name) while preferring GPU Direct domains when available
- Keep the entire stack open source (Apache-2.0)

### 2.2 Non-Goals (for current phases)
- Becoming a managed cloud service
- Supporting every accelerator on day one (Intel Gaudi and others are future)
- Replacing vendor-specific optimisations (TensorRT-LLM remains NVIDIA-only reference)
- Full multi-tenancy SaaS features (billing, SSO federation) in the core open-source product
- Training-focused orchestration beyond what Run:ai/KAI already provides

---

## 3. Target Users & Personas

| Persona | Description | Primary Needs |
|---------|-------------|---------------|
| **Platform / MLOps Engineer** | Owns the shared GPU cluster | Clean install, reversible changes, multi-vendor quotas, observability |
| **ML Engineer / Researcher** | Runs experiments and serving | Fair comparison reports, simple OpenAI-compatible endpoint, templates |
| **Infrastructure Lead** | Decides hardware strategy | Evidence for NVIDIA vs AMD choices, avoidance of lock-in |
| **Security / Compliance** | Reviews residual state and secrets | Clean uninstall, no long-lived join tokens, private CA option |
| **Coding agent / CI** | Submits jobs programmatically | Vendor-agnostic job API, stable status and quotas |

---

## 4. Success Metrics

| Metric | Target (v0.1 / early v0.2) | How measured |
|--------|----------------------------|--------------|
| Install success rate on reference hardware | ≥ 95% clean installs | Automated lab tests + manual runs |
| Uninstall cleanliness | Host returns to OS default (verified by check script) | `tests/host/verify-clean.sh` |
| Dual-vendor visibility | Both NVIDIA and AMD appear in Run:ai inventory and Grafana | Manual + automated checks |
| Fair benchmark reproducibility | Same model/engine on both vendors with documented versions | AIPerf reports |
| Multi-node HA | API VIP survives control-plane node failure | `t121-cluster.sh --failover` |
| Time to first useful cluster | < 30–45 min on prepared reference host (single node) | Measured install logs |
| Vendor-agnostic submit (P1.4) | AIJob with no vendor field runs; status shows chosen vendor/domain | Lab acceptance checks |

---

## 5. Requirements by Phase

### Phase 1 — Orchestration Platform (Project 1)
**Status:** Advanced (P1.3 in progress; P1.4 defined)

- [x] Host preparation, containerd, NVIDIA & AMD drivers/operators
- [x] Single-node kubeadm + Calico + MetalLB + local-path
- [x] Run:ai open source with oif patches for AMD visibility
- [x] Unified `oif:*` recording rules and Fleet/Scheduling dashboards
- [x] Multi-node node list, cluster SSH key, per-node stages
- [x] HA control plane (kube-vip) + joins
- [ ] Per-vendor node pools and real pool-based quotas (T-123)
- [ ] End-to-end multi-node demonstration + guides (T-124)

### Phase 1.4 — Topology & Intent
**Status:** Defined (ADR-019 accepted; tasks T-130–T-136)

- [ ] Topology discovery and `AcceleratorDomain` CRD
- [ ] Domain-aware packing for multi-GPU jobs
- [ ] `AIJob` CRD (vendor-agnostic surface) + controller mapping to existing objects
- [ ] `PlacementPolicy` defaults
- [ ] Status and `oif:*` domain / cross-vendor metrics
- [ ] Guides and presentation

### Phase 2 — Serving & Fair Benchmark (Project 2)
**Status:** Planned

- Dynamo (or llm-d fallback) on NVIDIA with default engines
- Equivalent ROCm path for AMD (spike first)
- AIPerf integration (`oif bench`) with profiles and temperature guard
- Serving dashboard (TTFT, ITL, throughput, KV cache)
- Overlay builds for latest engine versions on both vendors
- Comparison report generation

### Phase 3 — Unified API & Gateway (Project 3)
**Status:** Planned

- Gateway API Inference Extension + chosen gateway (agentgateway or Agent Router)
- One OpenAI-compatible endpoint (`api.<domain>`)
- API keys mapped to Run:ai projects
- Per-key token budgets and usage metering
- Self-service deploy + benchmark API (later)

### Later / Future
- Platform adapters (OpenShift, Nutanix Kubernetes Platform)
- Additional accelerators (Intel Gaudi, etc.)
- ARM64 support
- Cloud GPU instance attachment
- Multi-backend InferenceService routing under load

---

## 6. Functional Requirements (Core)

| ID | Requirement | Priority | Phase |
|----|-------------|----------|-------|
| FR-01 | `oif install` prepares host(s) and installs the chosen stack idempotently | P0 | 1 |
| FR-02 | Every change is recorded; `oif uninstall` reverses exactly those changes | P0 | 1 |
| FR-03 | Both `nvidia.com/gpu` and `amd.com/gpu` are first-class resources | P0 | 1 |
| FR-04 | Scheduler supports projects, quotas and (multi-node) node pools per vendor | P0 | 1 |
| FR-05 | Telemetry from both vendors maps into a single `oif:*` schema | P0 | 1 |
| FR-06 | HA Kubernetes API via kube-vip on multi-node | P0 | 1 |
| FR-07 | Fair benchmark of the same model/engine on both vendors | P0 | 2 |
| FR-08 | One OpenAI-compatible inference endpoint with team isolation | P0 | 3 |
| FR-09 | Platform can attach to an existing OpenShift/NKP cluster (adapter) | P1 | Later |
| FR-10 | All versions pinned and checksummed; no silent upgrades | P0 | All |
| FR-11 | Vendor-agnostic job intent (AIJob) without requiring a vendor resource name | P0 | 1.4 |
| FR-12 | Prefer packing multi-GPU jobs inside one AcceleratorDomain when requested; cross-vendor only when allowed | P0 | 1.4 |

---

## 7. Non-Functional Requirements

| Area | Requirement |
|------|-------------|
| **Reversibility** | Uninstall must leave the host in a state indistinguishable from a fresh OS install (verified by automated check) |
| **Security** | No long-lived join tokens; cluster key is oif-owned; secrets stay root-only |
| **Observability** | All key metrics available in Grafana under the `oif:*` schema |
| **Documentation** | Every major feature has a guide + living presentation under `presentations/` |
| **Licensing** | Apache-2.0 for all oif code and patches |
| **Testability** | Lab tests (hybrid-gpu-lab) cover single-node and multi-node paths; topology checks per ADR-020 |
| **Process** | Changes follow [SDLC.md](SDLC.md) |

---

## 8. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Dynamo ROCm path fails or is incomplete | Medium | High | Spike S-1; fallback to llm-d or plain vLLM ROCm |
| Run:ai patches break on upstream upgrades | Medium | Medium | Pin versions; maintain patch set per release; upstream contributions |
| Fair comparison invalidated by engine version drift | High | Medium | Overlay builds + explicit version reporting in every benchmark |
| Platform adapters (OpenShift/NKP) prove complex | Medium | Medium | Keep adapters thin; only change install/exposure paths |
| Scope creep into full multi-tenancy SaaS | Medium | High | Strict non-goals; focus on self-hosted open-source platform |
| Insufficient multi-GPU AMD hardware for domain tests | Medium | High | AMD collaboration / pitch; degrade gracefully to single-GPU domains |

---

## 9. Open Questions

1. Final choice of serving framework for AMD after S-1 (Dynamo ROCm vs llm-d vs plain vLLM).
2. Gateway product selection (agentgateway vs Agent Router) after S-6.
3. Priority order of platform adapters (OpenShift first?).
4. Whether to expose a public comparison report site or keep reports local.
5. Timeline for multi-GPU AMD / Instinct access to complete P1.4 and P2 validation.

---

## 10. References

- Architecture: `docs/ARCHITECTURE.md`
- Decisions: `docs/DECISIONS.md` (especially ADR-010, ADR-015–020)
- Process: `docs/SDLC.md`
- Design: `docs/design/Vendor-Agnostic-Job-Model.md`, `docs/design/P1.4-Lab-Acceptance-Checks.md`
- Tasks: `TASKS.md`
- Presentations: `presentations/`
- Test plan: `docs/TEST_PLAN.md`

---

*This PRD is a living document. Update it when major scope or prioritisation decisions are made.*
