# Proposal 0001: OIF as a monthly distro with a catalog-driven selector

- **Date:** 2026-10-30
- **Status:** proposed by the owner, written up by Claude; for Grok (ADRs, PRD, ARCHITECTURE, TASKS) and ChatGPT (review)
- **Changes:** PRD scope, ARCHITECTURE layers, the project order in TASKS; amends ADR-005, extends ADR-001, ADR-013, ADR-017, ADR-019

## 1. Why

OIF today installs one stack: kubeadm, the NVIDIA and AMD GPU Operators, Run:ai with KAI, Prometheus and Grafana. The owner's direction is broader: an installer that lets an administrator choose every layer, released as a tested distribution every month, growing towards a full AI cloud ("AI Cloud Factory": portal, tenancy, metering, bare-metal and VM pools, observability and AI-SRE).

Nothing built so far is discarded. The current stages become the first adapters, and the T-120 to T-124 lab suites become the regression gate for the refactor.

## 2. Decisions taken by the owner

| # | Decision |
|---|----------|
| D1 | Building lab VMs stays in the separate hybrid-gpu-lab project. OIF starts from pre-provisioned machines reachable over SSH. |
| D2 | OS qualification follows each vendor's specification. If nodes do not match, OIF gives the customer that specification (a spec report); it never reinstalls an OS. |
| D3 | The proof of concept uses upstream (open-source) Kubernetes. |
| D4 | OIF publishes a distro release every month with the stack available and qualified at that time. |
| D5 | Two tracks. **Open:** OIF builds and qualifies a stack from open-source components. **Commercial:** OIF releases only qualified combinations, such as NKP + NAI + OS, OpenShift + Red Hat AI, or a mix of these that both vendors support. |
| D6 | The installer has a proper selector for every element of the stack. |
| D7 | Control plane: 1 or 3 nodes on the open track. Commercial blueprints follow the vendor's recommended footprint (for NKP, the Nutanix-recommended HCI cluster). |
| D8 | The API server is the interface through which users reach model endpoints. |
| D9 | A hybrid environment is a set of pool environments: NVIDIA, AMD, and later other accelerator families (for example Broadcom- or Marvell-built XPUs). |
| D10 | Run:ai is one package that can be deployed, not the core of OIF. |

## 3. Release model

A release (for example `2026.12`) is a signed catalog plus artifacts:

- **Bill of materials:** every component with version, source, checksum, licence type and status (`qualified`, `tested`, `preview`).
- **Constraints:** per component, what it `requires`, `conflicts` with and `provides` (for example: an operator requires a driver branch and a kernel range; a commercial platform requires the OS versions its vendor certifies).
- **Vendor specifications:** OS, kernel, CPU, memory, disk, BIOS and firmware settings, copied from each vendor's support matrix for that release.
- **Blueprints:** the qualified commercial combinations.
- **Offline bundle** for air-gapped sites, release notes, and a published compatibility matrix.

Monthly cycle:

1. Week 1: candidate catalog from new upstream versions (automated collection).
2. Weeks 2 to 3: qualification matrix on the reference lab: install, lab suites, serving smoke test, AIPerf baseline, uninstall, clean check.
3. Week 4: promote statuses, sign, publish.

Support window: the current release and the two before it; patch releases (`2026.12.1`) for security fixes.

"Qualified" always names the hardware it was run on. The reference lab has one NVIDIA and one AMD workstation GPU; claims for other hardware need access to it.

`versions.env` becomes the source the catalog is generated from. The installer installs a release's bill of materials and records it in a lockfile, so "latest" means "latest qualified in the chosen release", and installs stay reproducible and uninstallable.

## 4. Layer model

```
Users and applications
  -> API server + gateway: keys, model catalog, routing, budgets, metering
OIF core
  -> release catalog, selector, tenants/projects/quotas, oif:* telemetry, AIJob (ADR-019)
Scheduler adapter
  -> Run:ai + KAI | KAI | Kueue | Volcano | Kubernetes default with ResourceQuota
Pool environments
  -> NVIDIA | AMD | future: Intel Gaudi, cloud TPU/Trainium, Broadcom/Marvell XPUs
Kubernetes platform
  -> upstream kubeadm (proof of concept) | NKP blueprint | OpenShift blueprint
Nodes
  -> pre-provisioned OS, checked against the vendor specification
```

Every layer is an adapter with the same verbs: `detect`, `plan`, `install`, `verify`, `uninstall`, `status`. Every host change stays recorded in the node's manifest (ADR-017), so uninstall keeps working per node.

### 4.1 Pool environments

A pool environment is a set of nodes with one accelerator family and everything that family needs. Adding a family means writing one adapter that fills this contract; the layers above do not change.

| Part | NVIDIA | AMD | Other family |
|------|--------|-----|--------------|
| Node specification | vendor driver and OS matrix | vendor matrix | vendor matrix |
| Enablement | NVIDIA GPU Operator | AMD GPU Operator | vendor device plugin or DRA driver |
| Resource name | `nvidia.com/gpu` | `amd.com/gpu` | vendor's |
| Telemetry | DCGM -> `oif:*` rules | AMD exporter -> `oif:*` rules | vendor exporter -> `oif:*` rules |
| Engine builds | CUDA vLLM, SGLang, Dynamo | ROCm vLLM, SGLang | vendor serving runtime |
| Status | tested | tested | future |

Broadcom and Marvell build custom accelerators for hyperscalers; none is sold today as an on-premises card with a Kubernetes operator. OIF defines the contract now and qualifies such a family when hardware and software are available. Intel Gaudi (which has a Kubernetes operator) and cloud TPU or Trainium pools are nearer candidates.

### 4.2 Tenancy and schedulers

OIF owns the tenant -> project -> quota model, including quotas per pool environment. A scheduler adapter implements it. Run:ai with KAI is one adapter (with OIF's AMD patches, ADR-016, belonging to that adapter); KAI alone, Kueue, Volcano and the default scheduler with ResourceQuota are others. Today projects and quotas exist only inside Run:ai, so this is the largest new design item.

### 4.3 API server

One OpenAI-compatible interface (`https://api.<domain>/v1/...`) across all pool environments:

- identity and API keys, mapped to tenant and project;
- a model catalog: `/v1/models` lists what is served and on which pool environment;
- routing per model: pinned to a pool, preferred with fail-over, or split by weight;
- token budgets and usage metering per key, model and pool (the input to billing later).

The gateway chosen by spike S-6 is its data path.

## 5. The selector

### 5.1 Rules

1. **Dependency order.** Questions follow the dependency graph, so a choice only narrows later choices.
2. **No dead ends.** An option is enabled only if at least one complete valid stack still contains it (full look-ahead; the catalog is small enough).
3. **Every option shows** its status, the release's recommended default, and, when disabled, the reason (for example "needs Ubuntu 24.04; node cp2 runs 26.04").
4. **Facts beat questions.** What nodes can report (accelerators, OS, CPU, memory, NICs) is discovered and confirmed, not typed.
5. **Mutability is labelled:** fixed at install (Kubernetes platform, pod network, API endpoint), changeable later (control-plane growth when an API VIP was set, node pools), add or remove at any time (serving runtimes, routes).
6. **One selector, three front ends:** an interactive terminal wizard (`oif init`), an answers file for repeatable and CI installs (`oif init --answers oif.yaml`), and later a web UI in the portal.
7. **Secrets** (licences, pull secrets, passwords) are asked only when the chosen stack needs them, stored root-only, never written to the answers file.
8. **`oif plan`** shows resolved versions, the spec check of every node, what goes where, and for an existing cluster which layers would rerun.

### 5.2 Selectors in order (open track)

| # | Selector | Options | Notes |
|---|----------|---------|-------|
| 0 | Release | current and the two before | selects the catalog |
| 1 | Track | open, commercial blueprint | commercial goes to 5.3 |
| 2 | Install source | online, local mirror, offline bundle | air gap |
| 3 | Topology | 1 or 3 control-plane nodes; API VIP; "may grow to HA"; control-plane nodes dedicated or schedulable; platform placement (ADR-021) | an API VIP is set even for 1 node when growth is allowed (kubeadm needs it at init) |
| 4 | Nodes | discover on an administrator-given CIDR (opt-in) or enter a list; read-only probe; tick hosts; role; pool environment | probe: OS release, CPU, memory, disks, accelerators by PCI id, existing Kubernetes |
| 5 | OS check | the release's qualified OS list for the chosen stack, checked on every node | mismatch -> spec report |
| 6 | Container runtime | containerd | |
| 7 | Kubernetes | upstream kubeadm, release N or N-1 | only option in the proof of concept |
| 8 | Pod network | Calico (tested), Cilium | |
| 9 | Load balancer | MetalLB L2, MetalLB BGP, external | |
| 10 | Ingress / Gateway API | HAProxy (tested), Envoy Gateway | |
| 11 | Storage | local-path, Longhorn (ADR-021), external CSI (NFS, Ceph), RWX for models | Longhorn default with 3 control-plane nodes |
| 12 | Certificates and domain | private CA, cert-manager with ACME, own certificate; wildcard-DNS name or real domain | |
| 13 | Identity | Keycloak, external OIDC | shared by scheduler UI, Grafana, API server, portal |
| 14 | Pool environments | detected; per pool: driver branch, partitioning (MIG, time-slicing) | only families present are offered |
| 15 | Scheduler | Run:ai + KAI (tested), KAI, Kueue, Volcano, default | |
| 16 | Observability | kube-prometheus-stack with `oif:*`, retention; logs later | |
| 17 | Model storage | RWX volume, S3, Hugging Face mirror | |
| 18 | Serving runtimes (multi-select) | vLLM, SGLang, Dynamo + vLLM, Dynamo + SGLang | per pool; ROCm status from spikes S-1 and S-5 |
| 19 | API server and gateway | gateway from spike S-6; keys, catalog, budgets | |
| 20 | Benchmark | AIPerf on or off | |

### 5.3 Commercial track

The administrator picks a blueprint, then sets only its parameters (node counts, pools, domain, licences). Components cannot be swapped, because qualification covers the combination. Candidate blueprints: NKP + NAI on the OS NKP certifies; OpenShift + Red Hat AI on RHCOS; mixed combinations only when both vendors list them as supported and the lab has qualified them. OIF installs through each vendor's supported path only: no patches to commercial software, nothing licensed redistributed; the customer supplies bundles, licences and pull secrets.

## 6. Mapping to the AI Cloud Factory picture

| Factory layer | OIF |
|---------------|-----|
| Unified Kubernetes control plane | now: kubeadm HA; NKP and OpenShift blueprints next |
| Compute pools: AI platform pool | now: pool environments per vendor |
| Compute pools: bare metal (Metal3/Ironic), VMs (KubeVirt) | later; makes a pre-provisioned OS optional |
| Storage | Longhorn now; NVMe-oF, S3 later |
| Observability | `oif:*` schema now; AI-SRE later |
| Service portal, metering, billing, marketplace | later; builds on tenancy and API server usage |
| Edge security, network fabric (DPU, RoCE) | integrations, documented; needs hardware not in the lab |

## 7. Proposed ADRs

| ADR | Subject |
|-----|---------|
| 022 | Monthly release model, two tracks, support window |
| 023 | Release catalog, constraint selector, lockfile (versions.env becomes the catalog source) |
| 024 | Vendor-specification preflight and the customer spec report |
| 025 | Topology: 1 or 3 control-plane nodes on the open track; vendor footprint for blueprints |
| 026 | Node discovery (opt-in CIDR, read-only probe) and day-2 node add and remove |
| 027 | Commercial blueprint policy: supported install paths only, customer-supplied licences |
| 028 | Pool environments and the accelerator adapter contract |
| 029 | OIF owns tenants, projects and quotas; schedulers are adapters (amends ADR-005) |
| 030 | API server: one OpenAI-compatible interface across pool environments |

## 8. Proof-of-concept scope (first release, open track)

- kubeadm with 1 or 3 control-plane nodes; Ubuntu nodes checked against the vendor specification.
- NVIDIA and AMD pool environments.
- OIF projects and quotas with two scheduler adapters, Run:ai + KAI and Kueue, to prove Run:ai is optional.
- vLLM and SGLang on both pools.
- API server with keys, serving one model from both pools.
- Selector (wizard and answers file), discovery, `oif node add`.

Implementation note: the catalog as JSON and the selector in Python using only the standard library (present on every Ubuntu node); the existing bash stages stay as adapters behind it.

## 9. Proposed order

1. Finish T-124 (multi-node demonstration) and T-003 (CI); merge the T-124 pull request.
2. ADRs 022 to 030 and the PRD and ARCHITECTURE updates (Grok); review (ChatGPT); owner acceptance.
3. Refactor into adapters with no change in behaviour, gated by the lab suites.
4. Catalog, selector, lockfile, `oif plan`; discovery and `oif node add`.
5. OIF tenancy model; Kueue adapter beside Run:ai + KAI.
6. Serving runtimes per pool; API server and gateway (absorbs today's Projects 2 and 3).
7. First monthly release; then NKP + NAI and OpenShift + Red Hat AI blueprints.
8. Later: portal, metering and billing, Metal3 and KubeVirt pools, AI-SRE.

The monthly qualification depends on CI and on a lab that rebuilds reliably, so hybrid-gpu-lab fixes (GPU power management, graceful guest shutdown) move ahead of step 3.

## 10. Open questions

1. Which tenancy model does the portal need first: per-team projects only, or organisations containing teams?
2. Does the first release need an air-gapped (offline bundle) install, or is online enough?
3. Which commercial blueprint is qualified first: NKP + NAI or OpenShift + Red Hat AI?
