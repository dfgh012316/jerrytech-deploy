# Postgres backup

每天把共用 PostgreSQL（ns `shared`）的每個業務 db 用 `pg_dump -Fc` 備份到 Cloudflare R2，連同 roles（`pg_dumpall --globals-only`）。
R2 路徑 `<bucket>/postgres/<UTC 時間戳>/<db>.dump` 與 `globals.sql`（例：`postgres/2026-11-14T190001Z/`），保留 7 天。
每天台北 03:00 執行（`timeZone: Asia/Taipei`），所以時間戳是前一天的 UTC 日期。保留與防刪不在 CronJob 裡，見下方「保留期限與防刪」。

CronJob 由 `.github/workflows/postgres-backup.yaml` 管：`backup.yaml` 合併到 main 就會 apply，叢集重建後要重套時跑
`gh workflow run postgres-backup.yaml`。Secret 不在 git 裡，照下面手動建。

## 第一次設定

1. Cloudflare 後台 → R2：建一個 **private** bucket（例：`jerrytech-backup`）。
2. R2 → Manage API tokens：建 token，權限 **Object Read & Write**、只限這個 bucket。記下 Access Key ID、Secret Access Key 與 Account ID。
3. 在自己的電腦寫一個只有自己能讀的檔（不要進 git、不要貼到聊天）：

   ```sh
   install -m 600 /dev/null ~/.config/jerrytech/r2-backup.env
   # 需要四行：R2_ACCOUNT_ID=…、R2_ACCESS_KEY_ID=…、R2_SECRET_ACCESS_KEY=…、R2_BUCKET=…
   # Cloudflare 給的其他值（API token、S3 endpoint）可以一起存，下一步只取這四個進叢集。
   ```

   **bucket 名稱打錯時 R2 回 403 AccessDenied，不是 NoSuchBucket**（只限單一 bucket 的 token 不透露其他 bucket 存不存在）——
   憑證驗證都過、卻每個操作都被拒，先對 bucket 名稱。

4. 建 Secret（只取四個值，經 stdin 傳到 Pi，不上命令列）。CronJob 不用手動 apply（見上）：

   ```sh
   SSH=(ssh -o ProxyCommand='cloudflared access ssh --hostname %h' dfgh012316@ssh.jerrytech.me)
   grep -E '^(R2_ACCOUNT_ID|R2_ACCESS_KEY_ID|R2_SECRET_ACCESS_KEY|R2_BUCKET)=' ~/.config/jerrytech/r2-backup.env \
     | "${SSH[@]}" 'sudo k3s kubectl --context default create secret generic r2-backup -n shared --from-env-file=/dev/stdin'
   ```

5. 手動跑一次確認：`kubectl --context default create job -n shared backup-test --from=cronjob/postgres-backup`，看 `kubectl --context default logs -n shared job/backup-test -c dump` 與 `-c upload`。

備份以超級使用者 `postgres` 經 service 連線（走 scram 密碼驗證；pod 內本機連線是 trust，不會用到密碼），密碼取自 `postgres-secrets`。
這個 Secret 只在第一次初始化資料目錄時寫進資料庫；之後還原 globals（例如升級 major 版本）會帶入來源伺服器的密碼雜湊，兩邊就對不上，
備份的 dump 步驟會 `password authentication failed`。2026-11-04 就是這樣（PG18 遷移造成），當時在 Pi 上產生新密碼、
經本機 socket `ALTER ROLE postgres PASSWORD` 後寫回 Secret。

## 保留期限與防刪

設定在 Cloudflare 後台（R2 → bucket → Settings），不在 git 裡：

| 設定 | Prefix | 值 | 作用 |
|---|---|---|---|
| Bucket lock rule | `postgres/` | 保留 7 天 | 7 天內的物件任何 token 都刪不掉、也覆寫不了，包含既有的物件 |
| Object lifecycle rule | `postgres/` | 7 天後刪除 | 取代原本 CronJob 裡的 `rclone delete`；R2 通常在到期後 24 小時內刪 |

- Pi 上的 token 必須維持 **Object Read & Write、只限這個 bucket**。拿掉 lock rule 要能改 bucket 設定（Admin 權限）；
  token 若給成 Admin，拿到 Pi 的人就能先拆鎖再刪。
- lock 只擋刪除與覆寫，擋不住讀取：拿到 token 仍可下載備份（含 `globals.sql` 的密碼雜湊）。
- 備份停掉（故障或被入侵）超過 7 天，lifecycle 會把最後幾份也刪掉，所以要盯「最新一份備份是多久前」。
- 能登入 Cloudflare 帳號的人可以刪掉 lock rule，帳號本身要開 2FA。

## 備份檢查與告警

`.github/workflows/postgres-backup-check.yaml` 每天台北 07:30 在 GitHub 的機器上（不是 Pi 上的 runner）列出 R2 的
`postgres/`，最新一份超過 26 小時、缺 `globals.sql`、有 0 byte 的 dump、少了前一份有的檔案，或總大小不到前一份的一半，
就發 Discord。跑在 Pi 之外，Pi 掛掉或被入侵時一樣會發現備份停了。手動跑（`gh workflow run postgres-backup-check.yaml`）
預設正常時也會發一則，用來測 webhook。

GitHub repo → Settings → Secrets and variables → Actions 要有：

| Secret | 內容 |
|---|---|
| `R2_RO_ACCESS_KEY_ID`、`R2_RO_SECRET_ACCESS_KEY` | 另建一把 R2 token：**Object Read only**、只限備份 bucket。不要重用 Pi 那把（那把能寫） |
| `R2_ACCOUNT_ID`、`R2_BUCKET` | 跟 Secret `r2-backup` 裡的一樣 |
| `DISCORD_WEBHOOK_URL` | Discord 頻道 → 編輯頻道 → 整合 → Webhook |

## 還原

```sh
rclone lsf r2:<bucket>/postgres/                               # 列出可用的時間戳
rclone copy r2:<bucket>/postgres/<時間戳>/ ./restore/
psql -U postgres -f restore/globals.sql                      # roles（已存在的會報錯，可忽略）
createdb -U postgres -O <owner> <db> && pg_restore -U postgres -d <db> restore/<db>.dump
```

新 db 預設 PUBLIC 有 CONNECT，還原後記得 `REVOKE CONNECT ON DATABASE <db> FROM PUBLIC`（見 `concepts/deployment` 的跨 db 隔離）。
