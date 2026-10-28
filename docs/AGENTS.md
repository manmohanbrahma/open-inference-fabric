# Agent roles on this repository

How **Claude Code** and **Grok** work on Open Inference Fabric together with the human owner.

Related: [SDLC.md](SDLC.md), [RULES.md](RULES.md), [CLAUDE.md](../CLAUDE.md), [TASKS.md](../TASKS.md).

---

## 1. Shared contract (both agents)

Before any change:

1. Read **PRD**, **ARCHITECTURE**, **DESIGN**, **RULES**, **SDLC**, **TASKS**, **DECISIONS**, **MEMORY**.
2. Work on **exactly one** task from `TASKS.md`.
3. Mark it `[~]` and note the agent (e.g. `Claude` or `Grok`).
4. Do not reverse an ADR silently — propose a new ADR instead.
5. No secrets, real IPs, or hostnames in tracked files.
6. After the task: update **TASKS.md**, **MEMORY.md**, and (if needed) **DECISIONS.md** / guides / presentations.

Sources of truth:

| Concern | Document |
|---------|----------|
| What & why | PRD.md |
| Architecture | ARCHITECTURE.md |
| Decisions | DECISIONS.md |
| Ordered work | TASKS.md |
| Current state | MEMORY.md |
| Process | SDLC.md + RULES.md |

---

## 2. Role split

| Role | Primary agent | Owns | Does not own by default |
|------|---------------|------|-------------------------|
| **Implementation** | **Claude Code** | `installer/`, `stages/`, `platform/`, `patches/`, `tests/`, executable lab scripts, guides written from real runs | Long product strategy, market decks, new architectural direction without an ADR |
| **Architecture & product docs** | **Grok** | ADRs, PRD, design sketches (`docs/design/`), SDLC/RULES alignment, presentations, acceptance-check *specifications*, roadmaps, pitch decks | Large multi-file refactors of shell stages unless asked |
| **Orchestrator** | **Human owner** | Priorities, accepting spikes, release tags, final say on ADR acceptance | Day-to-day task implementation |

Both may touch `TASKS.md` and `MEMORY.md` when closing or handing off work.

---

## 3. Typical workflow

```text
Human sets priority
       │
       ▼
┌──────────────┐     design / ADR / acceptance      ┌──────────────┐
│     Grok     │ ───────────────────────────────► │ Claude Code  │
│  (architect) │                                   │  (implement) │
└──────────────┘ ◄───── "slice done; needs docs" ──└──────────────┘
       │                                                      │
       └──────── presentations, MEMORY, guide review ─────────┘
```

1. **Grok** (or human) defines or refines scope: ADR, design doc, lab acceptance checks, TASKS entries.
2. **Claude** claims an implementation task (`[~] Claude`), implements, adds tests, writes the guide from a real run.
3. **Claude** leaves a short handoff in TASKS.md or the PR ("Ready for presentation / ADR note").
4. **Grok** updates presentation, MEMORY, or follow-up design as needed.
5. Human reviews and accepts checkpoints (especially end of P1.3, P1.4, Project 2).

---

## 4. Task claiming

In `TASKS.md`:

```text
- [~] T-123 Run:ai on several nodes … (Claude)
- [~] T-136 Guides and presentation … (Grok)
- [x] T-121 HA Kubernetes …
```

- Only one agent owns a task at a time.
- Prefer Claude for code/tests; Grok for docs/design/presentations.
- If blocked, unclaim or note the blocker in MEMORY.md.

---

## 5. Conflict avoidance

| Area | Preference |
|------|------------|
| `installer/`, `stages/`, `tests/lab/*.sh` | Claude Code |
| `docs/DECISIONS.md`, `docs/design/`, `docs/PRD.md`, `presentations/` | Grok |
| `TASKS.md` / `MEMORY.md` | Either, when closing or handing off |
| Same large shell file | Avoid concurrent edits; sequential handoff |

If both must touch the same file, the second agent pulls latest `main` and merges carefully; prefer small commits.

---

## 6. What each agent should say when starting

**Claude Code**

> Working on T-xxx. Plan: [files]. Will follow RULES and existing ADRs. Will update TASKS/MEMORY and write the guide when done.

**Grok**

> Working on [ADR / design / presentation / alignment]. Will update TASKS/MEMORY if task status changes. Implementation handoff for Claude: [acceptance checks or design path].

---

## 7. Definition of done (reminder)

A task is done when:

1. Acceptance criteria / lab checks pass (or are documented as manual).
2. Guide exists under `docs/guides/` when user-visible behaviour changed (from a real run).
3. TASKS.md marked `[x]`, MEMORY.md updated.
4. ADR updated if a decision was made.
5. Substantial features have or update a presentation under `presentations/`.

Full process: [SDLC.md](SDLC.md).

---

## 8. Human owner

The human remains the orchestrator:

- Chooses what is next when agents disagree or scope is ambiguous.
- Accepts or rejects ADRs and project checkpoints.
- Assigns work explicitly when needed ("Claude: T-123", "Grok: T-136 + AMD pitch refresh").

---

*This document is the multi-agent protocol for this repository. Update it when roles or handoff rules change.*
