# Development Rules

These rules apply to every change, by a person or by an AI assistant.

Process overview: [SDLC.md](SDLC.md).

## Before coding

- Read the relevant docs: PRD.md, ARCHITECTURE.md, DESIGN.md, this file, TASKS.md, DECISIONS.md, MEMORY.md and SDLC.md.
- Work on one task from TASKS.md at a time. Mark it `[~]` (optionally with agent name). Explain the plan for it before changing files.
- Inspect what already exists and reuse it. Do not modify files unrelated to the task.
- Do not reverse a decision in DECISIONS.md silently; propose a new ADR instead.

## Code

- Shell: `bash` with `set -eEuo pipefail`; every stage idempotent; long operations retried; errors print the cause and the command to inspect it.
- Every host change goes through the manifest helpers so `oif uninstall` can reverse it.
- Read-only commands (`status`, `plan`, `check`, `report`) must not write to the host.
- Pin every version and image tag in `versions.env`; no `latest` tags in tracked manifests.
- Kubernetes manifests and Helm values are declarative files under `platform/` or `serving/`; no ad-hoc `kubectl` edits in scripts beyond applying those files.
- Vendor-specific logic stays in the vendor directories; shared layers stay vendor-neutral.
- Python (report generator, helpers): type hints, standard library first, `ruff` clean.

## Security

- Never commit secrets, tokens, real IP addresses or host names. Real values live in `.env` (untracked); `.env.example` lists the keys.
- Never print a secret in logs or terminal output.
- Validate user input in the installer (IP ranges, paths, versions) before changing anything.

## GPUs and the lab host

- Load one GPU at a time during long benchmarks; the reference chassis cannot cool both under full load.
- Check GPU temperatures during any long GPU load.
- Never run cleanup commands inside the installer's working directories; use a scratch directory under `/tmp`.
- Do not pull very large images into the host's root filesystem for quick checks; inspect them in the registry instead.

## Testing

- Every task adds or updates a test or a check in `tests/` and states how it was verified.
- Run `shellcheck`, `yamllint`, unit tests and the smoke/lab tests relevant to the task before committing.
- A failing test is fixed before the next task starts.
- Multi-node and topology work must pass the regression gate in TEST_PLAN.md (T-121, T-122, verify-clean).

## Git

- Small commits with descriptive messages (`feat:`, `fix:`, `docs:`, `test:`, `chore:`).
- One task per branch for larger work (`feat/T-0xx-...`), merged to `main` when its acceptance criteria pass.

## After each task

- Write or update the install and deployment guide for the step in `docs/guides/` (layout in `docs/guides/README.md`), from a real run on the reference host or lab: commands, expected output, checks, host changes, troubleshooting. A step is not done without its guide.
- Update TASKS.md (status), MEMORY.md (current state, next step) and DECISIONS.md (if a decision was made).
- Substantial features should get or update a presentation under `presentations/`.

## Multi-agent handoff

- Claim tasks explicitly (`[~]` + agent name).
- Prefer Claude Code (or humans) for installer/stages/tests; Grok (or humans) for ADRs, design docs, PRD, presentations and acceptance criteria.
- When finishing a slice that needs docs or a presentation, leave a one-line note in TASKS.md or the PR.
