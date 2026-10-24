# 5. Run:ai open source

**Step:** T-105 (and spike S-3). **Tested:** 2026-10-24, Run:ai 3.0.20 on the reference host.

The full guide, with 39 figures from the real installation, is published as two pages:

- [Single-Node Run:ai Installation Guide](https://manmohanbrahma.github.io/ai/runai/install-guide/): every command and its output, browser access, a tour of the Run:ai UI, the quota test, troubleshooting, uninstall.
- [Single-Node Run:ai Deployment Guide](https://manmohanbrahma.github.io/ai/runai/deployment-guide/): architecture, versions, sizing, network and DNS, TLS, security, decisions, known issues.

## In short

```bash
cd ~/open-inference-fabric
sudo ./oif install        # runs stages prometheus, ingress, pki, runai-dns, runai, runai-fractions, runai-verify, runai-quota
```

| Stage | Result on the reference host |
| --- | --- |
| prometheus | kube-prometheus-stack 92.3.0 in namespace monitoring |
| ingress | HAProxy ingress (class haproxy) on the first MetalLB address |
| pki | private CA and certificate for `runai.<lb-ip>.sslip.io` and its wildcards; CA copied to `~/oif-ca.crt` |
| runai-dns | CoreDNS answers the Run:ai domain with the ingress address |
| runai | runai-installer 3.0.20: preflight 9/9, control plane and cluster `oif` registered |
| runai-fractions | fractioning daemons kept off the GPU node (driver 595 is older than r615) |
| runai-verify | all Run:ai pods running; UI answers over HTTPS trusted by the oif CA |
| runai-quota | team-a (1 GPU) runs on the GPU; team-b (0 GPU) waits on a free GPU: `NonPreemptibleOverQuota` |

Administrator login (root only):

```bash
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n runai-backend get configmap runai-backend-tenants-manager -o jsonpath='{.data.ADMIN_USERNAME}'; echo
sudo kubectl --kubeconfig /etc/kubernetes/admin.conf -n runai-backend get secret runai-backend-gen-tenants-manager -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d; echo
```
