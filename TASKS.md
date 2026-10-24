# Tasks

Work through tasks in order: understand, plan, implement, test, review, commit, update docs. Each phase ends with a working vertical slice.

Status: `[ ]` open, `[~]` in progress, `[x]` done, `[-]` dropped.

## Phase 0: Project

- [x] T-001 Research, PRD, architecture, design, rules, decisions, test plan, security, tasks
- [ ] T-002 Public GitHub repository, licence, README; push
- [ ] T-003 CI: shellcheck, yamllint, markdown link check, secret scan (gitleaks) on every push

## Phase 1: Spikes (prove the risky parts before building around them)

Each spike has exit criteria. A spike that fails stops the plan at a decision gate for the owner.

- [ ] S-1 **Dynamo on ROCm (W7900).** Build an image from a ROCm vLLM base plus the Dynamo runtime (no NIXL, no KVBM); run `dynamo.frontend` and `dynamo.vllm` with file discovery in podman on the W7900.
  Exit: the worker registers, `/v1/chat/completions` answers (streaming and non-streaming), and 10 minutes of AIPerf at concurrency 8 complete without errors.
- [ ] S-2 **KAI quotas for AMD.** On a throw-away Kind or kubeadm cluster, install KAI Scheduler; create a queue with quota 1 for `amd.com/gpu` and for `nvidia.com/gpu`; submit 2 pods per vendor.
  Exit: one pod per vendor runs and the second stays pending with a quota reason.
- [ ] S-3 **Run:ai open source on single-node kubeadm 1.35.** Install the control plane and cluster from the NGC Community chart or `runai-installer`.
  Exit: UI and API reachable, cluster connected, a project with a GPU quota created; footprint (CPU, memory, pods) recorded.
- [ ] S-4 **Dynamo operator with KAI.** Deploy a DynamoGraphDeployment whose pods are scheduled by KAI under a Run:ai project.
  Exit: pods carry the queue, quota is enforced, the graph serves requests.

## Phase 2: Base platform (slice: empty host to GPU-ready Kubernetes)

- [ ] T-010 `oif` skeleton: verbs, logging, prompts, state, manifest helpers, `versions.env` (reuse the proven helpers from the lab installers)
- [ ] T-011 Host preparation: packages, swap, sysctls, containerd, NVIDIA driver from the Ubuntu archive, vfio isolation of excluded GPUs
- [ ] T-012 kubeadm 1.35 single node, Calico, control-plane taint removed, maxPods
- [ ] T-013 local-path storage, MetalLB pool
- [ ] T-014 NVIDIA GPU Operator (host driver, toolkit, CDI, DCGM exporter)
- [ ] T-015 AMD GPU Operator (in-kernel driver, device plugin, labeller, metrics exporter, ECC threshold for kernel 7.0)
- [ ] T-016 `oif uninstall`, `status`, `plan`, `check`; test: install, re-run (no changes), uninstall, host back to OS default

## Phase 3: Observability (slice: see both GPUs in one dashboard)

- [ ] T-020 kube-prometheus-stack with persistent Grafana, scrape configs and ServiceMonitors for both exporters
- [ ] T-021 `oif:gpu_*` recording rules for both vendors; unit tests with `promtool test rules`
- [ ] T-022 Fleet dashboard (Grafana JSON in Git, provisioned)

## Phase 4: Orchestration (slice: quotas across vendors)

- [ ] T-030 Run:ai control plane and cluster (method chosen in S-3)
- [ ] T-031 Node pools `nvidia` and `amd`; project with quota; KAI and Run:ai metrics scraped
- [ ] T-032 Scheduling dashboard

## Phase 5: Serving (slices: NVIDIA end to end, then AMD end to end)

- [ ] T-040 Dynamo platform (operator, CRDs) pinned and installed
- [ ] T-041 NVIDIA slice: Qwen3-0.6B on the A6000 via DynamoGraphDeployment under the Run:ai project; chat completion through the frontend
- [ ] T-042 AMD image: `images/dynamo-vllm-rocm` from S-1, built and pushed to the in-cluster registry
- [ ] T-043 AMD slice: Qwen3-0.6B on the W7900 through the same frontend
- [ ] T-044 Serving metrics: ServiceMonitors for frontend and workers; Serving dashboard

## Phase 6: Performance (slice: one comparable report)

- [ ] T-050 AIPerf runner as a Kubernetes Job with profiles (concurrency sweep, fixed ISL/OSL); results to a PVC and the repo's `results/`
- [ ] T-051 `oif bench`: one GPU at a time, temperature guard, Grafana annotations for each run
- [ ] T-052 HTML comparison report generator (DESIGN.md rules)

## Phase 7: Release v0.1

- [ ] T-060 End-to-end test on the reference host from a clean OS (TEST_PLAN.md)
- [ ] T-061 Install guide with screenshots on the guides site
- [ ] T-062 Tag v0.1.0
