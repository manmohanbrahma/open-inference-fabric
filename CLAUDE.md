# Instructions for AI coding assistants

Before changing anything in this repository:

1. Read `docs/PRD.md`, `docs/ARCHITECTURE.md`, `docs/DESIGN.md`, `docs/RULES.md`, `TASKS.md`, `docs/DECISIONS.md` and `docs/MEMORY.md`.
2. Work on exactly one task from `TASKS.md`. Explain the plan first; do not write code until the plan is agreed.
3. Follow `docs/RULES.md`. In particular: no secrets, real IP addresses or host names in tracked files; pin versions in `versions.env`; every host change must be reversible by `oif uninstall`.
4. Run the checks in `tests/` and report: files changed, what was implemented, tests run, remaining issues.
5. After the task, write or update its install and deployment guide in `docs/guides/`, then update `TASKS.md`, `docs/MEMORY.md` and, if a decision was made, `docs/DECISIONS.md`.
