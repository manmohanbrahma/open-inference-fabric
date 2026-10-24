# Memory

Current state of the project. Update after every task.

## Status (2026-10-24)

- Phase 0: research and project documents written (T-001). Repository public at github.com/manmohanbrahma/open-inference-fabric (T-002).
- Reference host: clean Ubuntu 26.04.1 after the previous NKP + NAI lab was uninstalled on 2026-10-24. A6000 on nouveau (no NVIDIA driver yet), W7900 and W6400 on amdgpu (no vfio yet).
- Nothing of OIF is installed yet.

## Plan

The owner split the work into three projects (ADR-010): Project 1 orchestration (Run:ai on NVIDIA, then AMD), Project 2 serving with Dynamo and a fair benchmark (NVIDIA, AMD, then engine overlays, ADR-011/012), Project 3 unified API and gateway (to be planned).

## Current task

P1.1: T-101 done (`oif` command line, settings, manifest and uninstall engine, host check, unit tests, guide 1). Next: T-102 host preparation.

## Next step

T-102 host preparation (NVIDIA driver from the Ubuntu archive, swap, kernel settings, containerd, vfio for the W6400; one reboot asked first), then T-103, T-104 and spike S-3.

## Notes

- The reference host has no `curl` or `git` out of the box; oif uses Python and `wget`.
- `sudo` on the reference host needs a password: the owner runs `sudo ./oif ...`; read-only `./oif check` needs no sudo.
- Every step ships with a guide in `docs/guides/` (owner's rule, 2026-10-24).

## Known issues and risks

- Dynamo has no official ROCm support (ADR-002); decided by S-1.
- SGLang ROCm builds target Instinct GPUs; serving on the W7900 (gfx1100) is unproven (S-5).
- TensorRT-LLM support for the A6000 (Ampere) must be checked before T-204.
- KAI quota handling for `amd.com/gpu` is unverified; decided by S-2.
- The open-source Run:ai control plane's footprint on a single node is unknown; measured in S-3.
- The W7900 is a workstation GPU (gfx1100); AMD validates distributed serving stacks on Instinct GPUs.
- Kernel 7.0 inbox amdgpu reports phantom UMC ECC errors on the W7900; the AMD metrics exporter needs a raised threshold or it marks the GPU unhealthy.
- Both GPUs throttle when loaded together (ADR-009).
