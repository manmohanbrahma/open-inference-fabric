# Test Plan

What "working" means for v0.1, layer by layer. Every check is automated in `tests/` unless marked manual.

## Static checks (every commit, CI)

- `shellcheck` on all shell scripts; `yamllint` on manifests and values; `promtool check rules` and `promtool test rules`; Grafana dashboards are valid JSON and use only `oif:*` series; markdown links resolve; gitleaks finds no secrets.

## Installer

- `oif check` on a clean host reports OS, CPU, memory, GPUs and drivers and writes nothing (no state folder afterwards).
- `oif install` completes; running it again reports every stage as done and changes nothing.
- Interrupting the install (kill the job) and re-running resumes at the failed stage.
- `oif uninstall` leaves no kubelet/containerd services, Kubernetes folders, mounts, CNI links, fstab entries, or packages the installer added; `oif status` then reports nothing installed.

## GPU enablement

- Node allocatable shows `nvidia.com/gpu: 1` and `amd.com/gpu: 1`.
- Node labels give each GPU's product name and memory.
- A test pod requesting each GPU sees exactly one device (`nvidia-smi -L`, `rocm-smi`); excluded GPUs (vfio) are never visible.

## Orchestration

- With a project quota of one GPU per vendor, the first pod per vendor runs and the second stays pending with a quota reason; deleting the first lets the second run.
- Workloads land only on the node pool of the GPU they request.

## Serving

- Chat completion through the single endpoint for each model name (NVIDIA and AMD), non-streaming and streaming.
- `/v1/models` lists both models.
- 64 concurrent requests per GPU complete without errors.
- Restarting a worker pod: the frontend stops routing to it and resumes when it is Ready.

## Performance

- `oif bench` runs the sweep (concurrency 1, 8, 32, 64) on each GPU, one GPU at a time, after the temperature guard.
- Zero failed requests; results include versions, image digests and the exact AIPerf command.
- Re-running the same profile gives output tokens/s within ±5 % (manual review of the first runs).

## Observability

- Every Fleet and Serving panel shows data during a benchmark on the reference host.
- `oif:gpu_*` series exist for both vendors with labels `vendor`, `model`, `gpu`, `node`.
- Benchmark runs appear as Grafana annotations.
- The AMD exporter does not mark the W7900 unhealthy on kernel 7.0 (ECC threshold applied).

## Responsive output (reports and docs)

- Benchmark report and guides render at 375 px, 768 px and 1440 px without horizontal scrolling.
