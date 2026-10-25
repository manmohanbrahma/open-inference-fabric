# Memory

Current state of the project. Update after every task.

## Status (2026-10-24)

- Phase 0: research and project documents written (T-001). Repository public at github.com/manmohanbrahma/open-inference-fabric (T-002).
- Reference host: clean Ubuntu 26.04.1 after the previous NKP + NAI lab was uninstalled on 2026-10-24. A6000 on nouveau (no NVIDIA driver yet), W7900 and W6400 on amdgpu (no vfio yet).
- T-102 installed on 2026-10-24: NVIDIA 595.91.07 (CUDA 13.2) on the A6000, W6400 on vfio-pci, swap off, containerd 2.2.2 with data in the data folder. W7900 untouched (amdgpu).
- T-103 installed on 2026-10-24: Kubernetes 1.35.9 single node (pods 10.244.0.0/16, services 172.30.0.0/16), Calico v3.32.2, local-path (default, volumes in the data folder), MetalLB pool; smoke test passed; join tokens removed.
- T-105 on 2026-10-24: Run:ai 3.0.20 (control plane + cluster "oif"), kube-prometheus-stack 92.3.0, HAProxy on the first MetalLB address, private CA, sslip.io domain, CoreDNS block for the domain, GPU fractions off (driver 595 < r615). Quota test passed: team-b (0 GPU) NonPreemptibleOverQuota on a free GPU, team-a (1 GPU) ran. Over-quota is off by default in Run:ai.
- T-104 installed on 2026-10-24: GPU Operator v26.7.1 (host driver), nvidia.com/gpu 1, CUDA vectorAdd passed in a pod, DCGM exporter 23 metrics.
- T-111 and S-2 on 2026-10-25: AMD GPU Operator v1.5.1 on the in-kernel amdgpu driver; amd.com/gpu 1 (W7900, 45G, GC_11_0_0); pod got /dev/kfd and renderD; exporter healthy (raised UMC ECC threshold) and scraped by Prometheus. Run:ai quota enforced on amd.com/gpu (team-b NonPreemptibleOverQuota, team-a ran). One GPU quota counts both vendors.
- T-113 on 2026-10-25 (ADR-015): project team-c, Run:ai quota 2, ResourceQuota oif-gpu-vendor caps 1 NVIDIA + 1 AMD; both pods ran, a second NVIDIA pod was refused (exceeded quota). Run:ai accepted quota 2 although its node inventory lists only the A6000; its metrics count both vendors (team-c allocated 2) while its Projects page showed 1.
- T-106/T-112/T-114 on 2026-10-25: PrometheusRule oif-gpu (oif:gpu_*, oif:node_*, per-vendor allocatable/requested/caps, Run:ai project series; promtool tests), dashboards OIF Fleet and OIF Scheduling, Grafana at https://grafana.<runai-domain> (Run:ai wildcard certificate). Both vendors on every GPU panel. AMD graphics clock reads 0 at idle.

## Plan

The owner split the work into three projects (ADR-010): Project 1 orchestration (Run:ai on NVIDIA, then AMD), Project 2 serving with Dynamo and a fair benchmark (NVIDIA, AMD, then engine overlays, ADR-011/012), Project 3 unified API and gateway (to be planned).

## Current task

P1.1: T-101 to T-105 done, spike S-3 passed (guides 1 to 5). P1.2: T-111 and T-113 done, spike S-2 passed (guide 6). T-106, T-112, T-114 done (guide 7). T-107 uninstall and reinstall passed. T-115 done (guide 8): oif patches Run:ai so it counts and shows AMD GPUs.

## Next step

P1.3 multi-node (ADR-017): T-120 node list, cluster key and per-node runner, then T-121 to T-124 on the hybrid-gpu-lab VMs (T-119 done). Then Project 2 (Dynamo), then Project 3 (AI gateway, ADR-018 proposed, spike S-6). Also open: guide 9 (uninstall), T-116 KAI vendor-aware placement.

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
- Run:ai GPU quotas count `amd.com/gpu` (S-2) as one count with NVIDIA; per-vendor caps come from a Kubernetes ResourceQuota (ADR-015). Stock Run:ai's GPU inventory lists only NVIDIA GPUs; oif's patches (ADR-016) add the AMD GPU.
- The KAI scheduler adds both vendors into one GPU count per node: on a mixed node it can bind an NVIDIA pod when only the AMD GPU is free (kubelet `UnexpectedAdmissionError`); T-116.
- With GPU fractions off (T-108), patched Run:ai shows the cluster as Missing prerequisites (fractions unavailable); the node is Ready and whole-GPU workloads run.
- The lab's internet link can drop to tens of KB/s; the Run:ai patch builds keep the source and caches in the state folder and retry.
- AMD GPU Operator v1.5.1 needs `kmm.watch: false` as well as `kmm.enabled: false`, or its controller crash-loops after two minutes.
- The open-source Run:ai control plane's footprint on a single node is unknown; measured in S-3.
- The W7900 is a workstation GPU (gfx1100); AMD validates distributed serving stacks on Instinct GPUs.
- Kernel 7.0 inbox amdgpu reports phantom UMC ECC errors on the W7900; the AMD metrics exporter needs a raised threshold or it marks the GPU unhealthy.
- Both GPUs throttle when loaded together (ADR-009).
