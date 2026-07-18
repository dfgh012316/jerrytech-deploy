# Runbook：health probe 標準化（startupProbe + readiness 改打 /readyz）

> 這份是**手動執行的 runbook**（jerrytech-deploy 無 task-executor pipeline）。配合 slipkit / popofinder 的 `health-readiness-version-endpoints` task。標準決策見 jerry-wiki `concepts/health-checks.md`。

## 背景

`charts/app` 目前的 probe template（`templates/deployment.yaml:94-103`）只渲染 `livenessProbe` + `readinessProbe`，兩者都打不查相依的 `/health`，且只參數化 `path` / `initialDelaySeconds`，其餘 probe 欄位改在 values 也不生效；無 `startupProbe`。本次把 chart 升級為 liveness/readiness/startup 三分、全欄位參數化，讓 readiness/startup 打新的 `/readyz`（查 DB）。

### ⚠️ 前置條件（rollout 順序，務必遵守）

readiness 改打 `/readyz` 後，**任何還沒有 `/readyz` 端點的舊 image pod 會 readiness 永久失敗 → not ready → 服務中斷**。因此本 runbook 的 chart 變更**只能在以下都完成後才 merge / 部署**：

1. slipkit 的 `health-readiness-version-endpoints` task 已 merge，新 image 已由 self-hosted runner 部署上線，且 `GET https://slipkit.jerrytech.me/readyz` 回 200。
2. popofinder 的同名 task 已 merge，新 image 已部署上線，且 pod 內 `/readyz` 可用。

在這兩者確認前，**不要**執行本 runbook 的 chart code 變更。

### 涉及檔案

- `charts/app/values.yaml` — probe 預設值（`:44-50`）：標準化為三分 + 全欄位
- `charts/app/templates/deployment.yaml` — probe 渲染（`:94-103`）：加 `startupProbe`、參數化全欄位
- `apps/slipkit/values.yaml` — 移除舊的 `probes` 覆寫（`:17-23`），改吃 chart 標準預設
- `apps/popofinder/values.yaml` — **不需改動**（本就無 `probes` 覆寫，自動繼承 chart 新預設）

---

## Part 1：chart values.yaml probe 預設標準化

### 現況

`charts/app/values.yaml:43-50`：

```yaml
# -- Liveness and Readiness probes
probes:
  liveness:
    path: /health
    initialDelaySeconds: 30
  readiness:
    path: /health
    initialDelaySeconds: 5
```

### 目標

改為三分 probe、全欄位有預設；liveness 打 `/health`，readiness + startup 打 `/readyz`。

### 不可動的範圍

不得更動 `values.yaml` 其他區塊（image / service / resources / securityContext 等）。

### 實作步驟

1. 將 `charts/app/values.yaml:43-50` 整段替換為：
   ```yaml
   # -- Startup / Liveness / Readiness probes.
   # liveness 打靜態 /health（永不查相依）；readiness 與 startup 打 /readyz（查 DB）。
   # startup 通過前 liveness 不啟動，故 liveness initialDelaySeconds 設 0。
   probes:
     startup:
       path: /readyz
       periodSeconds: 5
       timeoutSeconds: 2
       failureThreshold: 30
     liveness:
       path: /health
       initialDelaySeconds: 0
       periodSeconds: 10
       timeoutSeconds: 2
       failureThreshold: 3
     readiness:
       path: /readyz
       initialDelaySeconds: 0
       periodSeconds: 10
       timeoutSeconds: 2
       failureThreshold: 3
   ```

---

## Part 2：chart deployment.yaml 加 startupProbe 並全欄位參數化

### 現況

`charts/app/templates/deployment.yaml:94-103`：

```yaml
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.liveness.path }}
              port: http
            initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readiness.path }}
              port: http
            initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
```

### 目標

新增 `startupProbe`，並把 `periodSeconds` / `timeoutSeconds` / `failureThreshold` 全部參數化（liveness/readiness 另含 `initialDelaySeconds`）。

### 不可動的範圍

不得更動此段之外的 template（ports / env / resources / volumeMounts 等）；probe 的 `port: http` 具名 port 維持不變。

### 實作步驟

1. 將 `charts/app/templates/deployment.yaml:94-103` 整段替換為（縮排：`startupProbe` 等鍵為 10 空格）：
   ```yaml
          startupProbe:
            httpGet:
              path: {{ .Values.probes.startup.path }}
              port: http
            periodSeconds: {{ .Values.probes.startup.periodSeconds }}
            timeoutSeconds: {{ .Values.probes.startup.timeoutSeconds }}
            failureThreshold: {{ .Values.probes.startup.failureThreshold }}
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.liveness.path }}
              port: http
            initialDelaySeconds: {{ .Values.probes.liveness.initialDelaySeconds }}
            periodSeconds: {{ .Values.probes.liveness.periodSeconds }}
            timeoutSeconds: {{ .Values.probes.liveness.timeoutSeconds }}
            failureThreshold: {{ .Values.probes.liveness.failureThreshold }}
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.readiness.path }}
              port: http
            initialDelaySeconds: {{ .Values.probes.readiness.initialDelaySeconds }}
            periodSeconds: {{ .Values.probes.readiness.periodSeconds }}
            timeoutSeconds: {{ .Values.probes.readiness.timeoutSeconds }}
            failureThreshold: {{ .Values.probes.readiness.failureThreshold }}
   ```

---

## Part 3：apps/slipkit/values.yaml 移除舊 probe 覆寫

### 現況

`apps/slipkit/values.yaml:17-23` 覆寫了 probes（readiness `path: /health`、`initialDelaySeconds: 10`），會蓋掉 chart 新的 `/readyz` 預設：

```yaml
probes:
  liveness:
    path: /health
    initialDelaySeconds: 30
  readiness:
    path: /health
    initialDelaySeconds: 10
```

### 目標

移除整個 `probes:` 覆寫區塊，讓 slipkit 吃 chart 標準預設（與 popofinder 一致）。

### 不可動的範圍

不得更動 `apps/slipkit/values.yaml` 其他區塊（image / configMap / secret / migrations 等）。

### 實作步驟

1. 刪除 `apps/slipkit/values.yaml:17-23` 的整個 `probes:` 區塊（含 `liveness` / `readiness` 子項）。

---

## Manifest Verification

```bash
# 變更前後 diff（各 app 一份）
helm template charts/app -f apps/slipkit/values.yaml    > /tmp/slipkit-after.yaml
helm template charts/app -f apps/popofinder/values.yaml > /tmp/popo-after.yaml
```

（kubeval / kubeconform 本機未安裝；以 `helm template` 渲染成功 + 內容斷言取代結構校驗。）

---

## 驗證計畫

| Part | 驗證方式 | 預期斷言 | 為什麼這個斷言能證明目標達成 |
|------|---------|---------|------------------------------|
| Part 1 | `helm template charts/app -f apps/popofinder/values.yaml \| grep -q 'path: /readyz'` | exit 0 | popofinder 無 probe 覆寫，渲染出 `/readyz` 即證明 chart 預設 readiness/startup 已改打 `/readyz` |
| Part 2 | `helm template charts/app -f apps/popofinder/values.yaml \| grep -q 'startupProbe'` | exit 0 | 渲染結果含 `startupProbe`，證明 template 已新增該 probe |
| Part 2 | `helm template charts/app -f apps/popofinder/values.yaml \| grep -q 'failureThreshold: 30'` | exit 0 | `failureThreshold` 出現且為 startup 的 30，證明該欄位已參數化且吃到預設值（非 K8s 預設 3） |
| Part 3 | `test "$(helm template charts/app -f apps/slipkit/values.yaml \| grep -c 'path: /readyz')" -ge 2` | exit 0 | slipkit 渲染出至少兩處 `/readyz`（readiness + startup），證明舊的 `/health` 覆寫已移除、改吃 chart 預設 |
| Part 3 | `helm template charts/app -f apps/slipkit/values.yaml \| grep -q 'path: /health'` | exit 0 | 仍有一處 `/health`（liveness），證明 liveness 維持打靜態端點 |

---

## 驗收

- [ ] `helm template charts/app -f apps/slipkit/values.yaml >/dev/null`
- [ ] `helm template charts/app -f apps/popofinder/values.yaml >/dev/null`
- [ ] `helm template charts/app -f apps/popofinder/values.yaml | grep -q 'startupProbe'`
- [ ] `helm template charts/app -f apps/popofinder/values.yaml | grep -q 'path: /readyz'`
- [ ] `helm template charts/app -f apps/popofinder/values.yaml | grep -q 'failureThreshold: 30'`
- [ ] `test "$(helm template charts/app -f apps/slipkit/values.yaml | grep -c 'path: /readyz')" -ge 2`
- [ ] `helm template charts/app -f apps/slipkit/values.yaml | grep -q 'path: /health'`

---

## Rollout 順序 checklist（實際部署時）

1. [ ] slipkit app task merge → 新 image 部署 → `curl -fsS https://slipkit.jerrytech.me/readyz` 回 200
2. [ ] popofinder app task merge → 新 image 部署 → pod 內 `/readyz` 可用
3. [ ] 執行本 runbook Part 1–3 的 chart code 變更，跑完上方「驗收」全綠
4. [ ] 開 PR merge 到 `main` → self-hosted runner `helm upgrade` rolling update 兩個 release
5. [ ] `kubectl -n slipkit get pod` / `kubectl -n popo get pod` 確認新 pod `READY 1/1`，無 readiness/startup 失敗事件
