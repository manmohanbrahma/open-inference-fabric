# Memory

Current state of the project. Update after every task.

## Status (2026-10-24)

- Phase 0: research and project documents written (T-001). Repository public at github.com/manmohanbrahma/open-inference-fabric (T-002).
- Reference host: clean Ubuntu 26.04.1 after the previous NKP + NAI lab was uninstalled on 2026-10-24. A6000 on nouveau (no NVIDIA driver yet), W7900 and W6400 on amdgpu (no vfio yet).
- T-102 installed on 2026-10-24: NVIDIA 595.91.07 (CUDA 13.2) on the A6000, W6400 on vfio-pci, swap off, containerd 2.2.2 with data in the data folder. W7900 untouched (amdgpu).
- T-103 installed on 2026-10-24: Kubernetes 1.35.9 single node (pods 10.244.0.0/16, services 172.30.0.0/16), Calico v3.32.2, local-path (default, volumes in the data folder), MetalLB pool; smoke test passed; join tokens removed.
- T-105 on 2026-10-24: Run:ai 3.0.20 (control plane + cluster "oif"), kube-prometheus-stack 92.3.0, HAProxy on the first MetalLB address, private CA, sslip.io domain, CoreDNS block for the domain, GPU fractions off (driver 595 < r615). Quota test passed: team-b (0 GPU) NonPreemptibleOverQuota on a free GPU, team-a (1 GPU) ran. Over-quota is off by default in Run:ai.
- T-104 installed on 2026-10-24: GPU Operator v26.7.2 (host driver), nvidia.com/gpu 1, CUDA vectorAdd passed in a pod, DCGM exporter 23 metrics.

## Plan

The owner split the work into three projects (ADR-010): Project 1 orchestration (Run:ai on NVIDIA, then AMD), Project 2 serving with Dynamo and a fair benchmark (NVIDIA, AMD, then engine overlays, ADR-011/012), Project 3 unified API and gateway (to be planned).

## Current task

P1.1: T-101 to T-105 done, spike S-3 passed (guides 1 to 5). Next: P1.2 AMD GPUs (spike S-2, AMD GPU Operator), then T-106 dashboards and T-107 uninstall test.

## Next step

S-3/T-105 run on the host: GPU Operator to v26.7.1, kube-prometheus-stack, HAProxy ingress on the first MetalLB address, private CA and certificate for runai.<ip>.sslip.io, Run:ai 3.0.20 (ADR-013, ADR-014). Then the project/quota test.

## Notes

- The reference host has no `curl` or `git` out of the box; oif uses Python and `wget`.
- `sudo` on the reference host needs a password: the owner runs `sudo ./oif ...`; read-only `./oif check` needs no sudo.
- First real run: an AMD GPU was accepted under NVIDIA_GPUS (only the address was checked); fixed with vendor checks, saved-settings validation and `install --reconfigure`.
- kubeadm init prints join credentials: its output stays in the root-only state folder; the k8s-tokens stage deletes the tokens; the readable install log is redacted.
- Kubernetes' default service range 10.96.0.0/12 overlaps the reference host's subnet; oif picks free ranges.
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
