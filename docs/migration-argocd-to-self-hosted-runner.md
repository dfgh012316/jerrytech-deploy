# Migration Plan: ArgoCD → Self-Hosted Runner

把部署控制面從 **ArgoCD（pull-based GitOps）** 換成 **GitHub Actions self-hosted runner + Helm（push-based）**。

目標：個人 lab 上路徑更短、除錯更直覺，同時保留 `jerrytech-deploy` 當唯一部署設定來源。

---

## 0. 現況摘要

### 架構（現在）

```
app repo push
  → build & push image
  → workflow_call: update-image-tag
       → commit apps/<app>/values.yaml (image.tag)
            → ArgoCD poll/sync → helm template → cluster
```

### 要遷移的 workload

| App dir | Helm release name | Namespace | Image | Notes |
|---------|-------------------|-----------|-------|-------|
| `apps/popofinder` | `popofinder` | `popo` | Docker Hub `dfgh012316/popofinder` | CronJob reconcile |
| `apps/slipkit` | `slipkit` | `slipkit` | GHCR `ghcr.io/dfgh012316/slipkit` | needs `ghcr-pull` secret |

> ArgoCD 預設用 Application `metadata.name` 當 Helm release name。遷移時 **release name / namespace 必須對上**，才是 in-place 接管，不是重裝。

### 不經 Argo、維持現狀的 bootstrap

| Component | 路徑 | 遷移後 |
|-----------|------|--------|
| Cloudflare Tunnel | `bootstrap/cloudflared/` | 手動 / 偶發 apply |
| Postgres | `bootstrap/postgres/` | 手動 |
| common-config | `bootstrap/common-config/` | 手動（每 ns 一次） |
| Monitoring | `bootstrap/monitoring/` | 手動（若有裝） |
| ArgoCD | `bootstrap/argocd/` | **整包移除** |

### 已存在、可複用的資產

- 通用 chart：`charts/app`
- 每 app values：`apps/<app>/values.yaml`
- Reusable workflow：`.github/workflows/update-image-tag.yaml`（allowlist + 改 tag + GitHub App commit）
- 手動 secret：`secret.enabled: true` → cluster 內既有 `<release-name>` secret（**不要用 CI 寫 secret 明文**）
- Cloudflare Tunnel 已涵蓋 app hostname（`popo` / `slipkit`）；`argocd.jerrytech.me` 遷移後可刪

---

## 1. 目標架構

```
app repo push
  → build & push image
  → workflow_call: update-and-deploy (或分兩段)
       1) commit apps/<app>/values.yaml (image.tag)     # 仍在 ubuntu-latest
       2) self-hosted runner: helm upgrade --install    # 在 Pi / 能連 k3s 的 runner
```

### 設計原則

1. **Git 仍是 source of truth**  
   values 先 commit 再 deploy；rollback = revert git + 再跑 deploy。

2. **Runner 只做 apply，不發明設定**  
   `helm upgrade -f apps/<app>/values.yaml`，不在 workflow 裡 hardcode 業務 env。

3. **不要雙寫**  
   同一個 app 不可同時被 Argo auto-sync 與 runner deploy（會互相覆蓋 / 打架）。

4. **App → namespace 對照顯式化**  
   現在對照藏在 `application.yaml` 的 `destination.namespace`。Argo 拿掉後要有一份 registry（見 Phase 2）。

5. **Secret 維持 out-of-band**  
   DB URL、OAuth client secret 等繼續用 `kubectl create secret`；CI 只部署 workload manifest。

---

## 2. 目標 repo 形狀（遷移完成後）

```
.
├── apps/
│   ├── _registry.yaml          # NEW: app → namespace / release 對照
│   ├── popofinder/
│   │   └── values.yaml         # 刪掉 application.yaml
│   └── slipkit/
│       └── values.yaml
├── bootstrap/
│   ├── cloudflared/
│   ├── common-config/
│   ├── monitoring/
│   └── postgres/
│   # bootstrap/argocd/ 刪除
├── charts/app/                 # 不變
├── scripts/
│   └── deploy-app.sh           # NEW: 本機/CI 共用 helm upgrade 包裝
└── .github/workflows/
    ├── update-image-tag.yaml   # 可保留或併入 deploy
    └── deploy-app.yaml         # NEW: workflow_call 或 push-to-main 觸發
```

### `_registry.yaml` 建議格式

```yaml
# apps/_registry.yaml
apps:
  popofinder:
    namespace: popo
    releaseName: popofinder
  slipkit:
    namespace: slipkit
    releaseName: slipkit
```

避免再把 namespace 寫死在 workflow 字串裡。

---

## 3. Self-hosted runner 怎麼放

### 建議：**跑在 Pi 主機（k3s server 同機）**，用 systemd 管理

| 方案 | 優點 | 缺點 |
|------|------|------|
| **A. 主機 runner（建議）** | 設定簡單；直接用 `/etc/rancher/k3s/k3s.yaml` 或複製後的 kubeconfig；不必在 cluster 裡再養 runner | Pi 關機 = 不能 deploy |
| B. in-cluster runner Deployment | 純 k8s 風格 | 要 ServiceAccount/RBAC、常駐資源、排查多一層 |
| C. 只在家裡筆電跑 runner | 不用動 Pi | 不在家就 deploy 不了；網路/VPN 麻煩 |

**選 A 的理由：** 單節點 lab、你已有 `sshpi`；部署權限與 k3s admin 重疊可接受。

### Runner 安裝要點（Phase 1 執行）

1. GitHub repo `jerrytech-deploy` → Settings → Actions → Runners → New self-hosted runner  
2. 建議 label：`[self-hosted, linux, arm64, pi, k3s]`（Pi 多半是 aarch64）  
3. 以 **非 root 專用 user**（例如 `github-runner`）跑 service  
4. 給該 user 讀 kubeconfig 的權限：
   ```bash
   # 示例：複製並收斂權限（依你實際 k3s 設定調整）
   sudo mkdir -p /home/github-runner/.kube
   sudo cp /etc/rancher/k3s/k3s.yaml /home/github-runner/.kube/config
   sudo chown -R github-runner:github-runner /home/github-runner/.kube
   # 若 server 是 127.0.0.1，runner 在本機即可；否則改成可連的 API URL
   ```
5. 安裝 **Helm 3**（與目前 chart 相容即可）  
6. 驗證：
   ```bash
   sudo -u github-runner kubectl get ns
   sudo -u github-runner helm list -A
   ```

### 安全邊界（lab 最低限度）

- Runner **只註冊在 `jerrytech-deploy`**（不要用 org-wide 除非必要）  
- Workflow 對 `pull_request` **不要**自動用 self-hosted 部署到 prod cluster（只允許 `main` / `workflow_call` from trusted repos）  
- 維持既有 allowlist（`popofinder` / `slipkit`）  
- kubeconfig 勿 commit；token 用 runner 本機檔案

---

## 4. 目標 CI/CD 流程

### 4.1 日常發版（app repo）

```
popofinder / slipkit CI (成功 build 後)
  uses: dfgh012316/jerrytech-deploy/.github/workflows/deploy-app.yaml@main
  with:
    app: popofinder   # 或靠 repo 名推斷
    tag: ${{ github.sha 前 7 碼 }}
    registry: docker.io | ghcr.io
```

`deploy-app.yaml` 建議兩個 job：

| Job | runs-on | 職責 |
|-----|---------|------|
| `validate-and-commit` | `ubuntu-latest` | allowlist、確認 image 存在、用 GitHub App 改 `values.yaml` 並 push |
| `deploy` | `[self-hosted, pi, k3s]` | checkout **剛 push 的 main**、`helm upgrade --install` |

`deploy` 必須 `needs: validate-and-commit`，並 checkout 最新 main（含新 tag），避免 deploy 到舊 values。

### 4.2 只改 deploy 設定（本 repo）

```
push to main touching apps/** or charts/**
  → deploy 受影響的 app（可用 paths filter 或 matrix 全跑）
```

手動補：`workflow_dispatch` 輸入 `app`（必要時 `tag` 覆寫）。

### 4.3 `deploy-app.sh` 核心行為（示意）

```bash
#!/usr/bin/env bash
set -euo pipefail
APP="$1"
# 從 apps/_registry.yaml 讀 namespace / releaseName（可用 yq）
NS=$(yq e ".apps.${APP}.namespace" apps/_registry.yaml)
RELEASE=$(yq e ".apps.${APP}.releaseName" apps/_registry.yaml)

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
# common-config 若缺失可選擇 fail 或 document 手動 apply

helm upgrade --install "$RELEASE" charts/app \
  --namespace "$NS" \
  --create-namespace \
  --values "apps/${APP}/values.yaml" \
  --wait --timeout 5m \
  --history-max 5
```

對齊現有 Argo 行為：

- `CreateNamespace=true` → `--create-namespace`
- prune 資源：Helm 會在 chart 不再產出時刪除（upgrade 時）；**刪整個 app** 要另做 `helm uninstall`（見 §7）

### 4.4 與現有 `update-image-tag` 的關係

兩種做法擇一：

| 策略 | 作法 | 建議 |
|------|------|------|
| **合併** | 改成一個 `deploy-app.yaml`（commit tag + helm） | ✅ 較俐落，caller 只接一個 workflow |
| **串接** | 保留 `update-image-tag`，再 `workflow_run` / 第二個 call deploy | 遷移期可過渡，長期多餘 |

Caller（`popofinder` / `slipkit` repo）最後只要改 `uses:` 指向新 workflow 即可，input 介面盡量相容（`app` / `tag` / `registry`）。

---

## 5. 分階段遷移（執行順序）

> 原則：**一次只遷一個 app**；全程可經 `sshpi` 驗證；出問題可暫時把該 app 的 `application.yaml` 加回並讓 Argo 接管（僅在尚未刪 Argo 前）。

### Phase 0 — 盤點與凍結（約 30 分）

- [ ] 記錄現況：
  ```bash
  kubectl get application -n argocd
  helm list -A
  kubectl get deploy,svc,cm,secret,cronjob -n popo
  kubectl get deploy,svc,cm,secret -n slipkit
  ```
- [ ] 確認 secret 名稱：`popofinder`（ns `popo`）、`slipkit`（ns `slipkit`）、`ghcr-pull`（slipkit）
- [ ] 確認 `common-config` 在 `popo` / `slipkit`
- [ ] 約定凍結：遷移視窗內少推 app（或接受要多跑一次 deploy）

**Exit：** 有書面 inventory；知道每個 Helm release 名稱與 namespace。

---

### Phase 1 — 裝 self-hosted runner（約 1–2 小時）

- [ ] 在 Pi 建立 runner user、安裝 runner binary、註冊到 `jerrytech-deploy`
- [ ] 裝 `kubectl`（可指到 k3s）、`helm`、`yq`
- [ ] kubeconfig 權限 OK
- [ ] 在 repo 加一支 **noop 測試 workflow**（`runs-on: [self-hosted, pi]`，只 `kubectl get ns`）
- [ ] 從 GitHub Actions UI 手動跑通

**Exit：** GitHub 顯示 runner Online；測試 job 綠燈。

---

### Phase 2 — 在 repo 落地 deploy 工具（先不拆 Argo）

- [ ] 新增 `apps/_registry.yaml`
- [ ] 新增 `scripts/deploy-app.sh`
- [ ] 新增 `.github/workflows/deploy-app.yaml`（validate+commit 可先複用現有 update-image-tag 邏輯）
- [ ] 新增 `workflow_dispatch`：可指定 app 只 deploy **不改 tag**（方便接管現有 release）
- [ ] README 加「遷移中」說明：deploy 路徑與 Argo 並存的規則

**此階段仍不要刪 `application.yaml`。**  
可先在 runner 上 **dry-run**：

```bash
helm upgrade --install popofinder charts/app \
  -n popo -f apps/popofinder/values.yaml \
  --dry-run --debug
```

比對 live 與 dry-run 是否只差預期欄位（避免一次 upgrade 大爆炸）。

**Exit：** dry-run 可接受；workflow 能在 dispatch 下被 runner 執行（可先 skip 真的 upgrade，只印參數）。

---

### Phase 3 — Pilot：遷移 `slipkit`（建議先）

理由：較新、獨立 ns `slipkit`，blast radius 小於 popofinder（還有 CronJob + 舊資料）。

步驟：

1. **暫停 Argo 對 slipkit 的管理（避免雙寫）**
   - 從 git **刪除** `apps/slipkit/application.yaml` 並 merge  
   - 或 Argo UI 對 slipkit 關 automated sync 後 **Delete 時選 non-cascading**（保留 cluster 資源）  
   - 推薦 git 刪 application.yaml + root prune Application CR，且 **不要**在 Application 上留會 cascade 掉 workload 的 finalizer（或 Delete 選 orphan）  
   - 驗收：`kubectl get application slipkit -n argocd` → NotFound；`kubectl get deploy -n slipkit` → 仍在

2. **用 runner 接管**
   ```bash
   ./scripts/deploy-app.sh slipkit
   # 或 GitHub workflow_dispatch
   ```
3. **驗收**
   - `helm status slipkit -n slipkit`
   - pod Ready；`https://slipkit.jerrytech.me` 正常
   - 人為改一個 values（例如 resources）→ dispatch deploy → 有反映

4. **回歸發版路徑**
   - 在 `slipkit` app repo 改 call 新 deploy workflow（或暫時手動 dispatch）
   - 推一個小 commit，確認 tag commit + helm upgrade 全自動

**Exit：** slipkit 只由 runner 部署；Argo 列表無 slipkit。

**Rollback：** 恢復 `apps/slipkit/application.yaml`，等 Argo sync（Argo 仍在時）。

---

### Phase 4 — 遷移 `popofinder`

同一套：

1. 移除 `apps/popofinder/application.yaml`（orphan workload）  
2. `deploy-app.sh popofinder`  
3. 特別檢查 **CronJob** `reconcile` 是否還在、schedule 正確  
4. 打一次 health / 主要 API  
5. 改 `popofinder` repo 的 caller workflow  

**Exit：** 所有業務 app 皆 runner 部署；Argo 只剩 `root`（或 root 已無 child）。

---

### Phase 5 — 關閉並移除 ArgoCD

確認：

```bash
kubectl get application -n argocd
# 應只剩 root 或完全不需要
```

然後：

1. **刪 root Application**（若還在）  
2. **卸載 ArgoCD**（當初若用 Helm 裝在 `argocd` ns）：
   ```bash
   helm list -n argocd
   helm uninstall <argocd-release> -n argocd
   # 或依當初安裝方式
   kubectl delete ns argocd
   ```
3. **清 CRD**（可選，避免殘留）：
   ```bash
   kubectl get crd | grep argoproj
   # 確認無其他 argoproj 元件再用後再刪
   ```
4. **Cloudflare Zero Trust** 刪 `argocd.jerrytech.me` public hostname  
5. **Repo 清理**
   - 刪 `bootstrap/argocd/`
   - 刪所有 `apps/*/application.yaml`（應已刪）
   - 更新 `bootstrap/cloudflared/README.md`
   - 重寫 root `README.md`（架構圖改為 runner）
6. 若有 DNS / 書籤 / 密碼庫裡的 Argo URL，一併清掉

**Exit：** cluster 無 argocd ns；文件與 tunnel 一致；業務 app 不受影響。

---

### Phase 6 — 收尾與慣例

- [ ] 文件化：如何新增一個 app（registry + values + allowlist + secret + common-config + tunnel hostname）  
- [ ] 文件化：如何下線一個 app（`helm uninstall`、刪 `apps/<app>`、allowlist、tunnel、secret、ns）  
- [ ] （可選）runner 自動更新策略、disk 清理  
- [ ] （可選）失敗通知（GitHub Actions email / 你常用的 channel）  
- [ ] （可選）每週 cron workflow：`helm diff` 或 `kubectl diff` 做 drift 檢查——**取代 Argo self-heal 的最小集**

---

## 6. 風險與對策

| 風險 | 影響 | 對策 |
|------|------|------|
| 遷移時 Argo 與 runner 雙寫 | 配置抖動、難查 | 單一 app 先脫離 Argo 再 helm upgrade |
| Helm release 名稱/ns 不對 | 裝成第二套、舊的仍跑 | Phase 0 inventory；`helm list -A` 對表 |
| Runner offline | 無法部署 | systemd enable；文件寫如何看 runner 狀態；急用可 ssh 跑 `deploy-app.sh` |
| Pi 架構 arm64 action 不相容 | job 失敗 | 部署 job 用 shell + 本機 helm/kubectl，少用僅 amd64 的 container action |
| PR 從 fork 用 self-hosted | 安全風險 | 不對 `pull_request` 開 deploy；只 `main` / trusted `workflow_call` |
| 刪 Argo 時誤 cascade 業務資源 | 服務中斷 | 先 orphan Application；確認 deploy 在才刪 ns `argocd` |
| 無 self-heal | 手改 cluster 不會自動修 | 靠「不要手改」+ 可選 drift cron；真要修就重跑 deploy |
| `update-image-tag` 與 deploy 競態 | 舊 tag 被 deploy | deploy job checkout 含 tag commit 的 sha；或單一 workflow 串起 |

---

## 7. Day-2 操作速查（遷移後）

### 發版

- 正常：app repo push → CI 全自動  
- 手動重送：Actions → `deploy-app` → `workflow_dispatch`

### 只改設定（values / chart）

- PR merge 到 main →（建議）paths filter 觸發該 app deploy  
- 或 ssh 到 Pi：`cd jerrytech-deploy && git pull && ./scripts/deploy-app.sh <app>`

### 回滾 image

```bash
# 在 jerrytech-deploy 把 values.yaml 的 tag 改回舊值，commit
./scripts/deploy-app.sh <app>
# 或 helm rollback <release> -n <ns>
```

### 下線 app

```bash
helm uninstall <release> -n <ns>
kubectl delete ns <ns>   # 若確定不留 secret/資料
# git: 刪 apps/<app>、registry 條目、allowlist
# Cloudflare: 刪 hostname
```

### 新增 app

1. `apps/<name>/values.yaml`  
2. `_registry.yaml` 登記 namespace  
3. allowlist 加 repo  
4. `kubectl create ns` + `common-config` + secret（+ 必要時 imagePullSecret）  
5. tunnel hostname  
6. 第一次 `./scripts/deploy-app.sh <name>`  
7. app repo CI 接上 deploy workflow  

---

## 8. 成功標準（Definition of Done）

- [ ] `kubectl get ns argocd` → NotFound  
- [ ] `helm list -A` 可見 `popofinder`、`slipkit`，且與 Git values 的 image tag 一致  
- [ ] 從 `slipkit` / `popofinder` 各完整走一輪：push → image → values commit → runner helm → 服務新版本  
- [ ] 本 repo 改 values 可經 workflow 或 script 上線  
- [ ] README / cloudflared 文件不再提 ArgoCD  
- [ ] `argocd.jerrytech.me` 已從 Cloudflare 移除  
- [ ] 下線 / 新增 app 的步驟有文件可跟  

---

## 9. 建議時程（可依週末切）

| 時段 | 內容 |
|------|------|
| Day 1 | Phase 0–1（盤點 + runner） |
| Day 2 | Phase 2–3（script/workflow + slipkit pilot） |
| Day 3 | Phase 4–5（popofinder + 拆 Argo） |
| 之後 | Phase 6 文件與可選 drift |

總工作量粗估：**半個週末到一個週末**（不含突發除錯）。

---

## 10. 明確不在範圍

- 不把 postgres / cloudflared / monitoring 強行納入同一套 app deploy（可之後再做成 `bootstrap-*.yaml` + 手動或獨立 workflow）  
- 不引入第二套 GitOps（Flux 等）  
- 不在此次處理 multi-env / multi-cluster  
- 不把 secret 搬進 Git  

---

## 11. 下一步（你點頭後可開工的第一刀）

1. Phase 1：Pi 上註冊 self-hosted runner + noop workflow  
2. Phase 2：`_registry.yaml` + `deploy-app.sh` + `deploy-app.yaml`  
3. Phase 3：orphan + 接管 slipkit  

需要實作時，建議 **PR 粒度** 對齊 phase，方便回滾與 review。
