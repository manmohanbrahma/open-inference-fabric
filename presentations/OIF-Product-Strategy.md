# Open Inference Fabric — Product Strategy

**Version:** 0.1 · 2026-10-27  
**Companion:** [docs/PRD.md](../docs/PRD.md) · [Architecture](../docs/ARCHITECTURE.md)

---

## Positioning

> The open-source fabric that lets you run the same AI workloads on NVIDIA and AMD GPUs with one API, one set of quotas, one observability schema, and a clean install/uninstall path.

---

## The Problem (Multi-vendor tax)

| Pain | Detail |
|------|--------|
| Fragmented stacks | Separate operators, resource names, schedulers and dashboards per vendor |
| No shared quotas | Cannot fairly allocate capacity across NVIDIA and AMD in one project |
| Unfair comparisons | Different engines, versions and setups make vendor choice guesswork |
| Residual state | Installs leave packages, keys and configuration that are hard to reverse |

---

## Solution

A layered, pluggable fabric:

1. **One API** — OpenAI-compatible endpoint + scheduler UI  
2. **Gateway + Serving** — Pluggable engines on CUDA and ROCm  
3. **Scheduler & Quotas** — Run:ai / KAI with per-vendor pools  
4. **Kubernetes + Operators** — kubeadm HA or attach to existing platform  
5. **Accelerators** — NVIDIA + AMD first-class; others later  

Upper layers never name a vendor. A workload asks for a model or GPU count; the lower layers decide.

---

## Market Context (2026)

- GPU semiconductor market projected toward ~$647B by 2031 (CAGR ~23%).
- Inference is growing faster than training as models enter production.
- Enterprises and sovereign AI operators increasingly run mixed NVIDIA + AMD fleets for cost, availability and resilience.
- Open-source orchestration wave: full Run:ai open-sourced (KAI in CNCF Sandbox), llm-d, GPUStack, HAMi, Modular MAX, Opod.

---

## Competitive Landscape

| Category | Examples | Gap vs OIF |
|----------|----------|------------|
| NVIDIA-centric | Run:ai, Dynamo, Grove | Strong NVIDIA path; weak dual-vendor story |
| Serving engines | vLLM, SGLang, Modular MAX | High performance; not full platforms |
| K8s distributed | llm-d, Opod | Good ambition; still early on production dual-vendor |
| Heterogeneous | GPUStack, HAMi, LLMKube | Multi-vendor aware; thinner on full lifecycle + fair benchmark |

No current open-source project fully occupies the intersection OIF targets: reversible installer + first-class NVIDIA/AMD with identical resource model, quotas and telemetry + fair benchmarking.

---

## Uniqueness

1. **Honest multi-vendor** — Upper layers never name a vendor; resource model, quotas and telemetry stay consistent.
2. **Reversible lifecycle** — Change records on every node; uninstall returns hosts to OS default.
3. **One telemetry schema** — DCGM + AMD exporter → `oif:*` rules → vendor-neutral dashboards.
4. **Fair comparison** — Same model, engine version, flags; one GPU under load; AIPerf reports.
5. **Pluggable platforms** — kubeadm (tested) or attach to OpenShift / NKP via thin adapters.
6. **Inclusive patches** — Run:ai patches so the scheduler counts and shows AMD GPUs correctly.

---

## Strategy Pillars

- Fully open source (Apache-2.0); no paid core.
- Ship working vertical slices early and often.
- Living documentation (ADRs + presentations stay current).
- Installer is the product experience: one command, honest status, reversible.

**Primary users:** Platform / MLOps engineers running mixed fleets; ML engineers needing fair comparisons; infrastructure leads avoiding lock-in.

---

## Roadmap

| Phase | Focus | Status |
|-------|-------|--------|
| **P1** | Orchestration — Run:ai + dual operators + multi-node HA + per-vendor pools | Advanced |
| **P2** | Serving & Benchmark — Dynamo / llm-d on both vendors + AIPerf fair reports | Planned |
| **P3** | Gateway & API — One OpenAI endpoint, keys, budgets, usage metering | Planned |
| **Later** | Platform adapters (OpenShift/NKP), more accelerators, ARM64 | Future |

---

## Success Metrics (early targets)

- ≥ 95% clean install success on reference hardware
- Uninstall returns host to OS default (verified by check script)
- Both vendors visible in Run:ai inventory and Grafana
- API VIP survives control-plane failure (lab tested)
- Fair reports with version transparency
- < 45 min to first useful single-node cluster

---

## Related

- Formal PRD: [docs/PRD.md](../docs/PRD.md)
- Architecture and figures: high-level architecture document + `docs/ARCHITECTURE.md`
- Feature decks: [presentations/](.)
- Tasks: [TASKS.md](../TASKS.md)
