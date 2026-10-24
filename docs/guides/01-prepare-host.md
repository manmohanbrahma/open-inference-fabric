# 1. Prepare the host and run the check

**Step:** T-101 (the `oif` command line). **Tested:** 2026-10-24 on Ubuntu 26.04.1, kernel 7.0, RTX A6000 + Radeon PRO W7900.

## What you get

- The Open Inference Fabric code on the GPU server.
- A settings file (`.env`) with your addresses, folders and passwords.
- A read-only report that says whether the host is ready, and what `oif install` will change.

Nothing on the host changes in this guide.

## Before you start

- A server with Ubuntu 26.04 (22.04 and 24.04 are expected to work), at least 16 CPU threads, 64 GB memory and 150 GB free under `/var/lib`.
- At least one NVIDIA GPU of the Ampere generation or newer (Project 1.1). AMD GPUs are added in Project 1.2.
- A user with `sudo`. You log in over SSH as this user.
- Internet access to `registry.k8s.io`, `nvcr.io`, `ghcr.io`, `huggingface.co` and `archive.ubuntu.com`.
- For the network settings, a few free IP addresses on the server's subnet: MetalLB hands them to Run:ai, Grafana and the inference endpoint.

## Steps

### 1. Download the code

Git is not needed. Download the latest code as an archive into your home folder:

```bash
cd ~
wget -qO oif.tar.gz https://github.com/manmohanbrahma/open-inference-fabric/archive/refs/heads/main.tar.gz
tar -xzf oif.tar.gz && mv open-inference-fabric-main open-inference-fabric && rm oif.tar.gz
cd ~/open-inference-fabric
./oif version
```

Expected output:

```text
oif 0.1.0-dev
```

If you prefer Git: `git clone https://github.com/manmohanbrahma/open-inference-fabric.git`.

### 2. Run the host check

The check only reads; it does not need `sudo`.

```bash
./oif check
```

Example output from the reference host:

```text
Host
  OS        : Ubuntu 26.04.1 LTS, kernel 7.0.0-38-generic
  CPU       : AMD EPYC 9684X 96-Core Processor, 192 threads
  Memory    : 751 GB total, 742 GB available
  Swap      : /swap.img
  IOMMU     : on
  Secure Boot: SecureBoot disabled
  Largest filesystem: /shared_storage (9370 GB free); /var/lib: 410 GB free

GPUs
  0000:82:00.0 NVIDIA  GA102GL [RTX A6000]            nouveau   compute
  0000:c8:00.0 AMD     Navi 31 [Radeon Pro W7900]     amdgpu    compute
  0000:03:00.0 AMD     Navi 24 [Radeon PRO W6400]     amdgpu    display only (isolate)
  0000:ca:00.0 other   ASPEED Graphics Family         ast       ignored

Checks
  [ok] Ubuntu 26.04
  [ok] 192 CPU threads
  [ok] memory
  [ok] /var/lib: 410 GB free
  [ok] 1 NVIDIA GPU(s)
  [ok] 1 AMD compute GPU(s)
  [!] 0000:82:00.0 on nouveau: oif install replaces it with the NVIDIA driver (one reboot, asked first)
  [!] display-only AMD GPU(s) 0000:03:00.0: oif install isolates them with vfio so Kubernetes cannot claim them (one reboot)
  [!] swap is on: oif install turns it off for Kubernetes (uninstall turns it back on)
  [ok] reachable: https://registry.k8s.io
  [ok] reachable: https://nvcr.io
  [ok] reachable: https://ghcr.io
  [ok] reachable: https://huggingface.co
  [ok] reachable: https://archive.ubuntu.com

Host is ready for oif install.
```

How to read it:

| Line | Meaning |
| --- | --- |
| `compute` | A GPU that Kubernetes will use. |
| `display only (isolate)` | An AMD card that only drives a display. AMD's device plugin would hand every AMD GPU to Kubernetes, so `oif install` binds this card to `vfio-pci` instead. |
| `ignored` | Not an NVIDIA or AMD GPU, for example the server management controller's display chip. Never touched. |
| `[!] ... nouveau` | The open-source driver is loaded. `oif install` installs the NVIDIA driver from the Ubuntu archive and asks before the reboot. |
| `[!] swap is on` | Kubernetes needs swap off. `oif install` turns it off and `oif uninstall` turns it back on. |
| `[!] cannot reach ...` | Fix the proxy or firewall before installing. |

### 3. Write the settings file

```bash
cp .env.example .env
chmod 600 .env
nano .env
```

| Setting | What to enter | Example |
| --- | --- | --- |
| `HOST_IP` | The server's main IP address | `<host-ip>` |
| `METALLB_RANGE` | Free addresses on the same subnet, first-last | `<a.b.c.240>-<a.b.c.244>` |
| `INSTALL_DIR` | Data folder on a large disk; removed by uninstall | `/data/oif` |
| `NVIDIA_GPUS` | PCI addresses from the check, comma-separated; empty for all | empty |
| `AMD_GPUS` | Same for AMD, used from Project 1.2 | empty |
| `ISOLATE_GPUS` | AMD display cards to keep away from Kubernetes; `none` for none | `0000:03:00.0` |
| `RUNAI_ADMIN_EMAIL` | Run:ai administrator login | `admin@example.com` |
| `RUNAI_ADMIN_PASSWORD`, `GRAFANA_ADMIN_PASSWORD` | Your own passwords, 12 characters or more | |
| `NGC_API_KEY` | NVIDIA NGC key, for the Run:ai images and charts | |
| `HF_TOKEN` | Hugging Face token, only for gated models | empty |

Values may be quoted. The file is read as data, never run as a script. Anything left empty is asked during `oif install`; passwords are asked without showing them.

> Keep `.env` on the server only. It is listed in `.gitignore`, so it is never committed.

## Check it worked

```bash
./oif check        # all [ok], or warnings you understand
./oif help         # list of commands
```

## The commands

| Command | Changes the host? | What it does |
| --- | --- | --- |
| `./oif check` | No | Host and GPU report (this guide) |
| `sudo ./oif install` | Yes | Asks the missing settings, shows a summary, then runs as a background job; safe to run again |
| `sudo ./oif status` | No | Finished stages and recorded host changes |
| `sudo ./oif plan` | No | Preview of what uninstall would remove and keep |
| `sudo ./oif uninstall` | Yes | Reverses every recorded change; asks you to type `wipe` |

`oif install` saves the settings, creates the data folder and then runs the stages described in the next guides, starting with [host preparation](02-host-preparation.md).

## What changed on the host

Nothing. `oif check` only reads system files, `lspci` and the network. The downloaded code is in `~/open-inference-fabric`.

When you later run `sudo ./oif install`, oif keeps:

- settings in `/var/lib/oif/settings.conf` (mode 600, root only), because they include passwords;
- a record of every host change in `/var/lib/oif/manifest`;
- the install log in `/var/lib/oif/install.log`.

`oif uninstall` reverses exactly the recorded changes, removes only the packages oif installed, and deletes `/var/lib/oif`.

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `run with sudo` | Every command except `check`, `help` and `version` needs `sudo`. |
| `cannot reach https://...` | Set the proxy for the system (`/etc/environment`) or open the firewall, then run the check again. |
| `no NVIDIA GPU` | Check `lspci | grep -i nvidia`. The GPU may be bound to `vfio-pci` by an earlier setup. |
| `.env:<n>: not KEY=VALUE` | That line is not a setting. Comment it out with `#`. |
| `.env:<n>: quote values that contain spaces` | Put the value in quotes: `GRAFANA_ADMIN_PASSWORD='my pass phrase'`. |
