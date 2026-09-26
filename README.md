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
│   ├── chart-check.sh            # helm lint + template + kubeconform for every app (PR CI & local)
│   └── adopt-helm-ownership.sh   # one-off: adopt existing resources into a release
└── .github/workflows/
    ├── deploy-app.yaml           # repository_dispatch + workflow_dispatch → deploy
    ├── chart-ci.yaml             # PR gate: chart-check.sh + Chart.yaml version bump check
    ├── build-runner-image.yaml   # build the arm64 runner image → GHCR (push / manual / workflow_call)
    ├── runner-auto-update.yaml   # daily: bump actions-runner base image → build → restart the runner
    └── runner-selftest.yaml      # manual: runner tools / in-cluster kubectl & helm / RBAC check
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

## Security Model

This is a **public** repo whose workflows can deploy through a **self-hosted runner** inside the cluster. GitHub recommends self-hosted runners only for private repos, because whoever gets a job onto the runner inherits its access. This section explains what limits that exposure and which risks are still open.

**Who can get a job onto the runner**

| Path | Guard |
|------|-------|
| Existing workflows | Self-hosted jobs only run on `repository_dispatch`, `workflow_dispatch` and `schedule`. Both dispatch events require a token with write access to this repo (app repos send a GitHub App token); `schedule` always runs the default-branch version. |
| Fork pull requests | PR CI (`chart-ci.yaml`) runs on GitHub-hosted runners. A fork PR could still *add* a workflow targeting `[self-hosted, pi, k3s]`, so runs from **all** outside contributors need manual approval (fork PR approval policy: `all_external_contributors`). Rule: never approve a run for a fork PR that touches `.github/workflows/`. |
| Workflow inputs | `app` / `tag` from dispatch payloads and manual inputs go through `env:`, never expanded inside `run:`. `app` must be on the allowlist and `tag` must match the Docker tag grammar before anything uses them. |

**Other controls**

- Every workflow sets `permissions:` explicitly: read-only by default, `contents: write` only for the two GitHub-hosted jobs that push (`deploy-app` / `commit-tag` and `runner-auto-update` / `bump`), and `packages: write` only for the image build.
- `actions/checkout` runs with `persist-credentials: false`, so no token is left in the long-lived runner's `_work` directory. The two push jobs are the exception; they run on GitHub-hosted VMs that are thrown away after the job.
- Third-party actions are pinned to commit SHAs (version in a trailing comment). Dependabot proposes updates monthly with a 7-day cooldown; major versions come as separate PRs.
- Workflows are checked with [zizmor](https://github.com/zizmorcore/zizmor) (`uvx zizmor --offline .github`: no errors or warnings) and [actionlint](https://github.com/rhysd/actionlint).
- The cluster exposes no Service outside itself: every Service is `ClusterIP`, with no Ingress, NodePort or LoadBalancer. Web traffic and remote SSH come in through Cloudflare Tunnel. `ssh.jerrytech.me` sits behind a Cloudflare Access policy, and sshd accepts public keys only.
- Secrets are created out-of-band with `kubectl create secret` and never committed.

**Known residual risks** (accepted for a single-owner homelab)

- The runner is long-lived (not `--ephemeral`), and its ClusterRole grants `*` on pods, workloads and Secrets in every namespace. No Pod Security admission is enforced, so code running on the runner effectively has root on the node.
- The runner pod holds a PAT that can manage this repo's runners (classic `repo` scope or fine-grained *Administration: write*).
- No NetworkPolicy: every pod can reach every other pod, including PostgreSQL.

## Chart (`charts/app`)

- Values are validated by `charts/app/values.schema.json`; unknown keys fail at template time.
- `image.repository` / `image.tag` are required — no fallback to a chart appVersion.
- `charts/app` is also consumed by PaPiin as a **pinned OCI version** (`papiin-sre/charts`), so **bump `Chart.yaml` `version` whenever templates change**. `chart-ci.yaml` enforces this on PRs.
- Local check before pushing: `./scripts/chart-check.sh` (needs helm, mikefarah `yq`, `kubeconform`).

## Bootstrap

Applied manually (see per-component READMEs):
- [actions-runner](bootstrap/actions-runner/README.md) — in-cluster self-hosted runner
- [Cloudflare Tunnel](bootstrap/cloudflared/README.md)
- [common-config](bootstrap/common-config/README.md)
- [postgres](bootstrap/postgres/README.md)

## Day-2 Operations

- **Release**: app repo push → fully automatic.
- **Manual redeploy**: Actions → *Deploy app* → `workflow_dispatch` (app + tag).
- **Config-only change**: edit `apps/<app>/values.yaml`, push to `main`, then run *Deploy app* with the tag left empty (`gh workflow run deploy-app.yaml -f app=<app>`); helm re-applies the current values. Don't run `scripts/deploy-app.sh` from the Pi host: the checkout there is stale, while CI checks out the latest `main` on every run.
