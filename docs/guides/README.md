# Install and deployment guides

One guide per step of the plan in [TASKS.md](../../TASKS.md). Each guide is written when its step is built and tested on the reference host, and updated whenever the step changes. Follow them in order.

| # | Guide | Step | Status |
| --- | --- | --- | --- |
| 1 | [Prepare the host and run the check](01-prepare-host.md) | T-101 | Tested |
| 2 | [Host preparation: NVIDIA driver, kernel settings, container runtime, GPU isolation](02-host-preparation.md) | T-102 | Tested |
| 3 | [Kubernetes, storage and load balancer](03-kubernetes.md) | T-103 | Tested |
| 4 | [NVIDIA GPU Operator](04-nvidia-gpu-operator.md) | T-104 | Tested |
| 5 | Run:ai open source | T-105 | Planned |
| 6 | Observability for NVIDIA | T-106 | Planned |
| 7 | Uninstall | T-107 | Planned |

Projects 1.2 (AMD GPUs), 2 (Dynamo serving and benchmarks) and 3 (unified API and gateway) add their guides here as they are built.

## How each guide is laid out

1. **What you get**: the result of the step.
2. **Before you start**: what must already be done.
3. **Steps**: numbered commands to copy, each followed by the output you should see.
4. **Check it worked**: commands that prove the result.
5. **What changed on the host**: every change, and how uninstall reverses it.
6. **Troubleshooting**: known problems and fixes.

Addresses, host names and secrets in examples are placeholders such as `<host-ip>`.
