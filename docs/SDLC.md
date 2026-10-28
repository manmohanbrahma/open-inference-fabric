# Software Development Life Cycle (SDLC)

This document defines how Open Inference Fabric is built, tested, documented and released. It is the process contract for humans and AI agents (Claude Code, Grok, and others).

---

## 1. Sources of truth

| Concern | Document |
|---------|----------|
| **What & why** | [PRD.md](PRD.md) |
| **Architecture** | [ARCHITECTURE.md](ARCHITECTURE.md) |
| **Decisions** | [DECISIONS.md](DECISIONS.md) (ADRs) |
| **Ordered work** | [TASKS.md](../TASKS.md) |
| **Current state** | [MEMORY.md](MEMORY.md) |
| **How we write code** | [RULES.md](RULES.md) |
| **What "done" means** | [TEST_PLAN.md](TEST_PLAN.md) + lab acceptance docs under `design/` |
| **User-facing steps** | [guides/](guides/) |
| **Feature explanations** | [presentations/](../presentations/) |
| **Design sketches** | [design/](design/) |

Product direction changes go through an ADR (or PRD update) **before** large implementation. Tasks are claimed and closed in `TASKS.md`.

---

## 2. Roles (multi-agent and human)

| Role | Typical owner | Responsibilities |
|------|---------------|------------------|
| **Product / Architecture** | Grok or human | PRD, ADRs, design sketches, roadmaps, presentations, acceptance criteria |
| **Implementation** | Claude Code or human | Installer stages, platform manifests, patches, tests, guides from real runs |
| **Orchestrator** | Human (project owner) | Priorities, task assignment, accepting spikes, release tags |

Agents must:

1. Read PRD, ARCHITECTURE, DESIGN, RULES, TASKS, DECISIONS, MEMORY before changing code.
2. Work on **one** task at a time; mark it `[~]` and note the agent name.
3. Not reverse an ADR silently — propose a new ADR instead.
4. Leave handoff notes in TASKS.md or the PR when a vertical slice is ready for docs or the next agent.

See also [CLAUDE.md](../CLAUDE.md) and [RULES.md](RULES.md).

---

## 3. Lifecycle of a task

```
Backlog → Claimed [~] → Plan agreed → Implement → Test → Guide → Docs/ADR/MEMORY → Done [x]
```

1. **Claim** — Set `[~]` in TASKS.md; optional branch `feat/T-xxx-short-name`.
2. **Plan** — Short plan (files to touch, acceptance). For design-heavy work, ADR or design doc first.
3. **Implement** — Follow RULES.md (idempotent stages, manifests, pinned versions, no secrets).
4. **Test** — Add/update checks under `tests/`; run static checks; satisfy TEST_PLAN and any lab acceptance doc.
5. **Guide** — Real-run guide in `docs/guides/` (owner rule: a step is not done without its guide).
6. **Close** — Update TASKS.md `[x]`, MEMORY.md, DECISIONS.md if needed; presentation under `presentations/` for substantial features.

---

## 4. Quality gates

| Gate | Requirement |
|------|-------------|
| **Static (every commit)** | shellcheck, yamllint, promtool (rules + unit tests), markdown link check, gitleaks (T-003) |
| **Installer** | Idempotent install; interrupt/resume; uninstall → verify-clean |
| **Lab (multi-node)** | Relevant `tests/lab/t12x-*.sh` / `t13x-*.sh` pass on hybrid-gpu-lab |
| **Regression** | Existing HA (T-121), GPU placement (T-122), dual-vendor quotas/dashboards still pass |
| **Docs** | Guide written from a real run; MEMORY and TASKS updated |
| **Decision** | New behaviour covered by an ADR when it is architectural |

Release tags (T-903): v0.1.0 after Project 1 checkpoint; v0.2.0 after Project 2 fair-comparison checkpoint.

---

## 5. Testing environments

| Environment | Use |
|-------------|-----|
| **Reference host** | Single-node dual-GPU (A6000 + W7900); install/uninstall; mixed-node quotas |
| **hybrid-gpu-lab** | Multi-node HA, one vendor per worker, domain/topology, failover |
| **NVIDIA DSX** | Optional NVIDIA-side ideas only — **not** a gate for multi-vendor claims (ADR-020) |

Acceptance check lists for P1.4 live in [design/P1.4-Lab-Acceptance-Checks.md](design/P1.4-Lab-Acceptance-Checks.md).

---

## 6. Documentation expectations

- **Every completed task** that changes user-visible behaviour has a guide under `docs/guides/`.
- **Substantial features** (e.g. T-120–T-122, product strategy) have a presentation under `presentations/`.
- **Architectural choices** are recorded as ADRs before or with the implementation.
- **MEMORY.md** is updated after every task so any agent can resume.

---

## 7. Security & compliance (process)

- No secrets, real IPs or hostnames in Git (`.env` untracked; `.env.example` for keys only).
- Change records enable full uninstall; clean check is part of the definition of done.
- Licence: Apache-2.0 for oif code and patches.

Details: [SECURITY.md](SECURITY.md).

---

## 8. Relation to projects

Work is ordered by ADR-010:

1. **Project 1** — Orchestration (single-node → AMD → multi-node HA → topology & intent)
2. **Project 2** — Serving & fair benchmark
3. **Project 3** — Unified API & gateway

Each project ends in a checkpoint the owner signs off before the next starts.

---

*This SDLC is living. Update it when process decisions change; prefer small ADRs for process as well as architecture.*
