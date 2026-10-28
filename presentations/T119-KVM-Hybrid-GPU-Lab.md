# T-119 — KVM Hybrid GPU Lab

**Status:** Done (2026-10-26)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Lab repo:** [manmohanbrahma/hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab)  
**Related:** TASKS.md P1.3 · ADR-017 (multi-node design) · hybrid-gpu-lab README & GUIDE

---

## 1. What T-119 delivers

| Capability | Description |
|------------|-------------|
| **Repeatable KVM lab** | One-command create/destroy/recreate of a 5-VM hybrid cluster that emulates production (one vendor per server). |
| **PCI passthrough** | Physical AMD Radeon PRO W7900 and NVIDIA RTX A6000 passed through to dedicated worker VMs. |
| **Clean host** | Host packages, vfio binding and lab state are recorded and fully reversible with `host-clean`. |
| **Ready for oif** | Fixed IPs on a private subnet, Ubuntu cloud images, passwordless sudo, lab + optional admin keys — ready for the multi-node installer. |

The lab is a **separate project**. It builds machines; Open Inference Fabric installs the cluster on them.

---

## 2. Lab topology

```
Host (single server with both GPUs, IOMMU enabled)
│
├── libvirt NAT network 192.168.120.0/24
│   │
│   ├── cp1   (control)  192.168.120.11   24 vCPU / 48 GiB / 500 GiB
│   ├── cp2   (control)  192.168.120.12   24 vCPU / 48 GiB / 500 GiB
│   ├── cp3   (control)  192.168.120.13   24 vCPU / 48 GiB / 500 GiB
│   ├── gpu-amd (worker) 192.168.120.21   48 vCPU / 96 GiB / 800 GiB  ← W7900 passthrough
│   └── gpu-nvidia (worker) 192.168.120.22 48 vCPU / 96 GiB / 800 GiB ← A6000 passthrough
```

- Odd number of control-plane VMs for etcd majority.
- Workers own exactly one physical GPU each (full PCI functions + HDMI audio).
- Drivers are **not** installed by the lab; the oif installer does that per node.

---

## 3. End-to-end workflow

```bash
cp lab.conf.example lab.conf   # set LAB_STORAGE, GPU PCI addresses, sizes
./lab plan                     # dry-run
sudo ./lab create              # host setup (first time) + network + VMs
sudo ./lab status
sudo ./lab ssh gpu-nvidia      # or ssh oif@192.168.120.22
sudo ./lab destroy             # VMs, disks, network gone; host setup kept
sudo ./lab recreate            # destroy then create
sudo ./lab host-clean          # also undo host packages and vfio bindings
```

### Design notes

- Ubuntu 26.04 LTS cloud image, pinned and checksum-verified.
- UEFI (OVMF_CODE_4M.fd, secure boot off), q35 machine, host CPU model, 256 GiB 64-bit PCI window for large GPU BARs.
- Lab SSH key installed on every VM; admin public key optional (all / control only / none).
- `oif` user has passwordless sudo; password login disabled.
- GPUs must be in their own IOMMU groups and unbound from the host before create.

---

## 4. What changes on the host (and how it is undone)

| Change | Undone by |
|--------|-----------|
| Packages (qemu, libvirt, virtinst, ovmf, driverctl, …) | `host-clean` (only those it installed) |
| GPU functions bound to `vfio-pci` (persistent via driverctl) | `host-clean` + reboot |
| libvirt network `hl-*`, VMs, thin disks under `LAB_STORAGE` | `destroy` |
| `/var/lib/hybrid-lab` state, lab key, seeds, base image | `host-clean` |

---

## 5. Acceptance / verification

- `tests/run.sh` in the lab repo: shellcheck + plan rendering (network XML, cloud-init keys per role, virt-install lines with both GPU functions).
- Manual: both GPUs initialise inside their VMs and survive a `lab recreate`.
- Passed 2026-10-26: drivers come up in the VMs; the lab is the test bed for all subsequent P1.3 tasks (T-120 …).

Guide with every step and real output: [docs/GUIDE.md](https://github.com/manmohanbrahma/hybrid-gpu-lab/blob/main/docs/GUIDE.md) (also published at the project site).

---

## 6. Key source files (hybrid-gpu-lab)

| Path | Role |
|------|------|
| `lab` | Main CLI (create / destroy / plan / status / ssh / host-clean) |
| `lab.conf.example` | Sizes, PCI addresses, network, storage |
| `versions.env` | Pinned cloud image |
| `docs/GUIDE.md` | Full walk-through with outputs |
| `tests/run.sh` | Static checks |

In open-inference-fabric the lab is referenced from TASKS.md (T-119) and used by `tests/lab/t12*.sh`.

---

## 7. Summary

| | |
|---|---|
| **Outcome** | Repeatable 5-VM hybrid GPU lab with real PCI passthrough, clean host lifecycle |
| **Mechanism** | libvirt + cloud-init + vfio-pci + UEFI with large MMIO window |
| **Safety** | Everything recorded; `destroy` and `host-clean` reverse it |
| **Proof** | Drivers initialise and survive recreate; used as the P1.3 test bed |
| **Next** | T-120 node list & cluster key on these VMs → T-121 HA Kubernetes → T-122 GPUs on their nodes |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the hybrid-gpu-lab project.*
