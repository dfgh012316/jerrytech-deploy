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

Existing namespaces (already deployed): `popo`, `slipkit`.

## Keys

| Key | Value |
|-----|-------|
| `DB_HOST` | `postgres.shared.svc` |
| `DB_PORT` | `5432` |

Changing this ConfigMap does not update existing Pod environments. Update any
`DB_HOST` or `DATABASE_URL` in app Secrets as well (Secret env values override
this ConfigMap), then restart the app workloads during the migration window.
