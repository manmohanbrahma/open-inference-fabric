# 3. Kubernetes, storage and load balancer

**Step:** T-103. **Tested:** 2026-10-24 on Ubuntu 26.04.1 after [guide 2](02-host-preparation.md). About 7 minutes, no reboot.

## What you get

- A single-node Kubernetes **1.35.9** cluster (kubeadm). The node is the control plane and also runs workloads, up to 250 pods.
- **Calico v3.32.2** pod network (VXLAN overlay).
- **local-path** storage (v0.0.37) as the default StorageClass; volumes live in `<INSTALL_DIR>/volumes` on the data disk.
- **MetalLB v0.16.0**, which gives LoadBalancer services an address from your `METALLB_RANGE`.
- **Helm v3.22.1**, and `kubectl` for your own user without `sudo`.

Every downloaded manifest and the Helm archive are checked against a SHA-256 checksum pinned in `versions.env`; oif refuses a file that differs.

## Before you start

- [Guide 2](02-host-preparation.md) finished (`install finished`, containerd running).
- `METALLB_RANGE` holds free addresses on the host's subnet (oif pings them when it asks).

## Steps

### 1. Run the install

```bash
cd ~/open-inference-fabric
sudo ./oif install
```

No questions are asked: the saved settings are used and the finished stages from guide 2 are skipped. The new stages run:

```text
== stage: k8s-packages
  [ok] kubeadm, kubelet, kubectl 1.35.9 (held); helm v3.22.1
== stage: kubernetes
  [ok] pod network 10.244.0.0/16, services 172.30.0.0/16 (no overlap with this host's networks)
== kubeadm init (pulls the control-plane images, 2-5 min)
[init] Using Kubernetes version: v1.35.9
...
  [ok] API server answering
  [ok] Kubernetes 1.35.9 control plane on <host-ip>:6443; kubectl works for <your-user>
== stage: k8s-tokens
  [ok] no join tokens or uploaded certificates left (single node)
== stage: calico
  [ok] Calico running
  [ok] node Ready
== stage: storage
  [ok] default StorageClass local-path, volumes in /shared_storage/oif/volumes
== stage: metallb
  [ok] MetalLB pool <a.b.c.240>-<a.b.c.244>
== stage: k8s-verify
  [ok] all system pods running
  [ok] test volume bound
  [ok] test pod running
  [ok] LoadBalancer address
  [ok] http://<a.b.c.240> answers
  [ok] Kubernetes ready: node <node> Ready v1.35.9, storage and load balancer tested (<a.b.c.240>)
== install finished
```

What happens behind the stages:

| Stage | What it does |
| --- | --- |
| k8s-packages | Adds the official Kubernetes package repository for 1.35 (`pkgs.k8s.io`) with its signing key, installs kubelet, kubeadm and kubectl 1.35.9 and holds them at that version so an `apt upgrade` cannot move them; installs cri-tools and Helm. |
| kubernetes | Picks pod and service address ranges that do not overlap the host's networks, renders [`platform/kubernetes/kubeadm.yaml`](../../platform/kubernetes/kubeadm.yaml) and runs `kubeadm init`. kubeadm's own output goes to `/var/lib/oif/kubeadm-init.log` (root only), because it contains join credentials. |
| k8s-tokens | Deletes the join tokens and the uploaded-certificates secret: no other node ever joins this cluster. |
| calico | Installs the Tigera operator and a Calico installation with the pod range ([`calico-installation.yaml`](../../platform/kubernetes/calico-installation.yaml)). |
| storage | Installs local-path, pointing it at the data disk, and makes it the default StorageClass. |
| metallb | Installs MetalLB and its layer 2 address pool ([`metallb-pool.yaml`](../../platform/kubernetes/metallb-pool.yaml)). |
| k8s-verify | Waits until every pod runs, then creates a test volume, a web server on it and a LoadBalancer service ([`smoke-test.yaml`](../../platform/kubernetes/smoke-test.yaml)), fetches the page through the MetalLB address and deletes the test. |

> **Why the address ranges are chosen, not defaulted.** Kubernetes' default service range is 10.96.0.0/12, which spans 10.96.0.0 to 10.111.255.255. On a host whose own network falls inside it, services and the host's subnet would collide. oif checks every candidate range against the host's addresses and routes and uses the first free one: pods 10.244.0.0/16, services 172.30.0.0/16 on the reference host.

## Check it worked

As your normal user (no `sudo`):

```bash
kubectl get nodes -o wide
kubectl get pods -A
kubectl get storageclass
kubectl -n metallb-system get ipaddresspool
```

Expected:

```text
NAME     STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...   CONTAINER-RUNTIME
<node>   Ready    control-plane   22m   v1.35.9   <host-ip>     ...   containerd://2.2.2

NAMESPACE            NAME                                       READY   STATUS
calico-system        calico-kube-controllers-...                1/1     Running
calico-system        calico-node-...                            1/1     Running
calico-system        calico-typha-...                           1/1     Running
calico-system        csi-node-driver-...                        2/2     Running
kube-system          coredns-... (2)                            1/1     Running
kube-system          etcd-<node>                                1/1     Running
kube-system          kube-apiserver-<node>                      1/1     Running
kube-system          kube-controller-manager-<node>             1/1     Running
kube-system          kube-proxy-...                             1/1     Running
kube-system          kube-scheduler-<node>                      1/1     Running
local-path-storage   local-path-provisioner-...                 1/1     Running
metallb-system       controller-...                             1/1     Running
metallb-system       speaker-...                                1/1     Running
tigera-operator      tigera-operator-...                        1/1     Running

NAME                   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   rancher.io/local-path   Delete          WaitForFirstConsumer

NAME   AUTO ASSIGN   ADDRESSES
oif    true          ["<a.b.c.240>-<a.b.c.244>"]
```

No join tokens remain:

```bash
kubectl -n kube-system get secrets -o name | grep -E 'bootstrap-token|kubeadm-certs' || echo none
```

### Reaching LoadBalancer addresses from your laptop

MetalLB announces its addresses on the host's network segment. If your laptop reaches the host only through a VPN that routes the host's single address, the MetalLB addresses are not routed to you. Use an SSH SOCKS tunnel and a browser profile that sends traffic through it:

```bash
ssh -N -D 127.0.0.1:1080 <user>@<host-ip>
# browser: SOCKS5 proxy 127.0.0.1:1080, with remote DNS
```

## What changed on the host

| Change | Reversed by `oif uninstall` |
| --- | --- |
| `/etc/apt/keyrings/oif-kubernetes.gpg`, `/etc/apt/sources.list.d/oif-kubernetes.list` | Deleted |
| Packages kubelet, kubeadm, kubectl (held), kubernetes-cni, cri-tools | Purged |
| `/usr/local/bin/helm`, `/etc/crictl.yaml` | Deleted |
| Cluster state: `/etc/kubernetes`, `/var/lib/kubelet`, `/var/lib/etcd`, CNI configuration, Calico state, network interfaces `cali*` and `vxlan.calico`, Kubernetes and Calico iptables rules | `kubeadm reset`, files and interfaces removed, only Kubernetes' and Calico's iptables rules dropped |
| `~/.kube/config` for your user | Deleted (the folder too, if oif created it) |
| `<INSTALL_DIR>/volumes` | Deleted with the data folder |

`sudo ./oif plan` lists all of it without changing anything.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `kubeadm init failed` | `sudo less /var/lib/oif/kubeadm-init.log` and `journalctl -u kubelet`. oif runs `kubeadm reset` after a failure, so `sudo ./oif install` starts clean once the cause is fixed. |
| `no free pod network range` / `no free service range` | All candidate ranges overlap the host's networks. Free one of 10.244.0.0/16, 172.20.0.0/16 or 192.168.128.0/17 (pods) and 172.30.0.0/16, 10.112.0.0/16 or 192.168.64.0/18 (services). |
| `checksum mismatch for https://...` | The upstream file changed or the download was altered. Do not bypass it; report it, and pin the new checksum in `versions.env` only after checking the file. |
| `Calico is not available` | `kubectl get tigerastatus` and `kubectl -n calico-system get pods`; image pulls from quay.io and docker.io must work. |
| `MetalLB address pool rejected` | The MetalLB webhook was not ready; run `sudo ./oif install` again. |
| `http://<address> did not answer` | Another device may use that address (`ping`), or layer 2 announcements are blocked on the switch. |
| `kubectl: connection refused` as your user | `~/.kube/config` is missing. Copy it again: `sudo install -D -m 600 -o $USER -g $(id -gn) /etc/kubernetes/admin.conf ~/.kube/config` |
