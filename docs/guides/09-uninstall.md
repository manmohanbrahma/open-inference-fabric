# 9. Uninstall and reinstall

**Step:** T-107. **Tested:** 2026-10-25 on the reference host (uninstall, clean check, reinstall from the GitHub tarball; a second uninstall left the host clean). Multi-node uninstall walks every node recorded by the first control-plane (ADR-017).

## What you get

- The host (or every node of a multi-node cluster) returned to its OS default: packages oif installed are purged, kernel and network settings removed, drivers and isolation undone, Kubernetes and data folders gone.
- A clean check you can run without sudo for most traces.
- The same machine ready for a fresh `oif install`.

## Before you start

- An install that finished at least once (`sudo ./oif status` shows stages and recorded changes).
- For multi-node: run uninstall only on the first control-plane node; it reaches the others with the cluster key.

## Steps

### 1. Preview (read-only)

```bash
sudo ./oif plan
```

Lists every recorded change newest first (files, services, teardowns, other nodes, packages). Nothing is modified.

### 2. Uninstall

```bash
sudo ./oif uninstall
```

Type `wipe` to confirm. Answer whether to reboot when done (recommended so removed drivers unload and network rules clear).

Uninstall runs as a background systemd job so a dropped SSH session does not stop it:

```bash
sudo tail -f /var/log/oif-uninstall.log
```

What it does (from the manifest, newest first):

1. Registered teardowns (Kubernetes, operators, Run:ai, observability, …).
2. Stop/disable services, remove oif config blocks and lines, restore backups, re-enable swap.
3. On multi-node: `NODE` records trigger uninstall on each other node; `NODEKEY` / `ADMINKEY` remove keys oif added.
4. Safe purge of packages oif installed (never packages the OS already had).
5. Delete the state folder and install log; optional reboot.

### 3. Check the host is clean

```bash
./tests/host/verify-clean.sh
# or with the data folder path from .env:
./tests/host/verify-clean.sh /path/to/data
```

Exit 0 means no oif traces. A few modules (for example `br_netfilter`, `vfio_pci`) may stay loaded until reboot; the script reports those as info.

### 4. Reinstall (optional)

From a clean OS (or after verify-clean):

```bash
# same tree, or a fresh tarball from GitHub
sudo ./oif install
```

Saved settings are gone after uninstall; answer the questions again (or restore `.env`).

## Check it worked

| Check | Expected |
| --- | --- |
| `sudo ./oif status` | Nothing installed / no state |
| `./tests/host/verify-clean.sh` | `Host is clean: no oif traces.` |
| `dpkg -l \| grep -E 'kubelet\|containerd\|nvidia-'` | No oif-installed packages (or only OS-preexisting tools) |
| Multi-node other hosts | Same clean check after uninstall from cp1 |

## What changed on the host

Everything that install recorded is reversed. Typical categories:

| Kind | Action |
| --- | --- |
| `TEARDOWN` | Component-specific cleanup (cluster, operators, …) |
| `SERVICE` / `ENABLED` | Stop and disable |
| `BLOCK` / `LINE` / `RESTORE` | Remove oif edits or restore backups |
| `SWAP` | Re-enable swap from fstab |
| `FILE` / `DIR` / `DATADIR` | Delete (data folder only if no mount remains under it) |
| `NODE` | Uninstall that node via its own record |
| `NODEKEY` / `ADMINKEY` | Remove authorized_keys lines oif added |
| `PKG` | Purged in safe_purge |
| State | `/var/lib/oif` and `/var/log/oif-install.log` removed |

## Troubleshooting

| Problem | Fix |
| --- | --- |
| `Nothing recorded` | No prior successful install on this host; nothing to do. |
| Uninstall job stuck | `sudo journalctl -u oif-uninstall -f`; check `/var/log/oif-uninstall.log`. |
| `data folder still has a mount under it` | Unmount leftover volumes, then re-run uninstall or remove the folder by hand. |
| Other node unreachable | Fix SSH with the cluster key, or remove the oif-cluster line from that node's `authorized_keys` and clean it manually. |
| Traces left after verify-clean | Reboot, then run verify-clean again; NVIDIA/vfio may need the reboot to fully release. |
| Second uninstall needed fixes | Fixed on the reference host (commits noted in TASKS.md T-107); re-run from current main. |

## Related

- `installer/lib/90-uninstall.sh` — status, plan, uninstall, manifest replay
- `tests/host/verify-clean.sh` — T-107 acceptance
- Multi-node: `installer/lib/60-nodes.sh` (node uninstall walker), presentations T-120–T-122
