# Lab acceptance tests

One script per task that needs real machines. Each prints `PASS` or `FAIL` per check and exits non-zero on any failure; a task is marked done in [TASKS.md](../../TASKS.md) only when its script passes. They run on the multi-node cluster built from the [hybrid-gpu-lab](https://github.com/manmohanbrahma/hybrid-gpu-lab) VMs (or any cluster with the same roles).

| Script | Task | Run on | After |
| --- | --- | --- | --- |
| `t120-nodes.sh [--reboot NODE]` | T-120 node list, cluster key, node runner | the first node, with sudo | `sudo ./oif install --until nodes` (or a full install) |

What each checks:

- **t120-nodes.sh**: several nodes in the settings and this host first; the cluster key exists and is root-only; for every other node: reachable with the cluster key alone (no agent) and sudo without a password, recorded for uninstall, oif copied, all nine node stages done, only the node settings sent (no passwords or tokens), its own change record; on NVIDIA nodes the driver loaded and nouveau blocked. `--reboot NODE` reboots that node the way the node runner does and requires it back within 15 minutes.

Unit tests that need no machines are in `tests/unit` (`tests/run.sh`); the read-only clean-host check after an uninstall is `tests/host/verify-clean.sh`.
