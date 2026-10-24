# Security

Security requirements from the start, not before release.

## Secrets

- Secrets (Hugging Face token, Run:ai admin password, Grafana admin password) are read from `.env` at install time and stored only as Kubernetes Secrets. `.env` is untracked.
- Scripts never echo secrets; logs are checked for token patterns in CI.
- The repository is public: no real IP addresses, host names, user names or tokens in tracked files. CI runs gitleaks on every push.

## Access

- Kubernetes API and admin kubeconfig: readable by root and the installing user only (mode 600).
- Run:ai: role-based access; the default admin password is changed at first login; projects grant only the users who need them.
- Grafana: admin password from `.env`; anonymous access off.
- Inference endpoint (v0.1): reachable only on the load-balancer address inside the lab network; no public exposure. Authentication at a gateway (API keys, rate limits) is planned for a later version and must exist before any exposure outside the lab.

## Supply chain

- Every image and chart pinned by version in `versions.env`; image digests recorded with benchmark results.
- Images come from the publishers' registries (nvcr.io, docker.io/rocm, quay.io, registry.k8s.io, ghcr.io) or are built from Containerfiles in this repo.
- Open-source Run:ai images and charts are public on NGC (`nvcr.io/nvidia/runai-oss`, `helm.ngc.nvidia.com/nvidia/runai-oss`); no NGC key is needed. The `runai-installer` binary is checked against the SHA-256 published with its GitHub release.
- TLS for Run:ai uses a private CA created on the host (`/var/lib/oif/pki`, root only); only its public certificate is handed out for browsers to trust.

## Host

- Every host change is recorded and reversible (`oif uninstall`).
- Passwordless sudo is added only for the installing user, only if needed by the Kubernetes tooling, and removed on uninstall.
- GPUs not given to Kubernetes are isolated with vfio so workloads cannot reach them.

## Workloads

- Model-serving pods run as non-root where the engine allows it, with read-only root filesystems where possible, and request only the GPU resource they need.
- Network policies limiting namespace-to-namespace traffic are planned for v0.2.

## Reporting

Report vulnerabilities privately to the maintainer, not in public issues.
