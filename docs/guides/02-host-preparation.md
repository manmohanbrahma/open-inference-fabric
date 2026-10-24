# 2. Host preparation: NVIDIA driver, kernel settings, container runtime, GPU isolation

**Step:** T-102. **Tested:** 2026-10-24 on Ubuntu 26.04.1, kernel 7.0.0-38, RTX A6000 + Radeon PRO W7900 + Radeon PRO W6400. About 3 minutes, plus one reboot.

## What you get

- The NVIDIA driver from the Ubuntu archive (595.91.07, CUDA 13.2) running the NVIDIA GPU, instead of the open-source `nouveau` driver.
- AMD display cards bound to `vfio-pci`, so Kubernetes cannot claim them.
- containerd 2.2, the container runtime Kubernetes uses, with its images on the data disk.
- Kernel modules and settings Kubernetes needs; swap off.

AMD compute GPUs are not changed in this step; they are added in Project 1.2.

## Before you start

- [Guide 1](01-prepare-host.md) done: code downloaded, `.env` written, `./oif check` reviewed.
- Secure Boot: off on the reference host. With Secure Boot on, Ubuntu's prebuilt NVIDIA modules are signed by Canonical and load as well.
- The host can be rebooted once.

## Steps

### 1. Start the install

```bash
cd ~/open-inference-fabric
sudo ./oif install
```

oif asks every question first. Settings already in `.env` are used without asking.

```text
GPUs on this host
  0000:82:00.0 NVIDIA  GA102GL [RTX A6000]            nouveau   compute
  0000:c8:00.0 AMD     Navi 31 [Radeon Pro W7900]     amdgpu    compute
  0000:03:00.0 AMD     Navi 24 [Radeon PRO W6400]     amdgpu    display only (isolate)
  0000:ca:00.0 other   ASPEED Graphics Family         ast       ignored
   NVIDIA GPUs for Kubernetes (addresses from the NVIDIA lines, comma-separated; empty = all):
   AMD GPUs for Kubernetes from Project 1.2 (addresses from the AMD compute lines; empty = all):
```

| Question | Answer |
| --- | --- |
| NVIDIA GPUs | Enter for all, or addresses from the **NVIDIA** lines only |
| AMD GPUs | Enter for all, or addresses from the **AMD compute** lines only |
| Run:ai e-mail and passwords | Your own; passwords are not shown while you type and need 12 characters or more |
| NGC key, Hugging Face token | Paste them, or Enter to give them later |
| May oif reboot this host by itself | `y` |
| Start with these settings | `y` |

A GPU listed under the wrong vendor is refused with the reason, for example `0000:c8:00.0 is not an NVIDIA GPU`.

### 2. Watch it run

The install continues as a background job, so a dropped SSH session does not stop it. The screen follows the log:

```text
== stage: preflight
  [ok] data folder /shared_storage/oif
== stage: host-packages
  [ok] base packages (5 recorded for uninstall)
== stage: kernel
  [ok] swap off (uninstall turns it back on)
  [ok] kernel modules overlay, br_netfilter; IP forwarding and bridge filtering on
== stage: containerd
  [ok] containerd running
  [ok] containerd 2.2.2, data in /shared_storage/oif/containerd
== stage: nvidia-driver
== installing the NVIDIA 595-server driver (headless, open kernel modules, prebuilt for kernel 7.0.0-38-generic)
  [ok] NVIDIA 595-server driver installed; it loads after the reboot
== stage: gpu-isolation
  [ok] vfio-pci set for device ids 1002:7422,1002:ab28; it takes effect after the reboot
== stage: reboot
  [!] a reboot is needed to load the NVIDIA driver instead of nouveau; bind 0000:03:00.0 to vfio-pci
  rebooting in 10 s (agreed at the start); the install continues after the reboot
```

The SSH session closes when the host reboots.

### 3. After the reboot

Wait about two minutes, log in again and follow the log. No `sudo` is needed to read it:

```bash
tail -f /var/log/oif-install.log
```

```text
== stage: reboot
  [ok] no reboot needed
== stage: host-verify
  [ok] NVIDIA driver 595.91.07: NVIDIA RTX A6000
  [ok] isolated on vfio-pci: 0000:03:00.0
  [ok] swap off
  [ok] containerd running
== install finished
```

### 4. Run it again

A second run must change nothing:

```bash
sudo ./oif install
```

```text
Using the settings saved by the first run (/var/lib/oif/settings.conf); finished stages are skipped.
== install finished
```

## Check it worked

```bash
nvidia-smi --query-gpu=name,driver_version,memory.total,temperature.gpu --format=csv
lspci -k -s 0000:03:00.0 | grep 'in use'          # your isolated card
swapon --show                                     # no output
sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables
systemctl is-active containerd
sudo ./oif status
```

Expected:

```text
name, driver_version, memory.total [MiB], temperature.gpu
NVIDIA RTX A6000, 595.91.07, 49140 MiB, 32
	Kernel driver in use: vfio-pci
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
active
```

`nvidia-smi` reports **CUDA Version: 13.2**, which meets Dynamo's requirement of driver 580 or newer with CUDA 13.

## What changed on the host

| Change | Reversed by `oif uninstall` |
| --- | --- |
| Packages: conntrack, curl, ipset, socat; containerd 2.2.2, runc 1.4.0; NVIDIA 595-server headless driver, prebuilt open kernel modules, utilities (18 packages with dependencies) | Purged, unless a package the OS had before depends on one |
| `/etc/modules-load.d/90-oif.conf`, `/etc/sysctl.d/90-oif.conf` | Deleted |
| Swap line in `/etc/fstab` commented out (`# disabled by oif:`) | `/etc/fstab` restored from its backup, swap on |
| `/etc/containerd/config.toml`: systemd cgroups, data in `<INSTALL_DIR>/containerd` | Containers stopped, mounts detached, file and data deleted |
| `/etc/modprobe.d/90-oif-nouveau.conf` (nouveau blocked) | Deleted, boot image rebuilt |
| `/etc/modprobe.d/90-oif-vfio.conf`, `/etc/modules-load.d/90-oif-vfio.conf` | Deleted, boot image rebuilt |
| `/etc/systemd/system/oif-resume.service` (only until the install continues after the reboot) | Removed by the install itself |
| `/var/lib/oif` (settings, mode 600; record of changes) and `/var/log/oif-install.log` | Deleted |

Preview the uninstall at any time without changing anything: `sudo ./oif plan`.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `the saved settings are not valid on this host` | Run `sudo ./oif install --reconfigure`. It asks again only for the invalid values; saved passwords are kept. To change a valid value, set it in `.env` first. |
| `0000:xx:00.0 is not an NVIDIA GPU` | Give only addresses from the NVIDIA lines of the GPU table, or press Enter for all. |
| `is a compute GPU and AMD_GPUS (empty) means all of them` | To isolate an AMD compute GPU, list the AMD GPUs you do want in `AMD_GPUS`. |
| `still needed after the reboot ... not rebooting again` | The driver or `vfio-pci` did not take over. Check `lsmod \| grep -E 'nvidia\|nouveau'`, `journalctl -k \| grep -i nvidia` and `lspci -nnk -s <address>`. oif never reboots twice for the same reason. |
| `IOMMU is off` | Enable AMD-Vi (or VT-d on Intel) in the BIOS, or set `ISOLATE_GPUS=none`. |
| `has the same device id as a GPU to isolate` | `vfio-pci` binds by device id, so two cards of the same model cannot be split this way. Leave that card unisolated. |
| You answered `n` to the reboot question | Reboot when convenient with `sudo reboot`; the install continues by itself afterwards. |
