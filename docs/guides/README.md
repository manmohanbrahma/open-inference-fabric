# Install and deployment guides

One guide per step of the plan in [TASKS.md](../../TASKS.md). Each guide is written when its step is built and tested on the reference host, and updated whenever the step changes. Follow them in order.

| # | Guide | Step | Status |
| --- | --- | --- | --- |
| 1 | [Prepare the host and run the check](01-prepare-host.md) | T-101 | Tested |
| 2 | [Host preparation: NVIDIA driver, kernel settings, container runtime, GPU isolation](02-host-preparation.md) | T-102 | Tested |
| 3 | [Kubernetes, storage and load balancer](03-kubernetes.md) | T-103 | Tested |
| 4 | [NVIDIA GPU Operator](04-nvidia-gpu-operator.md) | T-104 | Tested |
| 5 | [Run:ai open source](05-runai.md) (published with screenshots: [Installation Guide](https://manmohanbrahma.github.io/ai/runai/install-guide/), [Deployment Guide](https://manmohanbrahma.github.io/ai/runai/deployment-guide/)) | T-105 | Tested |
| 6 | [AMD GPU Operator and Run:ai quotas on AMD GPUs](06-amd-gpu-operator.md) | T-111, S-2, T-113 | Tested |
| 7 | [Observability for NVIDIA and AMD GPUs](07-observability.md): recording rules, Fleet and Scheduling dashboards, Grafana | T-106, T-112, T-114 | Tested |
| 8 | [Run:ai patches and ROCm templates for AMD GPUs](08-runai-patches.md): Run:ai counts both vendors, AMD logo, node ready without fractions | T-115 | Tested |
| 9 | [Uninstall and reinstall](09-uninstall.md) | T-107 | Tested |
| 10 | [Multi-node hybrid cluster](10-multi-node.md): NVIDIA and AMD GPUs on separate nodes, HA control plane, Run:ai node pools per vendor | T-120 – T-123 | Tested (lab) |

Multi-node (P1.3) workflow decks live under [presentations/](../../presentations/) (T-120–T-122). Full multi-node install guides come with T-124.

Project 2 (Dynamo serving and benchmarks) and 3 (unified API and gateway) add their guides here as they are built.

## How each guide is laid out

1. **What you get**: the result of the step.
2. **Before you start**: what must already be done.
3. **Steps**: numbered commands to copy, each followed by the output you should see.
4. **Check it worked**: commands that prove the result.
5. **What changed on the host**: every change, and how uninstall reverses it.
6. **Troubleshooting**: known problems and fixes.

Addresses, host names and secrets in examples are placeholders such as `<host-ip>`.
