# Instructions for AI coding assistants

Before changing anything in this repository:

1. Read `docs/SDLC.md`, `docs/PRD.md`, `docs/ARCHITECTURE.md`, `docs/DESIGN.md`, `docs/RULES.md`, `TASKS.md`, `docs/DECISIONS.md` and `docs/MEMORY.md`.
2. Work on exactly one task from `TASKS.md`. Mark it `[~]` (optionally with your name). Explain the plan first; do not write code until the plan is agreed.
3. Follow `docs/RULES.md` and `docs/SDLC.md`. In particular: no secrets, real IP addresses or host names in tracked files; pin versions in `versions.env`; every host change must be reversible by `oif uninstall`.
4. Run the checks in `tests/` (and relevant lab scripts) and report: files changed, what was implemented, tests run, remaining issues.
5. After the task, write or update its install and deployment guide in `docs/guides/`, then update `TASKS.md`, `docs/MEMORY.md` and, if a decision was made, `docs/DECISIONS.md`.
6. Do not reverse an ADR silently. If the task needs a new architectural decision, propose or request an ADR first.
7. For multi-agent work: prefer implementing code and tests; leave design-only and presentation work clearly noted for the architecture/docs agent (or human).
