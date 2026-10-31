# T-124 — Platform High Availability Across Control-Plane Nodes

**Status:** Done (2026-10-31)  
**Repo:** [manmohanbrahma/open-inference-fabric](https://github.com/manmohanbrahma/open-inference-fabric)  
**Related:** ADR-021 · ADR-022 (amends ADR-021) · `tests/lab/t124-ha.sh` · `tests/lab/t124-probe.py` · Guide 10 (HA section) · T-121 (HA Kubernetes)

---

## 1. What T-124 delivers

| Capability | Description |
|------------|-------------|
| **Platform on control-plane nodes** | Run:ai, monitoring, ingress and MetalLB controller are required to run on nodes labelled `node-role.kubernetes.io/runai-system=true` (the control-plane nodes). GPU workers run workloads only. |
| **Redundant copies (3+ CP nodes)** | Everything users touch runs in copies on different control-plane nodes: Run:ai control plane & cluster services (2), Keycloak (3), Thanos query/receive (2/3), NATS (3), Prometheus (2), Alertmanager (3), Grafana (2). Losing one node needs no operator action. |
| **Database HA** | CloudNativePG cluster of three PostgreSQL 16 instances (one per control-plane node) with automatic failover. Run:ai backend, Keycloak and Grafana state use it. |
| **Fast recovery** | Silent node declared down after 20 s. `oif-conntrack-reaper` on every node drops stale connections so clients reconnect immediately. Ingress address announced only from control-plane nodes. |
| **Data placement** | Self-replicating components keep data on local-path (one volume per copy). Longhorn used only for components without their own copies (NATS). |
| **Clean uninstall** | Uninstall across all five nodes leaves every node clean; reinstall works without `lab recreate`. |

Single-copy operators (by design) and clusters with fewer than three control-plane nodes keep the ADR-021 single-copy model.

---

## 2. Architecture

```
┌─────────┐  ┌─────────┐  ┌─────────┐
│   cp1   │  │   cp2   │  │   cp3   │   ← Control plane (system nodes)
│ etcd/API │  │ etcd/API │  │ etcd/API │      Run:ai ×2, Keycloak ×3,
│ kube-vip│  │ kube-vip│  │ kube-vip│      CNPG PostgreSQL ×3,
│ platform│  │ platform│  │ platform│      Prometheus ×2, Grafana ×2 …
└────┬────┘  └────┬────┘  └────┬────┘
     │            │            │
     └────────────┼────────────┘
                  │
           OIF_API_VIP + MetalLB ingress
                  │
     ┌────────────┼────────────┐
     │            │            │
┌────▼────┐  ┌────▼────┐
│ gpu-amd │  │gpu-nvidia│   ← Workers (workloads only)
│  W7900  │  │  A6000   │
└─────────┘  └─────────┘
```

- **System nodes** — control-plane nodes labelled and selected for all platform Deployments/StatefulSets.
- **Database** — CloudNativePG promotes a standby automatically after the 20 s node-down verdict.
- **Connections** — `oif-conntrack-reaper` (host service on every node) clears conntrack entries for gone endpoints so clients reconnect at once.
- **Ingress** — MetalLB addresses announced only from control-plane nodes (exclude-from-external-load-balancers removed on platform nodes).
- **Detection** — `node-monitor-grace-period=20s`, node lease 16 s (renewed every 4 s).

---

## 3. Workflow steps

Admin runs `sudo ./oif install` on the first control-plane node (cp1) with three or more control-plane nodes listed in `OIF_NODES`.

| Step | Action |
|------|--------|
| **01 System nodes** | Label control-plane nodes `node-role.kubernetes.io/runai-system=true`. Platform components (Run:ai installer systemNodes + affinity, monitoring, ingress, MetalLB controller) require it. |
| **02 Storage** | Longhorn 1.12.1 on control-plane nodes (one copy each, at most three) for components without their own replication. local-path for self-replicating data and workloads. |
| **03 Database** | Stage `platform-db`: CloudNativePG operator + cluster of three PostgreSQL 16 instances, one per control-plane node. Run:ai and Keycloak pointed at the external database. |
| **04 Replicas** | Run:ai control plane / cluster services / KAI set to 2 with required anti-affinity; Keycloak ≥3; Thanos receive 3 (RF=3); NATS 3; Prometheus 2; Alertmanager 3; Grafana 2. |
| **05 Fast path** | Install `oif-conntrack-reaper` on every node. Remove load-balancer exclusion from control-plane nodes. Set node-monitor-grace-period to 20 s. |
| **06 Verify** | Full install, then power off a control-plane node that holds the database primary and the ingress address. Probe from inside and outside. |

Single-node and one-control-plane clusters keep the simpler single-copy + local-path model.

---

## 4. Key source files

| Path | Role |
|------|------|
| `installer/stages/*` (system-nodes, longhorn, platform-db, runai, monitoring …) | Placement, replica counts, CloudNativePG, affinity, conntrack reaper |
| `installer/lib/60-nodes.sh` | Node stages, uninstall of reaper, Longhorn cleanup |
| `tests/lab/t124-ha.sh` | Inside-cluster acceptance: 23 checks (API, etcd, DB failover, workloads in both pools, quotas, dashboards, outage ≤90 s, recovery) |
| `tests/lab/t124-probe.py` | Outside probe: real Run:ai login + API call, Grafana, UI every 5 s |
| `docs/DECISIONS.md` → ADR-021, ADR-022 | Design rationale and amendments (max_connections, reaper, MetalLB, 20 s detection, wal_keep_size) |
| `docs/guides/10-multi-node.md` | Full multi-node guide including the HA demonstration section |
| `docs/evidence/T-124/` | Lab outputs, probe logs, uninstall verification |

---

## 5. Verification

### Inside the cluster (`tests/lab/t124-ha.sh`)

Run on another control-plane node after a full multi-node install:

```bash
sudo tests/lab/t124-ha.sh cp2
```

Power the named node off when prompted (lab: `virsh destroy hl-cp2`), on again when prompted.

**Lab result (2026-10-31, run 7, cp2 held database primary + ingress address):** 23 checks PASS.

```text
        power cp2 off now …
        cp2 is down (NotReady)
        every replicated platform service serving 42 s after NotReady
        database primary now oif-pg-1, 2 instance(s) ready
  PASS  Run:ai API: log in and keep project team-c (quota 1 GPU per vendor pool)
  PASS  NVIDIA workload runs in pool nvidia (gpu-nvidia)
  PASS  AMD workload runs in pool amd (gpu-amd)
  PASS  a third workload (second NVIDIA) waits: quota 1 in pool nvidia
        longest outage seen by users: Run:ai UI 0 s, Grafana 47 s, Kubernetes API 0 s (limit 90 s)
  PASS  cp2 Ready again
  PASS  database back to all its instances
T-124: PASS (23 checks)
```

### Outside the cluster (`tests/lab/t124-probe.py`)

On a machine that reaches the ingress address (lab host), with the oif CA and credentials:

```bash
OIF_CA=oif-ca.crt python3 tests/lab/t124-probe.py --seconds 1500
```

**Same run:** UI 0 s, login with API call 67 s, Grafana 47 s (limit 90 s); no relapse.

Regression: T-120 (74), T-121 (11), T-122 (20), T-123 (27) pass. Uninstall across all five nodes clean (verify-clean); reinstall without lab recreate.

---

## 6. Summary

| | |
|---|---|
| **Outcome** | Platform survives loss of any one control-plane node with ≤90 s outage for users; workloads, quotas and dashboards continue; node returns cleanly |
| **Mechanism** | Redundant copies on system nodes + CloudNativePG automatic failover + conntrack reaper + 20 s node detection + MetalLB on platform nodes |
| **Data** | Self-replicating components on local-path; Longhorn only for NATS |
| **Proof** | `tests/lab/t124-ha.sh` (23 checks) + outside probe on hybrid-gpu-lab (2026-10-31) |
| **Guide** | [Guide 10 — Multi-node hybrid cluster](../docs/guides/10-multi-node.md) (HA section) |
| **Next** | P1.4 Topology & Intent (T-130 …) |

---

*Generated for the open-inference-fabric presentations set. Keep in sync with TASKS.md and the installer modules.*
