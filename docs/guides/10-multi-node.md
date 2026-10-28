# 10. Multi-node hybrid cluster: NVIDIA and AMD GPUs on separate nodes

**Step:** T-120, T-121, T-122, T-123 (ADR-017). **Tested:** 2026-10-26 to 2026-10-28 on the [hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab) VMs: three control-plane nodes and two GPU workers, one with an AMD Radeon PRO W7900 and one with an NVIDIA RTX A6000. Addresses are the lab's private subnet, 192.168.120.0/24.

## What you get

- One highly available Kubernetes cluster across all nodes: three control-plane nodes behind one API address held by kube-vip, the GPU servers as workers.
- Each GPU set up on its own node: the NVIDIA driver on NVIDIA nodes, the AMD GPU firmware on AMD nodes, both GPU operators finding their GPUs wherever they are.
- Run:ai with one **node pool per vendor** (`nvidia`, `amd`) and project quotas per pool, which makes them per-vendor quotas; Run:ai's control plane runs on the control-plane nodes.
- oif's Run:ai patches and the ROCm templates (guide 8), the dashboards (guide 7), all on every node.
- One command on the first node does all of it; one command there removes it from every node (guide 9).

| Node | Role | GPU |
| --- | --- | --- |
| cp1, cp2, cp3 | control plane (etcd, API server, kube-vip), runs the platform | none |
| gpu-amd | worker | Radeon PRO W7900 |
| gpu-nvidia | worker | RTX A6000 |

## Before you start

- Every node runs Ubuntu 26.04 (cloud image or server install) and has one user with SSH keys and sudo without a password (the lab's user `oif`).
- The first control-plane node reaches every other node over SSH. You log in to it with your SSH agent forwarded (`ssh -A`): oif uses your access once to install its own key.
- Free addresses on the node subnet: one for the Kubernetes API (`OIF_API_VIP`) and a range for MetalLB (Run:ai, Grafana).
- Each GPU server holds GPUs of one vendor (a node with both stays in Run:ai's default pool, ADR-015).

## Steps

1. Log in to the first control-plane node with your agent forwarded and get oif:

   ```bash
   ssh -A oif@192.168.120.11
   git clone https://github.com/manmohanbrahma/open-inference-fabric.git && cd open-inference-fabric
   cp .env.example .env
   ```

2. In `.env`, list the nodes (this node first) and the addresses, besides the usual settings (Run:ai administrator, passwords):

   ```bash
   OIF_NODES="192.168.120.11:control 192.168.120.12:control 192.168.120.13:control 192.168.120.21:worker 192.168.120.22:worker"
   OIF_API_VIP=192.168.120.10
   METALLB_RANGE=192.168.120.240-192.168.120.244
   HOST_IP=192.168.120.11
   ```

   A label is optional (`cp1=192.168.120.11:control`); it only names the node in logs. Kubernetes uses each machine's hostname.

3. Install, keeping your agent through sudo for the key exchange:

   ```bash
   sudo --preserve-env=SSH_AUTH_SOCK ./oif install
   ```

   The questions come first, then the key exchange, then the install runs as a background job. On the reference run (outputs trimmed):

   ```text
   Nodes
     [ok] cluster SSH key created (/var/lib/oif/ssh/id_ed25519.pub)
     [ok] cp2 (192.168.120.12): cluster key installed through your SSH agent
     [ok] cp3 (192.168.120.13): cluster key installed through your SSH agent
     [ok] gpu-amd (192.168.120.21): cluster key installed through your SSH agent
     [ok] gpu-nvidia (192.168.120.22): cluster key installed through your SSH agent
   == stage: nodes
   == node gpu-nvidia (192.168.120.22, worker)
     [gpu-nvidia]   [ok] NVIDIA 595-server driver installed; it loads after the reboot
     [gpu-nvidia]   [!] a reboot is needed to load the NVIDIA driver instead of nouveau
   == gpu-nvidia: rebooting it for its GPU driver
   (the first node waits until gpu-nvidia answers with a new boot ID, then runs its remaining node stages)
     [gpu-nvidia]   [ok] NVIDIA driver 595.91.07: NVIDIA RTX A6000
   == node gpu-amd (192.168.120.21, worker)
     [gpu-amd]   [ok] AMD GPU firmware installed
     [gpu-amd]   [ok] AMD GPU started by amdgpu
   == stage: kubernetes
     [ok] kube-vip holds the API address 192.168.120.10
   == stage: k8s-join
   == cp2 (192.168.120.12) joins as control
     [cp2]   [ok] joined the cluster at 192.168.120.10:6443 as control
   == gpu-amd (192.168.120.21) joins as worker
     [gpu-amd]   [ok] joined the cluster at 192.168.120.10:6443 as worker
   == stage: k8s-tokens
     [ok] no join tokens or uploaded certificates left (all nodes joined)
   == stage: calico
     [ok] all 5 node(s) Ready
   == stage: gpu-verify
     [ok] nvidia.com/gpu advertised (1 in the cluster)
     [ok] pod saw the GPU, CUDA test passed; DCGM: fb_used=0 gpu_temp=37 power_usage=33.778
   == stage: amd-gpu-verify
     [ok] amd.com/gpu advertised (1 in the cluster)
     [ok] node advertises amd.com/gpu: 1 (gpu.device-id=7448, gpu.family=GC_11_0_0, gpu.product-name=AMD_Radeon_Pro_W7900, gpu.vram=45G)
   == stage: runai
     [ok] Run:ai 3.0.20 installed
   == stage: runai-pools
     [ok] GPU nodes labelled oif.ai/gpu-vendor: gpu-amd=amd gpu-nvidia=nvidia
       node pool nvidia (oif.ai/gpu-vendor=nvidia) Ready
       node pool amd (oif.ai/gpu-vendor=amd) Ready
     [ok] Run:ai counts each vendor's GPUs in its pool
   == stage: runai-patches
     [ok] patched image oif.local/runai-oss/cluster-sync:3.0.20-oif1 on every node (4 loaded now)
   == stage: vendor-quota
     [ok] project team-c (namespace runai-team-c): Run:ai quota 1 GPU in node pool nvidia and 1 in node pool amd
     [ok] team-c runs GPU 0: NVIDIA RTX A6000 on gpu-nvidia and the AMD GPU on gpu-amd
     [ok] a second NVIDIA pod waits in the queue: NonPreemptibleOverQuota: ... team-c-nvidia quota is 1 GPUs, while 1 GPUs are already allocated ...
   == stage: observability-verify
       amd AMD Radeon Pro W7900 (gpu 0): util 0%, memory 0.0 of 45.0 GiB, 6 W, 32 °C
       nvidia NVIDIA RTX A6000 (gpu 0): util 0%, memory 0.0 of 48.0 GiB, 35 W, 43 °C
   == install finished
   ```

   To test a part, `sudo ./oif install --until STAGE` stops after that stage (for example `--until nodes` or `--until k8s-verify`).

| Stage | Multi-node behaviour |
| --- | --- |
| (questions) | creates oif's cluster key on this node, installs it on every other node through your agent; your key on the other control-plane nodes when `ADMIN_KEY_ON_CONTROL=yes` |
| nodes | copies oif to each node and runs the node stages there (`oif _node`): packages, kernel, containerd, NVIDIA driver or AMD firmware, Kubernetes packages; reboots a node when its driver needs it; only the settings a node needs are sent, never passwords or tokens |
| kubernetes | kube-vip on the API address, `kubeadm init` on this node |
| k8s-join | a 30-minute token (and for control-plane nodes the certificate key) over SSH to `oif _node-join` on each node; tokens and uploaded certificates deleted after |
| gpu-operator, amd-gpu-operator and their checks | installed when any node has that vendor's GPU; counted across the cluster, checked on the node that has the GPU |
| runai-pools | labels GPU nodes `oif.ai/gpu-vendor`, creates the Run:ai node pools `nvidia` and `amd` |
| runai-patches | builds on this node, loads the patched images on every node |
| quota tests | in the vendor's pool; the per-vendor test uses Run:ai's pool quotas (a third pod queues) |

## Check it worked

The lab acceptance scripts, run on the first node:

```bash
sudo tests/lab/t120-nodes.sh            # cluster key, node stages on every node
sudo tests/lab/t121-cluster.sh --failover   # 5 nodes Ready, API on the shared address, moves when its holder loses kube-vip
sudo tests/lab/t122-gpus.sh             # each GPU on its driver and node, a pod per vendor on the right node
sudo tests/lab/t123-runai.sh            # pools per vendor, images on every node, placement and quota per pool
```

Results of the reference run (2026-10-28): T-120 66 checks, T-121 14, T-122 20, T-123 27, all PASS. The node reboot was proven by `t120-nodes.sh --reboot gpu-nvidia` (back after 27 s); in the install run itself the lab VM powered off instead of rebooting (a lab bug since fixed) and was started by hand.

```text
T-123 Run:ai on several nodes: node pools per vendor
        amd phase=Ready nodes=gpu-amd gpus 1
        nvidia phase=Ready nodes=gpu-nvidia gpus 1
        default phase=Ready nodes=cp1,cp2,cp3 gpus 0
  PASS  pod in pool nvidia runs on the NVIDIA node (gpu-nvidia)
  PASS  pod in pool amd runs on the AMD node (gpu-amd)
  PASS  a second pod in pool nvidia waits (quota 1 used)
  PASS  an NVIDIA GPU asked for in pool amd is never placed
T-123: PASS (27 checks)
```

A workload chooses a pool with the label `runai/node-pool: nvidia` (or `amd`); in the Run:ai UI, pick the node pool when submitting. A project's quota is set per pool (Organization, Projects).

## What changed on the nodes

Each node keeps its own change record in `/var/lib/oif`, the same kinds as a single host (guide 9): packages, kernel settings, containerd, the NVIDIA driver with nouveau blocked or the AMD firmware package, Kubernetes. The first node also records which nodes it prepared and the keys it added (`NODE`, `NODEKEY`, `ADMINKEY`). `sudo ./oif uninstall` on the first node uninstalls every node from its own record, then removes oif's key and any admin key it added.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `no access yet to: ...` during the questions | Your agent did not reach sudo. Log in with `ssh -A`, run `sudo --preserve-env=SSH_AUTH_SOCK ./oif install`, or add the printed `oif-cluster` key line to `~/.ssh/authorized_keys` on each node. |
| `<node> is not reachable with the cluster key` in stage nodes | The key exchange did not reach it: run `sudo ./oif install --reconfigure` in a terminal with your agent. |
| `<node> did not come back after the reboot` | The node took longer than 10 minutes or powered off. On lab VMs created before hybrid-gpu-lab 3e126ce, the first reboot powers the VM off: start it (`virsh start hl-<name>`) and run the install again, or recreate the lab. |
| `AMD GPU ... not started by amdgpu` | The firmware is installed but the driver could not reload: the stage asks for a reboot; on a node it does that itself. |
| `kubeadm join failed` | On that node: `sudo less /var/lib/oif/kubeadm-join.log`. The token lives 30 minutes; run the install again for a new one. |
| A pod in a vendor pool stays Pending with `NonPreemptibleOverQuota` | The project's quota in that pool is used: this is the per-vendor quota working. |
| Run:ai pods in `ImagePullBackOff` for `oif.local/runai-oss/*` | A node is missing a patched image: run the install again (the runai-patches stage loads it on every node), or check with `sudo tests/lab/t123-runai.sh`. |

## Known limits

- GPU fractions stay off while the NVIDIA driver is older than r615 (T-108); the cluster shows Run:ai's "Missing prerequisites" for that.
- A node with GPUs of both vendors cannot be split into two pools; it stays in the default pool (ADR-015 applies there).
- The vendor-agnostic job surface and accelerator domains are P1.4 (ADR-019).
