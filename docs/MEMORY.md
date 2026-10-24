# Memory

Current state of the project. Update after every task.

## Status (2026-10-24)

- Phase 0: research and project documents written (T-001). Repository not yet on GitHub (T-002).
- Reference host: clean Ubuntu 26.04.1 after the previous NKP + NAI lab was uninstalled on 2026-10-24. A6000 on nouveau (no NVIDIA driver yet), W7900 and W6400 on amdgpu (no vfio yet).
- Nothing of OIF is installed yet.

## Current task

T-002: create the public GitHub repository and push.

## Next step

S-1: Dynamo on ROCm on the W7900 (go/no-go for the AMD path).

## Known issues and risks

- Dynamo has no official ROCm support (ADR-002); decided by S-1.
- KAI quota handling for `amd.com/gpu` is unverified; decided by S-2.
- The open-source Run:ai control plane's footprint on a single node is unknown; measured in S-3.
- The W7900 is a workstation GPU (gfx1100); AMD validates distributed serving stacks on Instinct GPUs.
- Kernel 7.0 inbox amdgpu reports phantom UMC ECC errors on the W7900; the AMD metrics exporter needs a raised threshold or it marks the GPU unhealthy.
- Both GPUs throttle when loaded together (ADR-009).
