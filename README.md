# Open Inference Fabric

**One open-source platform to schedule, serve, benchmark and observe LLMs on NVIDIA and AMD GPUs.**

Open Inference Fabric (OIF) assembles NVIDIA's open-source AI infrastructure software into a suite you can install on a GPU server with one command:

| Layer | Built on |
| --- | --- |
| Orchestration | NVIDIA Run:ai (open source) with the KAI Scheduler: projects, quotas, node pools |
| Serving | NVIDIA Dynamo with vLLM (SGLang and TensorRT-LLM later), one OpenAI-compatible endpoint; AMD GPUs through a ROCm build |
| Performance | NVIDIA AIPerf benchmark profiles and comparison reports |
| Observability | Prometheus and Grafana with DCGM and AMD device metrics exporters, normalised into one vendor-neutral schema |
| Platform | Upstream Kubernetes (kubeadm), NVIDIA GPU Operator, AMD GPU Operator |

> **Status: v0.1 in development.** The `oif` command line and host check work; the platform stages are being added one step at a time. Start with the [install and deployment guides](docs/guides/README.md); progress is in [TASKS.md](TASKS.md).

## Why

Teams with both NVIDIA and AMD GPUs run separate stacks per vendor: different serving endpoints, different dashboards, no shared quotas, and benchmarks that cannot be compared. OIF puts both vendors behind one scheduler, one API, one benchmark tool and one set of dashboards.

## Usage

```bash
./oif check                                # read-only host and GPU report
cp .env.example .env && $EDITOR .env      # addresses, tokens
sudo ./oif install                         # questions first, then unattended
sudo ./oif status | plan                   # progress; preview of uninstall
sudo ./oif uninstall                       # back to the OS default
sudo ./oif bench --model qwen3-0.6b        # (Project 2) AIPerf sweep on each GPU, HTML report
```

## Documentation

| Document | Purpose |
| --- | --- |
| [PRD](docs/PRD.md) | What we are building and why; MVP and success criteria |
| [Architecture](docs/ARCHITECTURE.md) | Layers, flows, telemetry schema, repository layout |
| [Design](docs/DESIGN.md) | CLI, dashboard and report conventions |
| [Rules](docs/RULES.md) | How code is written and changed (people and AI assistants) |
| [Tasks](TASKS.md) | What we build next, in order |
| [Decisions](docs/DECISIONS.md) | Why each architectural choice was made |
| [Memory](docs/MEMORY.md) | Current project state |
| [Test plan](docs/TEST_PLAN.md) | What "working" means |
| [Install guides](docs/guides/README.md) | Step-by-step install and deployment, one guide per step |
| [Security](docs/SECURITY.md) | Security requirements |
| [Research](docs/RESEARCH.md) | Sources behind the decisions |

## Reference hardware

Developed and tested on one server: AMD EPYC 9684X, 751 GiB RAM, NVIDIA RTX A6000 and AMD Radeon PRO W7900, Ubuntu 26.04.

## Licence

Apache-2.0. NVIDIA, Run:ai, Dynamo, AMD, ROCm and Radeon are trademarks of their owners; this project is not affiliated with or endorsed by them.
