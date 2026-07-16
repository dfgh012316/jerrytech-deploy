# Postgres

Single-replica Postgres StatefulSet shared by in-cluster apps.
Not managed by ArgoCD — apply manually once per cluster.

## Deploy

1. Create the namespace and the `postgres-secrets` Secret (do NOT commit the password):

```sh
kubectl create namespace postgres
kubectl create secret generic postgres-secrets \
  --from-literal=postgres-password=<POSTGRES_PASSWORD> \
  -n postgres
```

2. Apply the StatefulSet and Services:

```sh
kubectl apply -f postgres.yaml
```

## Services

| Service | Type | Use |
|---------|------|-----|
| `postgres.postgres.svc:5432` | Headless ClusterIP | In-cluster access |
| `postgres-nodeport:30432` | NodePort | External access from the Pi host (e.g. `psql` from the LAN) |
