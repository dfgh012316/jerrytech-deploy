# Monitoring (not deployed)

Preserved Helm values for the monitoring stack — **currently not deployed**.
Kept here so the stack can be brought up later without re-deriving the config.

## What's here

| File | Upstream chart |
|------|----------------|
| `kube-prometheus-stack-values.yaml` | `prometheus-community/kube-prometheus-stack` (Grafana + Prometheus + node-exporter + kube-state-metrics) |
| `loki-values.yaml` | `grafana/loki` (SingleBinary mode, ARM64) |
| `promtail-values.yaml` | `grafana/promtail` (ARM64) |

Sized for a single Raspberry Pi node.

## Before redeploying — read this

1. **Grafana admin secret.** Values reference `existingSecret: grafana-admin-credentials`. Create it manually:

   ```sh
   kubectl create namespace monitoring
   kubectl create secret generic grafana-admin-credentials \
     --from-literal=admin-user=admin \
     --from-literal=admin-password=<PASSWORD> \
     -n monitoring
   ```

2. **Grafana Ingress is dead config.** `kube-prometheus-stack-values.yaml` still
   has an `ingress` block referencing `letsencrypt-wildcard` and
   `jerrytech-wildcard-tls`. cert-manager is no longer installed on this
   cluster and all external traffic now goes through Cloudflare Tunnel —
   when redeploying, either disable the ingress and add a Cloudflare Tunnel
   public hostname → `grafana.monitoring.svc:80`, or reintroduce cert-manager.

3. **Manual install for now** (no ArgoCD Application yet):

   ```sh
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo add grafana https://grafana.github.io/helm-charts
   helm repo update

   helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
     -n monitoring --create-namespace \
     -f kube-prometheus-stack-values.yaml

   helm upgrade --install loki grafana/loki \
     -n monitoring -f loki-values.yaml

   helm upgrade --install promtail grafana/promtail \
     -n monitoring -f promtail-values.yaml
   ```

   When this becomes a permanent part of the cluster, convert each into an
   ArgoCD `Application` under `apps/` pointing at the upstream chart with
   `helm.valueFiles` referencing these files.
