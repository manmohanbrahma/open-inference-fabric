# Open Inference Fabric — Product Strategy

**Version:** 0.1  
**Date:** 2026-10-27  
**Companion PPTX:** Available on request / in releases  
**Related:** [PRD](../docs/PRD.md), TASKS.md, docs/ARCHITECTURE.md

---

## Positioning

> The open-source fabric that lets you run the same AI workloads on NVIDIA and AMD GPUs with one API, one set of quotas, one observability schema, and a clean install/uninstall path.

---

## 1. The Problem — Multi-Vendor Tax

| Pain | Detail |
|------|--------|
| Fragmented stacks | Separate operators, resource names, schedulers and dashboards per vendor |
| No shared quotas | Cannot fairly allocate capacity across NVIDIA and AMD in one project |
| Unfair comparisons | Different engines, versions and setups make vendor choice guesswork |
| Residual state | Installs leave packages, keys and configuration that are hard to reverse |

Result: vendor lock-in risk, higher TCO, slow hardware decisions.

---

## 2. Solution — Layered, Pluggable Fabric

1. **One API** — OpenAI-compatible endpoint + scheduler UI  
2. **Gateway + Serving** (planned) — Pluggable engines on CUDA and ROCm  
3. **Scheduler & Quotas** — Run:ai / KAI with per-vendor pools  
4. **Kubernetes + Operators** — kubeadm HA or attach to existing platform  
5. **Accelerators** — NVIDIA + AMD first-class; others later  

Upper layers never name a vendor. A workload asks for a model or GPU count; the lower layers decide.

---

## 3. Market Context (2026)

- GPU semiconductor market: ~$189B (2025) → ~$647B by 2031 (CAGR ~23%)
- Inference growing faster than training as models enter production
- Mixed fleets (NVIDIA + AMD) rising for cost, availability and sovereign AI
- Open-source wave: full Run:ai open-sourced (KAI Scheduler CNCF Sandbox), llm-d, GPUStack, HAMi, Modular MAX, Opod

---

## 4. Competitive Landscape

| Category | Examples | Gap vs OIF |
|----------|----------|------------|
| NVIDIA-centric | Run:ai, Dynamo, Grove | Excellent NVIDIA path; weak dual-vendor story |
| Serving engines | vLLM, SGLang, Modular MAX | High performance but not full platforms |
| K8s distributed | llm-d, Opod | Good ambition; still early on production dual-vendor |
| Heterogeneous | GPUStack, HAMi, LLMKube | Multi-vendor aware; thinner on full lifecycle + fair benchmark |

No current open-source project fully occupies: reversible installer + first-class dual vendor + unified telemetry + fair benchmarking + pluggable platforms.

---

## 5. Uniqueness

1. **Honest multi-vendor** — Upper layers never name a vendor; resource model, quotas and telemetry stay consistent  
2. **Reversible lifecycle** — Change records on every node; uninstall returns hosts to OS default  
3. **One telemetry schema** — DCGM + AMD exporter → `oif:*` rules → vendor-neutral dashboards  
4. **Fair comparison** — Same model, engine version, flags; one GPU under load; AIPerf reports  
5. **Pluggable platforms** — kubeadm (tested) or attach to OpenShift / NKP via thin adapters  
6. **Inclusive patches** — Run:ai patches so the scheduler counts and shows AMD GPUs correctly  

---

## 6. Strategy

- Fully open source (Apache-2.0); no paid core
- Ship vertical slices early and often
- Living documentation (ADRs + presentations stay current)
- Installer as product experience: one command, honest status, reversible

**Primary targets**
1. Platform / MLOps teams running mixed NVIDIA + AMD fleets  
2. Research labs needing fair vendor comparisons  
3. Organisations avoiding single-vendor lock-in  

---

## 7. Roadmap

| Phase | Focus | Status |
|-------|-------|--------|
| **P1** | Orchestration — Run:ai + dual operators + multi-node HA + per-vendor pools | Advanced |
| **P2** | Serving & Benchmark — Dynamo / llm-d on both vendors + AIPerf fair reports | Planned |
| **P3** | Gateway & API — One OpenAI endpoint, keys, budgets, usage metering | Planned |
| **Later** | Platform adapters (OpenShift/NKP), more accelerators, ARM64 | Future |

---

## 8. Success Metrics

| Metric | Target |
|--------|--------|
| Clean install success | ≥ 95% on reference hardware |
| Uninstall cleanliness | Host returns to OS default (verified) |
| Dual-vendor visibility | Both in Run:ai inventory and Grafana |
| HA | API VIP survives control-plane failure |
| Fair reports | Same model/engine on both GPUs with version transparency |
| Time to first cluster | < 30–45 min (single node) |

---

## 9. Closing

**Build once. Run on any accelerator. Leave no trace.**

Repository: [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
Licence: Apache-2.0
