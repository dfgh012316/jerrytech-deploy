# Postgres

Single-replica PostgreSQL 18 StatefulSet in the `shared` namespace, shared by in-cluster apps.
Not part of the deploy pipeline — apply manually once per cluster.

`shared` groups services consumed by multiple apps. Each service keeps its own
workload, credentials and storage; app workloads remain in their own namespaces.
Redis and RabbitMQ are not deployed until needed.

## Deploy

1. Create the namespace and the `postgres-secrets` Secret (do NOT commit the password):

```sh
kubectl create namespace shared
kubectl create secret generic postgres-secrets \
  --from-literal=postgres-password=<POSTGRES_PASSWORD> \
  -n shared
```

2. Apply the StatefulSet and Services:

```sh
kubectl apply -f postgres.yaml
kubectl rollout status statefulset/postgres -n shared
```

## Services

| Service | Type | Use |
|---------|------|-----|
| `postgres.shared.svc:5432` | Headless ClusterIP | In-cluster access |

There is no NodePort. For operator access, use `kubectl exec` or an explicit
`kubectl port-forward -n shared svc/postgres 5432:5432`.

## Storage and upgrades

- Image: `postgres:18.6-bookworm` (ARM64 supported).
- PostgreSQL 18 uses `/var/lib/postgresql/18/docker` for `PGDATA`; mount the PVC
  at `/var/lib/postgresql`, not the pre-18 `/var/lib/postgresql/data` path.
- `pg-data-postgres-0` uses `local-path` storage. The requested 5Gi is not a
  reservation of physical disk space or an enforced capacity limit. The installed
  provisioner's setup script creates a directory without a quota. PG18 used about
  72MiB after migration, not 5GiB. Changing the request to 1Gi would not reclaim
  disk space; existing PVCs cannot be shrunk in place. Monitor actual directory
  usage and free space on the Pi instead. See the
  [local-path limitations](https://github.com/rancher/local-path-provisioner#cons)
  and [Kubernetes volume resizing](https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims).
- After provisioning, set the bound PV's reclaim policy to `Retain`:

  ```sh
  pv=$(kubectl get pvc pg-data-postgres-0 -n shared -o jsonpath='{.spec.volumeName}')
  kubectl patch pv "$pv" --type=merge -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
  ```

  Keep PVCs when retiring a StatefulSet. `Retain` is not a backup; keep a
  recoverable backup outside the Pi as well.
- A major-version upgrade requires dump/restore or `pg_upgrade`. Never start
  PG18 on a PG15 data directory. See [the migration runbook](../../docs/postgres18-migration.md).
