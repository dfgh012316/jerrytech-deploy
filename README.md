# jerrytech-deploy

Deployment repository for [jerrytech.me](https://jerrytech.me): a single-node k3s cluster on a Raspberry Pi, deployed **push-based** via an **in-cluster GitHub Actions self-hosted runner** + Helm.

> Previously ArgoCD (pull-based GitOps); migrated to a self-hosted runner (push-based) in 2026-07. See `docs/migration-argocd-to-self-hosted-runner.md`.

## Architecture

```
app repo push
  └─ CI: build & push image (GitHub-hosted)
       └─ repository_dispatch → this repo's "Deploy app" workflow
            ├─ job 1 (GitHub-hosted): bump apps/<app>/values.yaml image tag
            └─ job 2 (in-cluster self-hosted runner): helm upgrade --install
```

External traffic is routed through **Cloudflare Tunnel** (Zero Trust) — no LoadBalancer or Ingress controller.

## Repository Structure

```
.
├── apps/
│   ├── _registry.yaml            # app → namespace / release name map
│   ├── popofinder/values.yaml
│   └── slipkit/values.yaml
├── bootstrap/                    # cluster infra, applied manually (each has a README)
│   ├── actions-runner/           # in-cluster runner: image/ + chart/
│   ├── cloudflared/
│   ├── common-config/
│   └── postgres/
├── charts/app/                   # generic Helm chart for all services
├── scripts/
│   ├── deploy-app.sh             # helm upgrade wrapper (shared by local & CI)
│   └── adopt-helm-ownership.sh   # one-off: adopt existing resources into a release
└── .github/workflows/
    ├── deploy-app.yaml           # repository_dispatch + workflow_dispatch → deploy
    └── build-runner-image.yaml   # build the arm64 runner image → GHCR
```

## CI/CD Flow

1. App repo (popofinder/slipkit) CI builds & pushes an image tagged with the commit SHA.
2. CI generates a **GitHub App token** and sends a `repository_dispatch` (type `deploy-app`, payload `{app, tag}`) to this repo.
3. `deploy-app.yaml`:
   - **commit-tag** (GitHub-hosted): validate against the allowlist → bump `apps/<app>/values.yaml` image tag with the built-in `GITHUB_TOKEN` → commit & push.
   - **deploy** (in-cluster self-hosted runner): checkout that commit → `deploy-app.sh <app>` → `helm upgrade --install`.
4. Rollback = revert `values.yaml` and re-run deploy (or `helm rollback`).

## Key Design Decisions

| Decision | Reason |
|----------|--------|
| In-cluster self-hosted runner (custom chart) | Managed by Helm like everything else; returns with the cluster on Pi re-flash; no operator → short, debuggable path |
| `repository_dispatch` (not a reusable workflow) | A repo-level runner on a personal account is only visible to runs triggered *by this repo*; dispatch makes the deploy a run of *this* repo |
| Deploy commits with the built-in `GITHUB_TOKEN` | The deploy workflow runs in this repo's context — no PAT/App token needed |
| Cloudflare Tunnel instead of Ingress | No public IP on the cluster; Zero Trust handles access control |
| Generic Helm chart (`charts/app`) | One chart for all services; per-app diffs live in `apps/<app>/values.yaml` |
| Secrets via manual `kubectl create secret` | Never committed to git |

## Bootstrap

Applied manually (see per-component READMEs):
- [actions-runner](bootstrap/actions-runner/README.md) — in-cluster self-hosted runner
- [Cloudflare Tunnel](bootstrap/cloudflared/README.md)
- [common-config](bootstrap/common-config/README.md)
- [postgres](bootstrap/postgres/README.md)

## Day-2 Operations

- **Release**: app repo push → fully automatic.
- **Manual redeploy**: Actions → *Deploy app* → `workflow_dispatch` (app + tag).
- **Config-only change**: edit `apps/<app>/values.yaml`, then ssh to the Pi and run `scripts/deploy-app.sh <app>`, or use `workflow_dispatch`.
