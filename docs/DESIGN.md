# Design

OIF has three user surfaces: the `oif` command line, Grafana dashboards, and benchmark reports. They should look and behave as one product.

## Command line

- One entry point, `oif <verb>`: `install`, `uninstall`, `status`, `plan`, `check`, `bench`, `report`, `logs`.
- Read-only verbs (`status`, `plan`, `check`, `report`) never change the host or the cluster.
- Every verb that changes something asks all its questions first, shows a summary, then runs unattended and is safe to re-run (finished stages are skipped).
- Output style, same as the lab installers:
  - stage headers `== stage: <name>` with a timestamp;
  - `[ok]` in green for a finished step, `[!]` in yellow for a warning, `ERROR:` in red with the reason and the command to inspect;
  - long jobs run as a systemd unit and print how to follow them.
- Exit codes: 0 success, 1 failure, 2 usage error.

## Dashboards (Grafana)

Three dashboards, all built only on the vendor-neutral `oif:*` series (see ARCHITECTURE.md):

| Dashboard | Rows |
| --- | --- |
| Fleet | One row per GPU: utilisation, memory used/total, power, temperature (edge and junction for AMD), clocks; node CPU and memory |
| Serving | Per model and GPU: requests/s, TTFT p50/p95, inter-token latency p50/p95, output tokens/s, KV cache usage, in-flight requests, errors |
| Scheduling | Per Run:ai project / KAI queue: GPUs allocated vs quota, pending workloads, time to schedule |

Conventions:

- Vendor colours used consistently: NVIDIA `#76B900`, AMD `#ED1C24`; everything else in neutral greys.
- Units always shown: %, GiB, W, °C, ms, tokens/s.
- Time range defaults to the last 1 hour, refresh 30 s; benchmark runs are annotated on every dashboard.
- Variables: `vendor`, `node`, `gpu`, `model`.
- Every panel must show data on the reference host or display "no data" with a link to the exporter's troubleshooting note; no silently empty panels.

## Benchmark reports

- One self-contained HTML file per run set plus the raw AIPerf JSON.
- Header: date, host summary, GPU models, driver and engine versions, image digests, exact AIPerf command.
- Charts: throughput vs concurrency, TTFT and ITL percentiles vs concurrency, one line per GPU in the vendor colours.
- Tables follow the charts with the numbers; no number appears only in a chart.
- Light and dark themes; readable on a phone.

## Documentation

- Guides published alongside the other lab guides, in the same "runbook" style: numbered steps, copy buttons, checklists, screenshots of real runs with addresses replaced by placeholders.
