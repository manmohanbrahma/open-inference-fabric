# 6. AMD GPU Operator and Run:ai quotas on AMD GPUs

**Step:** T-111, spike S-2 and T-113. **Tested:** 2026-10-25, AMD GPU Operator v1.5.1 with a Radeon PRO W7900 on the reference host.

## What you get

- The cluster schedules the AMD GPU as `amd.com/gpu`, next to the NVIDIA GPU's `nvidia.com/gpu`.
- The node carries AMD labels: product name, VRAM, GPU family and device id.
- The AMD device metrics exporter publishes temperature, VRAM and health on port 5000, with a Prometheus ServiceMonitor.
- Run:ai project quotas apply to the AMD GPU (spike S-2).

The kernel's own `amdgpu` driver is used: the operator builds no driver and loads no kernel module.

## Before you start

- Guides 1 to 5 done: Run:ai installed, its quota test passed.
- The AMD GPU is on the `amdgpu` driver (not isolated to vfio-pci in `.env`), and `/dev/kfd` exists. `./oif check` lists both.

## Steps

1. Run the installer. It continues after the Run:ai stages:

   ```bash
   cd ~/open-inference-fabric
   sudo ./oif install        # runs stages amd-gpu-operator, amd-gpu-verify, amd-quota
   ```

2. Expected output (about 5 minutes):

   ```text
   == stage: amd-gpu-operator
     [ok] metrics exporter: UMC ECC health threshold raised for the Radeon PRO workstation GPU on kernel 7.0.0-38-generic
   == AMD GPU Operator v1.5.1 (2-5 min)
     [ok] AMD GPU node labelled by Node Feature Discovery
     [ok] AMD device plugin running
     [ok] AMD GPU Operator pods running
   == stage: amd-gpu-verify
     [ok] amd.com/gpu advertised
     [ok] node advertises amd.com/gpu: 1 (gpu.device-id=7448, gpu.family=GC_11_0_0, gpu.product-name=AMD_Radeon_Pro_W7900, gpu.vram=45G)
     [ok] AMD test pod finished
       crw-rw----    1 root     990       226, 129 ... /dev/dri/renderD129
       crw-rw----    1 root     990       503,   0 ... /dev/kfd
     [ok] AMD GPU metrics
     [ok] pod got the AMD GPU; metrics: gpu_edge_temperature=30 gpu_health=1 gpu_junction_temperature=36 gpu_total_vram=46064 gpu_used_vram=92
   == stage: amd-quota
     [ok] team-b (quota 0) waits while the AMD GPU is free: NonPreemptibleOverQuota: Non-preemptible workload is over quota. Workload requested 1 GPUs, but team-b quota is 0 GPUs, ...
     [ok] team-a (quota 1) gets the AMD GPU
     [ok] team-a runs with /dev/kfd  /dev/dri: card0 renderD129 ; team-b still Pending
     [ok] S-2 passed: Run:ai enforces quotas on amd.com/gpu
   == install finished
   ```

| Stage | What it does |
| --- | --- |
| amd-gpu-operator | Checks the GPU is on `amdgpu` and `/dev/kfd` exists; creates namespace `kube-amd-gpu` and the exporter's config (raised UMC ECC threshold for W7900/W7800 cards); installs the pinned chart with the values in `platform/gpu-amd/values.yaml`; waits for the NFD label and the device plugin. |
| amd-gpu-verify | Waits for `amd.com/gpu` to equal the number of AMD GPUs; prints the AMD labels; runs a pod that requests the GPU and lists `/dev/kfd` and `/dev/dri`; reads the metrics exporter. |
| amd-quota | Uses the Run:ai projects from guide 5 (team-a 1 GPU, team-b 0); a pod requesting `amd.com/gpu` stays pending in team-b and runs in team-a. |

## Check it worked

```bash
kubectl -n kube-amd-gpu get pods                       # controller, default-device-plugin, default-node-labeller, default-metrics-exporter: Running
kubectl get node -o jsonpath='{.items[0].status.allocatable}'; echo   # "amd.com/gpu":"1" and "nvidia.com/gpu":"1"
kubectl get node --show-labels | tr , '\n' | grep amd.com/gpu
curl -s http://$(kubectl -n kube-amd-gpu get svc default-metrics-exporter -o jsonpath='{.spec.clusterIP}'):5000/metrics | grep '^gpu_health'
```

A workload asks for the AMD GPU with:

```yaml
resources:
  limits:
    amd.com/gpu: 1
```

## Chart settings that matter

From `platform/gpu-amd/values.yaml`:

| Setting | Why |
| --- | --- |
| `node-feature-discovery.enabled: false`, `installdefaultNFDRule: true` | NFD already runs from the NVIDIA GPU Operator; only AMD's rule is added. |
| `kmm.enabled: false`, `kmm.watch: false` | No driver build. Both are needed: with only the first, the v1.5.1 controller waits for KMM's resource types, exits after two minutes and never creates the device plugin. |
| `crds.defaultCR.upgrade: true` | oif owns the default DeviceConfig; a rerun re-applies it. |
| `remediation.enabled: false`, `draDriver.deviceClass.create: false` | No Argo remediation workflows; GPUs come from the device plugin, not Dynamic Resource Allocation. |
| `resource_naming_strategy: single` | Every AMD GPU is `amd.com/gpu`. |
| exporter config `amd-metrics-config` | Kernel 7.0's in-box amdgpu reports phantom UMC ECC errors on the W7900; the default threshold would mark the GPU unhealthy. |

## What changed on the host

Nothing on the host itself: the step adds Kubernetes objects only (namespace `kube-amd-gpu`, Helm release `amd-gpu-operator`, the DeviceConfig `default`, NFD rule, CRDs). `oif uninstall` removes them with the cluster. The chart is cached in `/var/lib/oif/charts/`.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `amd.com/gpu advertised: not reached`; no `default-device-plugin` DaemonSet; controller in CrashLoopBackOff with `no matches for kind "Module" in version "kmm.sigs.x-k8s.io/v1beta1"` | `kmm.watch` was left on. Fixed in oif (values revision `v1.5.1-r2`); `sudo ./oif install` reruns the stage. |
| `gpu_health` 0 on a Radeon PRO W7900 | Phantom UMC ECC errors on kernel 7.0; check that configmap `amd-metrics-config` carries the raised threshold. |
| `<bdf> is on driver 'vfio-pci', not amdgpu` | The GPU is isolated for VMs in `.env` (`ISOLATE_GPUS`); remove it there, run `sudo ./oif install --reconfigure` and reboot when asked. |
| `/dev/kfd is missing` | The amdgpu driver did not enable compute: `sudo dmesg \| grep -i kfd`. |

## Per-vendor quotas (T-113)

A Run:ai project's GPU quota is a single count for both vendors, and a Run:ai node pool is a node label, so one node holding both GPUs cannot be split into `nvidia` and `amd` pools (ADR-015). oif keeps Run:ai's total quota and adds a Kubernetes ResourceQuota per vendor in the project's namespace (`platform/runai/vendor-quota.yaml`).

Stage `vendor-quota` (tested 2026-10-25) creates project team-c with a Run:ai quota of 2 GPUs, caps it at 1 NVIDIA + 1 AMD, runs one pod per vendor and tries a second NVIDIA pod:

```text
== stage: vendor-quota
resourcequota/oif-gpu-vendor created
  [ok] project team-c (Run:ai quota 2 GPUs, namespace runai-team-c) capped at 1 NVIDIA + 1 AMD GPU
  [ok] team-c runs one GPU of each vendor
  [ok] team-c runs GPU 0: NVIDIA RTX A6000 and the AMD GPU (/dev/kfd  /dev/dri: card0 renderD129 )
  [ok] a second NVIDIA GPU pod is refused: exceeded quota: oif-gpu-vendor, requested: requests.nvidia.com/gpu=1, used: requests.nvidia.com/gpu=1, limited: requests.nvidia.com/gpu=1
  [ok] T-113 passed: per-vendor GPU caps inside one Run:ai project (project team-c and its quota kept)
```

To cap another project, apply the same template to its namespace:

```bash
NS=runai-<project> NVIDIA_GPU_CAP=1 AMD_GPU_CAP=1   # then substitute into platform/runai/vendor-quota.yaml and kubectl apply
kubectl -n runai-<project> describe resourcequota oif-gpu-vendor
```

A pod over a vendor cap is refused when it is created (`exceeded quota`), not queued; Run:ai's own quota still queues pods over the project's total.

## Known limits

- **Run:ai has no vendor split.** Its GPU inventory (Nodes and Node pools pages, node API) lists only the A6000 (`gpuCount: 1`), while its allocation figures count the AMD GPU only in places: with one pod per vendor running in team-c, the Nodes page shows 1 A6000 with 2 GPUs allocated and Run:ai's metrics give team-c 2, but the Projects page shows team-c with 1. The vendor split is in oif's Grafana dashboards (T-114).
- The W7900 is a workstation GPU; Run:ai documents data-centre GPUs. Whole-GPU scheduling works; GPU fractions are NVIDIA-only.
