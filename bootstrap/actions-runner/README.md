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

## runner 版本

entrypoint 用 `--disableupdate` 關掉 runner 的自我更新，版本由 `image/Dockerfile` 的 `FROM ghcr.io/actions/actions-runner:<版本>` 決定，**由 `.github/workflows/runner-auto-update.yaml` 每天自動追新版**，不用人工處理。

- 為什麼不用 runner 內建的自我更新：在這個 container 裡會失敗。2026-09-26 GitHub 要求 2.335.1 升到 2.337.0，更新腳本換完 bin 後找不到 `Runner.Listener`（exit 127），container 重建後又回到 image 的舊版。就算更新成功，也只寫在 container 的可寫層，pod 一重建就回到舊版，下一個 job 又觸發一次更新。更新期間 runner 會略過 job，deploy job 因此被 cancel（"The job was not acquired by Runner of type self-hosted even after multiple attempts"）。
- 關掉的代價：GitHub 規定新版發布後 **30 天內**要升級，否則不再派 job；重大安全更新則在升級前立即停派。
- 自動化流程（每天 03:17 Asia/Taipei）：
  1. `check-runner`：在 runner 上比對執行中的版本與 `FROM`。不一致代表之前 bump 了，但 build 或 restart 沒成功，標成 stale。
  2. `bump`：`actions/runner` 最新 release 比 `FROM` 新，而且 base image 已上 GHCR，就改 `FROM` 與 `chart/Chart.yaml` 的 `appVersion`，以 `github-actions[bot]` commit 到 main。沒有新版但 stale 時，用目前的 HEAD 重新 build + restart，所以失敗的升級隔天會自動重試。
  3. `build`：呼叫 `build-runner-image.yaml`（`GITHUB_TOKEN` 的 push 不會觸發它的 push trigger）。
  4. `restart`：用 `restart-job.yaml` 建一次性 Job。runner 不能在自己的 job 裡重啟自己（Deployment 是 `Recreate`），所以由這個 Job 等 runner 閒置後 `rollout restart`，再確認新 pod 以新版本上線。進度：`kubectl -n actions-runner logs job/runner-restart-<run_id>-<attempt> -f`（完成 24 小時後自動刪除）。
- 測試：Actions → *Runner auto-update* → `workflow_dispatch` 勾 `rebuild`，版本沒變也會 rebuild 並重啟 runner。
- 失敗時 GitHub 會寄信；因為 stale 而重試的那次 run，也會由 `stale-alert` 標成失敗來通知。手動 fallback：改 `FROM`、merge（自動 build），再 `kubectl -n actions-runner rollout restart deploy/actions-runner`。
- ⚠️ 這是 public repo：repo **60 天沒有任何活動**時 GitHub 會停用 schedule（會先寄信）。deploy 的 bot commit 也算活動；真的被停用，到 Actions 頁面重新 enable 即可。
- 其他工具版本（helm / kubectl / yq）也在同一個 Dockerfile，與 Pi host 和 k3s 對齊，不在自動更新範圍內。

## 撤除
```bash
helm uninstall actions-runner -n actions-runner
```
pod 收到 SIGTERM 會自動反註冊（grace period 90s），不留 offline 殭屍 runner。

## 權限邊界
- ClusterRole 只授予部署 `charts/app` 所需資源（namespaces / core / apps / batch / networking），**非 cluster-admin**。
- runner 只跑本 repo 受信任的 `main` / `repository_dispatch` workflow，**不對 fork PR 開放**。
