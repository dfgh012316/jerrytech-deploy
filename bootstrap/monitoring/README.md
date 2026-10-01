# Monitoring

| File | Upstream chart | Status |
|------|----------------|--------|
| `prometheus-values.yaml` | `prometheus-community/prometheus` 29.35.0 (Prometheus + node-exporter) | Minimal metrics history for the Pi — install manually (below) |
| `kube-prometheus-stack-values.yaml` | `prometheus-community/kube-prometheus-stack` (Grafana + Prometheus + node-exporter + kube-state-metrics) | Preserved, not deployed |
| `loki-values.yaml` | `grafana/loki` (SingleBinary mode, ARM64) | Preserved, not deployed |
| `promtail-values.yaml` | `grafana/promtail` (ARM64) | Preserved, not deployed |

## Prometheus (minimal)

Keeps metric history so before/after comparisons (e.g. memory across a k3s
upgrade) don't depend on whatever `kubectl top` shows right now. No Grafana,
Alertmanager or Ingress; nothing is exposed outside the cluster.

Scrapes every 1m, keeps 30d, capped at 2GB on disk (SD card):

| Job | Source | Use |
|-----|--------|-----|
| `kubelet-resource` | kubelet `/metrics/resource` | Same data as metrics-server: `node_memory_working_set_bytes` is `kubectl top node` |
| `kubernetes-nodes-cadvisor` | kubelet `/metrics/cadvisor` | Per-cgroup memory/CPU for `/`, `/system.slice/k3s.service` and each pod/container |
| `node-exporter` | DaemonSet | Host `/proc/meminfo`, vmstat, filesystem, thermal |

kubelet `/metrics` (~31k series) and annotation-based pod/service discovery are
disabled. node-exporter runs without `hostNetwork`, so it doesn't listen on the
Pi's LAN/IPv6 addresses; its network interface metrics describe the pod, not `wlan0`.

Install / upgrade (on the Pi: as root with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`):

```sh
helm upgrade --install prometheus oci://ghcr.io/prometheus-community/charts/prometheus \
  --version 29.35.0 -n monitoring --create-namespace \
  -f prometheus-values.yaml --wait
```

Query through the API server proxy (no port-forward needed):

```sh
kubectl get --raw '/api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query?query=node_memory_working_set_bytes'
```

Web UI: `kubectl -n monitoring port-forward svc/prometheus-server 9090:80`.

## Full stack (preserved, not deployed)

Kept so the stack can be brought up later (e.g. on a cluster that needs
dashboards and logs) without re-deriving the config. Sized for a single
Raspberry Pi node. It brings its own Prometheus and node-exporter, so don't
install it alongside the minimal Prometheus above.

### Before redeploying — read this

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

3. **Manual install for now** (not automated):

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

   When this becomes a permanent part of the cluster, wire it into the deploy
   pipeline — e.g. a dedicated `workflow_dispatch` target that runs these
   `helm upgrade --install` commands on the in-cluster runner.
