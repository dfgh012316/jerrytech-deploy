# jerrytech-deploy

GitOps deployment repository for [jerrytech.me](https://jerrytech.me), managed by ArgoCD running on a Raspberry Pi Kubernetes cluster.

## Architecture

```
GitHub (source repo)
  └─ CI: build & push Docker image
       └─ triggers reusable workflow (update-image-tag)
            └─ commits new image tag → this repo
                 └─ ArgoCD detects diff → syncs cluster
```

External traffic is routed through **Cloudflare Tunnel** (Zero Trust), eliminating the need for an exposed LoadBalancer or Ingress controller.

## Repository Structure

```
.
├── apps/                    # Per-app Helm value overrides + ArgoCD Application CRDs
│   └── popofinder/
├── bootstrap/               # One-time cluster bootstrap manifests
│   ├── argocd/              # ArgoCD Helm values
│   └── cloudflared/         # Cloudflare Tunnel deployment
├── charts/
│   └── app/                 # Generic reusable Helm chart for all services
└── .github/workflows/
    └── update-image-tag.yaml  # Reusable workflow called by app repos
```

## CI/CD Flow

1. App repo pushes code → GitHub Actions builds and pushes a Docker image tagged with the commit SHA
2. App CI calls the reusable `update-image-tag` workflow defined in this repo
3. The workflow validates the caller repo against an allowlist, verifies the image exists on DockerHub, then commits the new tag to `apps/<app>/values.yaml` using a **GitHub App token** (no PAT)
4. ArgoCD detects the change and syncs the cluster automatically (auto-sync + self-heal enabled)

## Key Design Decisions

| Decision | Reason |
|----------|--------|
| ArgoCD `server.insecure: true` | TLS is terminated at the Cloudflare edge; traffic inside the cluster runs over plain HTTP intentionally |
| GitHub App token instead of PAT | Scoped to this repo only, not tied to a personal account |
| Cloudflare Tunnel instead of Ingress | No public IP required on the cluster; Zero Trust handles access control |
| Generic Helm chart (`charts/app`) | Single chart for all services; per-app differences live in `apps/<app>/values.yaml` |
| App of Apps pattern | Single ArgoCD root application manages all child applications automatically |

## Bootstrap

See per-component READMEs:
- [ArgoCD](bootstrap/argocd/)
- [Cloudflare Tunnel](bootstrap/cloudflared/README.md)
