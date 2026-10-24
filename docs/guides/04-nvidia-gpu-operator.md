# 4. NVIDIA GPU Operator

**Step:** T-104. **Tested:** 2026-10-24 on the cluster from [guide 3](03-kubernetes.md), RTX A6000, driver 595.91.07. About 3 minutes.

## What you get

The NVIDIA GPU Operator **v26.7.2** with its default stack, so Kubernetes can schedule the NVIDIA GPU and report its health:

| Component | Version | What it does |
| --- | --- | --- |
| Container toolkit | v1.20.1 | Lets containers use the GPU (adds an `nvidia` runtime to containerd and writes CDI device specs) |
| Device plugin | v0.20.1 | Advertises `nvidia.com/gpu` on the node, so pods can request a GPU |
| GPU feature discovery | v0.20.1 | Labels the node with the GPU model, memory, driver and CUDA versions |
| DCGM exporter | 4.6.1 | Exports GPU metrics (temperature, power, memory, clocks, utilisation, errors) on port 9400 |
| Node Feature Discovery | (chart) | Detects the node's hardware so the operator knows where the GPUs are |
| MIG manager | v0.15.1 | Manages MIG partitioning on GPUs that support it (the A6000 does not; it stays idle) |
| Validator | v26.7.2 | Runs a CUDA check after every change |

The one change from the defaults is in [`platform/gpu-nvidia/values.yaml`](../../platform/gpu-nvidia/values.yaml): `driver.enabled: false`. The host already runs the NVIDIA driver from the Ubuntu archive (guide 2), the same 595.91.07 version the operator would otherwise build in a container.

The chart is downloaded from `helm.ngc.nvidia.com` and checked against the SHA-256 published in NGC's chart index (pinned in `versions.env`).

## Before you start

- [Guide 3](03-kubernetes.md) finished: the node is Ready, every pod runs.
- `nvidia-smi` works on the host.

## Steps

### 1. Run the install

```bash
cd ~/open-inference-fabric
sudo ./oif install
```

Only the new stages run:

```text
== stage: gpu-operator
== GPU Operator v26.7.2 (pulls the operator images, 3-8 min)
Release "gpu-operator" does not exist. Installing it now.
STATUS: deployed
  [ok] GPU Operator ready (ClusterPolicy)
== stage: gpu-verify
  [ok] nvidia.com/gpu advertised
  [ok] node advertises nvidia.com/gpu: 1 (NVIDIA-RTX-A6000)
  [ok] CUDA test pod finished
    GPU 0: NVIDIA RTX A6000 (UUID: GPU-...)
    Copy output data from the CUDA device to the host memory
    Test PASSED
    Done
  [ok] DCGM metrics
  [ok] pod saw the GPU, CUDA test passed; DCGM: fb_used=0 gpu_temp=39 power_usage=33.965
== install finished
```

What the verification does:

1. Waits until the node advertises as many `nvidia.com/gpu` as there are NVIDIA GPUs in your settings, and has the GPU model label.
2. Starts the pod in [`platform/gpu-nvidia/gpu-test.yaml`](../../platform/gpu-nvidia/gpu-test.yaml): it requests one GPU, runs `nvidia-smi -L`, then NVIDIA's CUDA `vectorAdd` sample, and must print `Test PASSED`. The pod is deleted afterwards.
3. Reads temperature, power and memory from the DCGM exporter.

## Check it worked

```bash
kubectl -n gpu-operator get pods
kubectl get clusterpolicy cluster-policy -o jsonpath='{.status.state}{"\n"}'
kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}{"\n"}'
kubectl get node -o json | jq -r '.items[0].metadata.labels | to_entries[] | select(.key | test("nvidia.com/(gpu.product|gpu.memory|cuda.driver-version.full|gpu.compute.major)")) | "\(.key)=\(.value)"'
```

Expected:

```text
NAME                                                READY   STATUS
gpu-feature-discovery-...                           1/1     Running
gpu-operator-...                                    1/1     Running
gpu-operator-node-feature-discovery-gc-...          1/1     Running
gpu-operator-node-feature-discovery-master-...      1/1     Running
gpu-operator-node-feature-discovery-worker-...      1/1     Running
nvidia-container-toolkit-daemonset-...              1/1     Running
nvidia-cuda-validator-...                           0/1     Completed
nvidia-dcgm-exporter-...                            1/1     Running
nvidia-device-plugin-daemonset-...                  1/1     Running
nvidia-operator-validator-...                       1/1     Running
ready
1
nvidia.com/cuda.driver-version.full=595.91.07
nvidia.com/gpu.compute.major=8
nvidia.com/gpu.memory=49140
nvidia.com/gpu.product=NVIDIA-RTX-A6000
```

GPU metrics, straight from the exporter (from the host):

```bash
ip=$(kubectl -n gpu-operator get svc nvidia-dcgm-exporter -o jsonpath='{.spec.clusterIP}')
curl -s http://$ip:9400/metrics | grep -E '^DCGM_FI_DEV_(GPU_TEMP|POWER_USAGE|FB_USED|FB_FREE|SM_CLOCK|GPU_UTIL)' | sed -E 's/\{[^}]*\}//'
```

```text
DCGM_FI_DEV_FB_FREE 48540
DCGM_FI_DEV_FB_USED 0
DCGM_FI_DEV_GPU_TEMP 39
DCGM_FI_DEV_GPU_UTIL 0
DCGM_FI_DEV_POWER_USAGE 33.86
DCGM_FI_DEV_SM_CLOCK 210
```

These are the hardware metrics the Fleet dashboard will show (guide 6).

### Use the GPU in your own pods

Request it as a resource and use the `nvidia` runtime class:

```yaml
spec:
  runtimeClassName: nvidia
  containers:
    - name: app
      image: <your CUDA image>
      resources:
        limits:
          nvidia.com/gpu: 1
```

From guide 5 on, GPU workloads are submitted through Run:ai projects, which apply quotas.

## What changed on the host

| Change | Reversed by `oif uninstall` |
| --- | --- |
| Namespace `gpu-operator` with the operator and its components | `helm uninstall` first, so the toolkit removes its own changes |
| `/etc/containerd/conf.d/99-nvidia.toml` (the `nvidia` runtime, included by containerd's config) | Removed by the toolkit; oif deletes it if left |
| `/usr/local/nvidia` (toolkit binaries) | Removed by the toolkit; oif deletes it if left |
| `/var/run/cdi/k8s.device-plugin.nvidia.com-gpu.json`, `/var/run/cdi/management.nvidia.com-gpu.yaml` (CDI device specs) | Deleted |
| Runtime classes `nvidia`, `nvidia-cdi`, `nvidia-legacy`; node labels | Removed with the cluster |

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `GPU Operator not ready` | `kubectl -n gpu-operator get pods`; for a pod that is not Running, `kubectl -n gpu-operator logs <pod>`. Image pulls from `nvcr.io` must work. |
| `nvidia-operator-validator` stuck in `Init` | The host driver is not loaded: check `nvidia-smi` on the host and guide 2. |
| `the node does not advertise 1 nvidia.com/gpu` | `kubectl -n gpu-operator logs ds/nvidia-device-plugin-daemonset`. A GPU bound to `vfio-pci` is not visible to the device plugin. |
| `CUDA vectorAdd did not pass` | `kubectl -n oif-gpu-test logs cuda -c vectoradd`. A CUDA error usually means a driver and toolkit mismatch; check the validator logs. |
| `no DCGM metrics` | `kubectl -n gpu-operator logs ds/nvidia-dcgm-exporter`. |
