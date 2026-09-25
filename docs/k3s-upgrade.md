# Runbook：k3s v1.32.6 → v1.36.4（單節點 RPi）

> **2026-09-26 已執行完成**，結果與偏差見文末「執行紀錄」。
>
> 這是**手動執行的 runbook**，預定在內網直連 Pi 時一次跑完四次升級。本文的現況都是 2026-09-23 唯讀盤點的結果，執行當天要先跑「步驟 0」，確認現況沒有變。背景事實見 jerry-wiki `repos/jerrytech-deploy.md` 的「k3s 升級前提」與 `concepts/deployment.md` 的「維運存取」。

## 執行條件

- **只在 Pi 所在的內網執行**，直連 `ssh -i ~/.ssh/pi-backup dfgh012316@192.168.1.188`（2026-09-26 那台工作站沒有 `pi-backup`，用 `~/.ssh/id_ed25519` 登入）。不要透過 `ssh.jerrytech.me` 操作，因為它由 k3s 內的 cloudflared pod 承載，k3s 一有狀況就會跟著斷。
- 全程在 `screen -S k3s` 裡以 root 執行（先 `sudo -i`；host 沒有 tmux）。斷線後用 `screen -r k3s` 接回。
- **禁止 `shutdown -h`、`poweroff`、`halt`**：EEPROM 設定 `POWER_OFF_ON_HALT=0`，停機後不會自己開機。本 runbook 不需要 reboot，也不順手做 `apt upgrade`。
- 升級期間不 push popofinder 與 slipkit 的 main（步驟 1 會把 runner 縮到 0，漏網的 deploy 會在 GitHub 排隊）。
- 避開每月 1 日 04:00（`popofinder-reconcile` 執行時間）。預估需要 1.5–2 小時。

## 升級路徑

k3s 不能跳過 minor 版本（[docs.k3s.io/upgrades/manual](https://docs.k3s.io/upgrades/manual)：“Ensure that your plan does not skip intermediate minor versions”）。每個 minor 取最新 patch。目標版本是 stable channel 的 v1.36.4；v1.37.0 才剛發布 `.0`，這次不追。

| 次序 | 版本 | `k3s-arm64` sha256（2026-09-23 取自 release 的 `sha256sum-arm64.txt`） |
|---|---|---|
| 1 | `v1.33.13+k3s2` | `cf6afb3944f9ecf120fa2837b542479018c08f9ea1d1d181d4a68445e7717a8d` |
| 2 | `v1.34.11+k3s1` | `272f45b9efc69d0bbdb7042156156c6903087829a5003d4593af0ad2d08d76d4` |
| 3 | `v1.35.8+k3s1` | `898476e008704289382377ef19946f23b511cf2678042cb5c8aef991e64f840a` |
| 4 | `v1.36.4+k3s1` | `c920706346d5ad4e5cd3c7bf1bb09ce71ebe07fec829e513e40f1caf98aed8bb` |

升級方式是換掉 `/usr/local/bin/k3s` 再重啟 service。官方說明 k3s 停止期間 pod 會繼續跑（“Containers for Pods continue running even when K3s is stopped”），所以不需要 drain，也不需要重開機。不用 `get.k3s.io` install script 的理由：它會重寫 systemd unit 並立刻重啟，中間沒有停機備份的空檔。

各 minor 的 release notes 裡，與這台相關的只有 containerd 2.0（1.33 起）和 1.35 起的 cgroup v1 移除。本機已經是 containerd 2.0.5、cgroup v2，也沒有自訂 containerd template，所以兩者都不影響。1.33–1.36 沒有移除任何 API。

## 現況基準（2026-09-23）

- k3s `v1.32.6+k3s1`，SQLite datastore（`/var/lib/rancher/k3s/server/db/state.db`，約 52M），containerd `2.0.5-k3s1.32`，Debian 12，kernel `6.6.28+rpt-rpi-2712`。
- systemd `ExecStart` 只有 `k3s server`，**沒有** `/etc/rancher/k3s/config.yaml`。`kubectl` 與 `crictl` 都是指向 `k3s` 的 symlink，會跟著一起升級。
- 憑證 notAfter 為 2027-04-22，這次重啟不會觸發輪替。
- 根分割區剩 12G 可用（59%）。2026-09-23 用 `k3s crictl rmi --prune` 清掉 79 個沒有 container 引用的 image，釋出約 4G；見文末附錄。

## 決策：先停用 traefik（預設要做；執行前再確認一次）

目前 packaged `traefik` HelmChart CR 與 `server/manifests/traefik.yaml` 都還在，但 helm release 已經被卸掉，只剩 `traefik-crd`。叢集裡也沒有 traefik pod、LoadBalancer Service、Ingress 或 IngressRoute。

k3s 每次啟動都會重寫 packaged manifest，而 v1.33.13 起 chart 會換成 `traefik-40.1.4`，helm-controller 因此會重新 `helm install` traefik。它的 LoadBalancer Service 會經 servicelb 以 hostPort 佔用 host 的 80/443。

對外流量本來就是 Cloudflare Tunnel 直連 Service，所以停用 traefik 等於維持現況。停用後 k3s 會刪掉 manifest 與兩個 HelmChart，`traefik-crd` 被 uninstall，traefik.io、hub.traefik.io 以及 Gateway API 的 CRD 會一併刪除；這些 CRD 目前都沒有任何 CR。

停用要在 **v1.32.6 上單獨先做**（步驟 2），不要等到新版第一次啟動時才加。原因是新版 helm-controller 會不會在套用 disable 之前先把 traefik 裝回來，目前沒有確認。

如果決定保留 traefik，就跳過步驟 2，並接受升級後 host 的 80/443 會被佔用。

## 步驟

以下指令都在 screen 裡、`sudo -i` 之後以 root 執行。

```sh
D=/root/k3s-upgrade
```

### 0. 確認現況沒有漂移（不影響服務）

```sh
k3s --version | head -1                      # 預期 v1.32.6+k3s1
systemctl show k3s -p ExecStart --no-pager   # 預期 argv[]=/usr/local/bin/k3s server
ls -l /etc/rancher/k3s/config.yaml           # 預期不存在；若存在，先停下來看內容再決定
stat -fc %T /sys/fs/cgroup                   # 預期 cgroup2fs
df -h /                                      # 預期至少 3G 可用
k3s kubectl get node -o wide
k3s kubectl get pods -A
KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm list -A
```

在工作站上記下 app 的基準狀態（兩個都預期回 200）：

```sh
for u in https://popo.jerrytech.me/readyz https://slipkit.jerrytech.me/readyz; do curl -s -o /dev/null -w "$u %{http_code}\n" --max-time 10 "$u"; done
```

### 1. 準備（不影響服務）

**1a. 預先下載四個版本並驗 checksum**，比對上表的 sha256：

```sh
mkdir -p $D && chmod 700 $D && cd $D
for V in v1.33.13+k3s2 v1.34.11+k3s1 v1.35.8+k3s1 v1.36.4+k3s1; do
  U="https://github.com/k3s-io/k3s/releases/download/${V/+/%2B}"
  mkdir -p "$V"
  curl -fsSL -o "$V/k3s-arm64" "$U/k3s-arm64"
  curl -fsSL -o "$V/sha256sum-arm64.txt" "$U/sha256sum-arm64.txt"
  (cd "$V" && grep ' k3s-arm64$' sha256sum-arm64.txt | sha256sum -c -) || echo "CHECKSUM FAIL: $V"
done
```

**1b. 備份 PostgreSQL**。PG 和系統在同一張 SD 卡上，所以一定要備份：

```sh
k3s kubectl -n shared exec postgres-0 -- pg_dumpall -U postgres > $D/pg_dumpall-$(date +%F).sql
chmod 600 $D/pg_dumpall-*.sql
grep -c 'PostgreSQL database cluster dump complete' $D/pg_dumpall-*.sql   # 預期 1（檔尾是 "--" 與空行，tail -2 看不到這行）
```

這份 dump 含 role 密碼 hash，要當成 secret 看待。

**1c. 暫停部署**：

```sh
k3s kubectl -n actions-runner scale deploy actions-runner --replicas=0
```

### 2. 在 v1.32.6 上停用 traefik

這一步本身也是一次重啟 k3s 的預演。

```sh
systemctl stop k3s
mkdir -p $D/backup/v1.32.6-pre-traefik
cp -a /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/token $D/backup/v1.32.6-pre-traefik/
printf 'disable:\n  - traefik\n' > /etc/rancher/k3s/config.yaml
systemctl start k3s
timeout 300 sh -c 'until k3s kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 5; done' && echo "API ready"
```

驗證以下四件事。helm-delete job 跑完可能要 1–2 分鐘。

```sh
k3s kubectl -n kube-system get helmchart           # 預期 No resources found
ls /var/lib/rancher/k3s/server/manifests/          # 預期沒有 traefik.yaml
k3s kubectl get crd | grep -E 'traefik|gateway'    # 預期無輸出
KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm list -A  # 預期沒有 traefik-crd
```

驗證完，再跑一次步驟 3 的「每次升級後的檢查」，確認服務正常。

### 3. 逐版升級（依序做四次）

每次只改 `V`：

```sh
V=v1.33.13+k3s2          # 第 2–4 次依序改成 v1.34.11+k3s1、v1.35.8+k3s1、v1.36.4+k3s1
CUR=$(k3s --version | awk 'NR==1{print $3}')
B=$D/backup/$CUR
systemctl stop k3s                            # pod 繼續跑，只有 API 暫停
mkdir -p "$B"
cp -a /var/lib/rancher/k3s/server/db /var/lib/rancher/k3s/server/token /usr/local/bin/k3s "$B"/
install -m 0755 "$D/$V/k3s-arm64" /usr/local/bin/k3s
systemctl start k3s
timeout 300 sh -c 'until k3s kubectl get --raw=/readyz >/dev/null 2>&1; do sleep 5; done' && echo "API ready"
```

備份要在 k3s 停止時做，SQLite 的 `state.db` 與 `-wal`、`-shm` 才會一致。官方 rollback 的前提是要有「在要退回的那個 minor 上」取的 `server/db/` 與 `server/token`（[docs.k3s.io/upgrades/roll-back](https://docs.k3s.io/upgrades/roll-back)），所以每次升級都要各備份一次。

**每次升級後的檢查**：全部通過，而且穩定 5 分鐘，restart 次數沒有增加，才做下一次（單節點、服務少，5 分鐘足夠）。

```sh
k3s --version | head -1                                      # 等於 $V
k3s kubectl get node -o wide                                 # Ready，VERSION 是新版
for d in coredns metrics-server local-path-provisioner; do k3s kubectl -n kube-system rollout status deploy/$d --timeout=300s; done
k3s kubectl get pods -A | grep -vE 'Running|Completed'       # 只剩表頭才算通過
k3s kubectl -n kube-system get helmchart,job                 # 沒有 traefik（若步驟 2 有做）
journalctl -u k3s --since '-10 min' --no-pager | grep -E 'level=(error|fatal)' | tail -20   # 剛啟動時偶發的 error 可接受，持續重複出現才算異常
```

在工作站上重跑步驟 0 的 `/readyz` curl，兩個都要回 200。

### 4. 收尾

```sh
k3s kubectl -n actions-runner scale deploy actions-runner --replicas=1
k3s kubectl -n actions-runner rollout status deploy/actions-runner --timeout=300s
```

1. 確認 runner 在 GitHub 上是 online：`gh api repos/dfgh012316/jerrytech-deploy/actions/runners --jq '.runners[] | [.name,.status] | @tsv'`（需要 repo admin；沒有的話看 runner pod log 有沒有 `Listening for Jobs`）。
2. 用一次不帶 tag 的部署驗證 pipeline 實際可用。runner 的 Helm 3.16.4 已超出官方支援的 k8s 版本範圍，這一步用來確認它實際上還能用：`gh workflow run deploy-app.yaml -f app=slipkit`。values 沒變，所以不會觸發 rollout。
3. 從工作站把備份拉到 Pi 以外的地方。內容含 k8s Secrets（在 SQLite 裡是明文）、server token 和 PG globals，必須限制權限，也不要落在 repo 目錄裡：

   ```sh
   umask 077; mkdir -p ~/Backups/jerrytech-pi
   ssh -i ~/.ssh/pi-backup dfgh012316@192.168.1.188 \
     "sudo tar -C /root --exclude='k3s-upgrade/v1.*' -czf - k3s-upgrade" > ~/Backups/jerrytech-pi/k3s-upgrade-backup-$(date +%F).tar.gz
   ```

4. 穩定運行一週後刪掉 `$D/v1.*`（下載的 binary）。`$D/backup` 保留到下次升級。

## Rollback

要退回哪一版，就用那一版目錄下的 `db`、`token`、`k3s` 一起還原；也可以直接跳回更早的版本，例如 `v1.32.6+k3s1`。備份之後叢集寫入的狀態會遺失，但升級窗口內沒有部署，實際只會少掉 events 與 leases。

```sh
PREV=v1.35.8+k3s1                               # 要退回的版本（= $D/backup 底下的目錄名）
B=$D/backup/$PREV
systemctl stop k3s
mv /var/lib/rancher/k3s/server/db $D/failed-db-$(date +%s)   # 整個目錄換掉，不留新版的 -wal
cp -a "$B/db" /var/lib/rancher/k3s/server/db
cp -a "$B/token" /var/lib/rancher/k3s/server/token
install -m 0755 "$B/k3s" /usr/local/bin/k3s
systemctl start k3s
```

官方的 SQLite 說明只有 “replace the `.db` file with the copy”，上面的完整順序是從 etcd 那一頁的流程推過來的，屬於推論。如果還原後 pod 狀態異常，就先跑 `k3s-killall.sh` 停掉所有 container，再 `systemctl start k3s`。這會讓所有服務短暫中斷；在內網直連時做沒有問題。

**停損條件**：

- API 5 分鐘內沒有 ready：看 `journalctl -u k3s -n 200`，然後 `systemctl restart k3s` 再試一次；仍然失敗就 rollback 到 `$CUR`。
- 升級後出現原本沒有的 CrashLoop，15 分鐘內查不出原因：rollback。
- 任何一次升級的檢查沒通過，都不要進行下一次。

## 後續（升級完成後另開 PR）

- [x] Pi host 的 `/usr/local/bin/helm` 3.16.1 → **4.3.0**（2026-09-26）。舊 binary 留在 `/root/k3s-upgrade/helm-v3.16.1`；helm-diff 3.10.0 在 Helm 4 下不能用，一併升到 3.15.14（舊版在 `~/helm-plugin-backup/`）。
- [x] 因為 host 改用 Helm 4，runner 不照原計畫停在 3.21.x，直接對齊 4.3.0：`bootstrap/actions-runner/image/Dockerfile` 的 `HELM_VERSION=v4.3.0`、`KUBECTL_VERSION=v1.36.4`，`chart-ci.yaml` 的 helm 改 `v4.3.0`，`chart-check.sh` 的 `K8S_VERSION` 改 `1.36.4`（kubeconform schema 已有 v1.36.4）。Helm 4.3.x 支援 k8s 1.34–1.37。
- [x] runner 拉到新 image 後（`build-runner-image.yaml` 在 merge 時自動跑；image 是 `latest` + `pullPolicy: Always`，要 `rollout restart` 才會換），跑 `runner-selftest.yaml` 與步驟 4.2 的測試部署。
  - 2026-09-26：新 image（helm 4.3.0、kubectl 1.36.4）的 selftest 通過，但接著 GitHub 要求 runner 2.335.1 自我更新到 2.337.0，更新在 container 裡失敗，runner 更新期間略過了測試部署的 job（被 cancel，叢集未受影響）。修正：base image 升到 2.337.0 並加 `--disableupdate`（#11，見 `bootstrap/actions-runner/README.md`「runner 版本」）。
  - 修正後 runner 2.337.0 連續跑 selftest 與 `deploy-app -f app=slipkit` 都成功：slipkit revision 39、`APPLY_METHOD: client-side apply`，pod 沒有重建。
- [x] `scripts/deploy-app.sh` 的 `--atomic` 改 `--rollback-on-failure`、`--dry-run` 改 `--dry-run=client`（host 與 runner 都已是 Helm 4）。
- [ ] Pi host 的 helmfile 0.171.0 在 Helm 4 下會壞（呼叫已移除的 `helm version --client`），需要 ≥1.2.0；目前看起來沒在用。
- [ ] 同步 jerry-wiki：k3s 版本、traefik 已停用、`config.yaml` 已存在、host 與 runner 都是 Helm 4。

Helm 4 與既有 release 的相容性：三個 release（slipkit、popofinder、actions-runner）都是 Helm 3 建的，`helm get metadata` 顯示 `APPLY_METHOD: client-side apply (defaulted)`。Helm 4 的 upgrade 會沿用前一個 revision 的 apply method，只有全新 `helm install` 預設用 server-side apply，所以在 host 上不要對既有 app 重新 install，也不要加 `--server-side=true`。

## 執行紀錄（2026-09-26）

四跳全部完成，最終 `v1.36.4+k3s1`，containerd `2.3.4-k3s1.36`。app pod（popofinder、slipkit、postgres-0、cloudflared）全程沒有重啟，兩個 `/readyz` 每次檢查都是 200。

| 時間 | 動作 | 結果 |
|---|---|---|
| 01:12 | 步驟 0 | 與 2026-09-23 基準一致 |
| 01:37 | 步驟 1b–1c | pg_dumpall 362K（popo、postgres、slipbox）；runner 縮到 0 |
| 01:38 | 步驟 2 停用 traefik | HelmChart、`traefik.yaml`、26 個 traefik/Gateway CRD、`traefik-crd` release 都移除；helm-delete 期間有約 1 分鐘的 `waiting for delete ... requeuing` error |
| 01:41 | → v1.33.13+k3s2 | containerd 2.2.5；coredns / metrics-server / local-path 換新 pod；啟動時有 `runtime core not ready` 503 與 watch canceled |
| 01:57 | → v1.34.11+k3s1 | containerd 2.2.7；系統元件再換一次 pod |
| 02:04 | → v1.35.8+k3s1 | 系統元件 manifest 沒變，沿用原 pod；無 error |
| 02:11 | → v1.36.4+k3s1 | containerd 2.3.4；無 error |
| 02:17 | 步驟 4 | runner 放回，`Listening for Jobs`；runner 內 helm 3.16.4 能正常讀 release |

traefik 在之後的每一跳都沒有被裝回來，host 的 80/443 也沒被佔用。升級後根分割區剩 9.9G（備份與下載的 binary 約 760M）。

與上面步驟不同的地方：

- GitHub release 的 CDN 從家裡網路單一連線只有約 50KB/s（Pi 與工作站都一樣，Cloudflare 則有 24MB/s）。改在工作站用 16 條 `curl -r` 分段並行下載（約 800KB/s），驗過 sha256 後 scp 到 Pi。
- 步驟 2、3 包成 `$D/step2-disable-traefik.sh`、`$D/step3-upgrade.sh <V>`（先驗版本與 checksum、備份目錄已存在就中止、`set -eu`），用 `screen -dmS` 背景執行，log 在 `$D/logs/`。確認過 k3s unit 是 `KillMode=process`。
- 穩定觀察：v1.33.13 看 12 分鐘，之後每跳 5 分鐘。
- 步驟 4.2 的測試部署延到 runner 換成 Helm 4 之後一起做。
- 待辦：2026-10-03 之後刪 `$D/v1.*`。

## 附錄：2026-09-23 磁碟盤點與 image 清理

當時根分割區（29G SD 卡）用了 20G。主要用量如下：

| 位置 | 用量 | 說明 |
|---|---|---|
| `/var/lib/rancher/k3s/agent/containerd` | 7.6G | 解壓後的 layer 5.9G、壓縮 blob 1.7G；共 89 個 image，大多沒在用 |
| `/usr` | 5.5G | Raspberry Pi OS 桌面版的系統檔 |
| `/var/log/journal` | 2.8G | journald 沒設上限 |
| `/home/dfgh012316/.vscode-server` | 1.5G | VS Code Remote 累積的舊版 server |
| `/var/lib/docker` | 43M | host 的 Docker，與 k3s 無關 |

沒在用的 image 包括：slipkit 與 slipbox 的舊 tag 66 個、舊版 cloudflared 9 個，以及已退役的 argocd、postgres:15、papiin-api、agent-feed、redis、busybox 等。

`k3s crictl rmi --prune` 只會刪掉沒有被任何 container（包括已結束的）引用的 image；pause image 是 pinned，不會被刪。執行後剩 10 個 image，containerd 目錄降到 3.8G，根分割區剩 12G 可用。所有 pod 未受影響，兩個 `/readyz` 都回 200。之後 rollback app 到舊 tag，或 local-path 需要 busybox helper 時，會重新拉 image，這是預期行為。

尚未處理的部分：

- journal 可以用 `journalctl --vacuum-size=500M` 回收，並在 `/etc/systemd/journald.conf` 設 `SystemMaxUse=` 做長期上限。
- `.vscode-server` 裡的舊版 server 可以刪除。
- 執行中的 runner container 的 writable layer 約 0.8G（`crictl stats`）。它只會隨 container 重建而重置；要根治得把工作目錄改掛 `emptyDir`。
