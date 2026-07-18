# actions-runner — in-cluster self-hosted runner

push-based deploy 的執行者：一個常駐在 k3s 的 GitHub Actions self-hosted runner，註冊到
`dfgh012316/jerrytech-deploy`，在收到 deploy 事件時對**本 cluster** 執行 `helm upgrade`。
取代 ArgoCD 的 pull-based 控制平面（見 `docs/migration-argocd-to-self-hosted-runner.md`）。

## 組成

- `image/` — 自訂 runner image：官方 `actions-runner` 疊加 `helm`/`kubectl`/`yq` + 自寫
  `entrypoint.sh`（用 PAT 換 registration token 自動註冊，SIGTERM 時反註冊）。
  由 `.github/workflows/build-runner-image.yaml` build 成 `ghcr.io/dfgh012316/jerrytech-runner`（arm64）。
- `chart/` — 部署 runner 的 helm chart：常駐 Deployment + ServiceAccount + ClusterRole/Binding。
- 認證：**PAT** 放在 out-of-band 建立的 k8s secret（值不進 git，慣例同其他 secret）。

## 首次部署

### 1. build runner image
push 到 `main` 動到 `image/**` 會自動觸發，或手動：
```bash
gh workflow run build-runner-image.yaml -R dfgh012316/jerrytech-deploy
```
build 完把 GHCR package 設為 public（免 imagePullSecret）：
`github.com/users/dfgh012316/packages/container/jerrytech-runner/settings` → Change visibility → Public。
（若保持 private，改在 values 設 `imagePullSecrets: [{name: ghcr-pull}]` 並於 `actions-runner` ns 建該 secret。）

### 2. 建 PAT secret
PAT 需求（public repo 的 repo-level runner 管理）：
- classic PAT：勾 `repo`；或
- fine-grained PAT：對 jerrytech-deploy 給 **Administration: Read and write**
```bash
kubectl create namespace actions-runner
kubectl -n actions-runner create secret generic runner-pat \
  --from-literal=ACCESS_TOKEN=<你的PAT>
```

### 3. helm install
```bash
helm upgrade --install actions-runner ./chart -n actions-runner --create-namespace
```

### 4. 驗證
```bash
kubectl -n actions-runner get pod
kubectl -n actions-runner logs deploy/actions-runner
gh api /repos/dfgh012316/jerrytech-deploy/actions/runners
```
GitHub → Settings → Actions → Runners 應看到 `jerrytech-pi-runner` 為 Idle。

## 撤除
```bash
helm uninstall actions-runner -n actions-runner
```
pod 收到 SIGTERM 會自動反註冊（grace period 90s），不留 offline 殭屍 runner。

## 權限邊界
- ClusterRole 只授予部署 `charts/app` 所需資源（namespaces / core / apps / batch / networking），**非 cluster-admin**。
- runner 只跑本 repo 受信任的 `main` / `repository_dispatch` workflow，**不對 fork PR 開放**。
