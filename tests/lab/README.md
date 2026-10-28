# Lab acceptance tests

One script per task that needs real machines. Each prints `PASS` or `FAIL` per check and exits non-zero on any failure; a task is marked done in [TASKS.md](../../TASKS.md) only when its script passes. They run on the multi-node cluster built from the [hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab) VMs (or any cluster with the same roles).

| Script | Task | Run on | After |
| --- | --- | --- | --- |
| `t120-nodes.sh [--reboot NODE]` | T-120 node list, cluster key, node runner | the first node, with sudo | `sudo ./oif install --until nodes` (or a full install) |
| `t121-cluster.sh [--failover]` | T-121 highly available Kubernetes across the nodes | the first node, with sudo | `sudo ./oif install --until k8s-verify` (or later) |
| `t122-gpus.sh` | T-122 GPUs on their nodes, both operators | the first node, with sudo | `sudo ./oif install --until amd-gpu-verify` (or later) |
| `t123-runai.sh` | T-123 Run:ai node pools per vendor, per-pool quotas, patched images on every node | the first node, with sudo | a full `sudo ./oif install` |

What each checks:

- **t120-nodes.sh**: several nodes in the settings and this host first; the cluster key exists and is root-only; for every other node: reachable with the cluster key alone (no agent) and sudo without a password, recorded for uninstall, oif copied, every node stage done, only the node settings sent (no passwords or tokens), its own change record; on NVIDIA nodes the driver loaded and nouveau blocked. `--reboot NODE` reboots that node the way the node runner does and requires it back within 15 minutes.

- **t121-cluster.sh**: every node Ready, the control-plane count, no node tainted against workloads, one etcd member and API server per control-plane node, no join tokens or uploaded certificates left, kubeconfig on the API endpoint; with a shared address: the API answers there and one kube-vip runs per control-plane node. `--failover` takes kube-vip off the node holding the address, requires another node to take it with the API still answering, then restores it.

- **t122-gpus.sh**: the cluster's GPU inventory (at least one per vendor); per GPU: its driver, `nvidia-smi` or `/dev/kfd`, and the node offering it; the cluster offers exactly as many `nvidia.com/gpu` and `amd.com/gpu` as there are GPUs and nodes without GPUs offer none; both operators ready; one test pod per vendor lands on that vendor's node and gets only its GPU; both exporters report.

- **t123-runai.sh**: GPU nodes labelled `oif.ai/gpu-vendor` and no other node; Run:ai pools `nvidia` and `amd` Ready with each vendor's GPUs; the three patched images on every node and in use; with project team-c (quota 1 per pool): a pod per pool runs on that vendor's node, a second NVIDIA pod waits on quota, an NVIDIA GPU asked for in pool `amd` is never placed.

Unit tests that need no machines are in `tests/unit` (`tests/run.sh`); the read-only clean-host check after an uninstall is `tests/host/verify-clean.sh`.
