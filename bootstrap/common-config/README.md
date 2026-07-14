# common-config

Cluster-wide config that points apps at the shared Postgres
([bootstrap/postgres](../postgres/)). Apps consume it via `envFrom.configMapRef`.

The ConfigMap has no `namespace` field, so it must be applied into each
namespace that needs it.

## Deploy

Apply once into every new app namespace:

```sh
kubectl apply -f common-config.yaml -n <app-namespace>
```

Existing namespaces (already deployed): `papiin-api`, `popo`, `slipkit`.

## Keys

| Key | Value |
|-----|-------|
| `DB_HOST` | `postgres.postgres.svc` |
| `DB_PORT` | `5432` |
