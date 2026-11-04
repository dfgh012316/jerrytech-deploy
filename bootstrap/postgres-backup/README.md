# Postgres backup

每天把共用 PostgreSQL（ns `shared`）的每個業務 db 用 `pg_dump -Fc` 備份到 Cloudflare R2，連同 roles（`pg_dumpall --globals-only`）。
R2 路徑 `<bucket>/postgres/<UTC 日期>/<db>.dump` 與 `globals.sql`，保留 30 天。台北 03:00 執行，在各 app 的每日排程之前。
不在 deploy pipeline 裡，跟 `bootstrap/postgres` 一樣手動 apply。

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

4. 建 Secret（只取四個值，經 stdin 傳到 Pi，不上命令列）並 apply：

   ```sh
   SSH=(ssh -o ProxyCommand='cloudflared access ssh --hostname %h' dfgh012316@ssh.jerrytech.me)
   grep -E '^(R2_ACCOUNT_ID|R2_ACCESS_KEY_ID|R2_SECRET_ACCESS_KEY|R2_BUCKET)=' ~/.config/jerrytech/r2-backup.env \
     | "${SSH[@]}" 'sudo k3s kubectl --context default create secret generic r2-backup -n shared --from-env-file=/dev/stdin'
   "${SSH[@]}" 'sudo k3s kubectl --context default apply -f -' < bootstrap/postgres-backup/backup.yaml
   ```

5. 手動跑一次確認：`kubectl --context default create job -n shared backup-test --from=cronjob/postgres-backup`，看 `kubectl --context default logs -n shared job/backup-test -c dump` 與 `-c upload`。

備份以超級使用者 `postgres` 經 service 連線（走 scram 密碼驗證；pod 內本機連線是 trust，不會用到密碼），密碼取自 `postgres-secrets`。
這個 Secret 只在第一次初始化資料目錄時寫進資料庫；之後還原 globals（例如升級 major 版本）會帶入來源伺服器的密碼雜湊，兩邊就對不上，
備份的 dump 步驟會 `password authentication failed`。2026-11-04 就是這樣（PG18 遷移造成），當時在 Pi 上產生新密碼、
經本機 socket `ALTER ROLE postgres PASSWORD` 後寫回 Secret。

## 還原

```sh
rclone copy r2:<bucket>/postgres/<日期>/ ./restore/
psql -U postgres -f restore/globals.sql                      # roles（已存在的會報錯，可忽略）
createdb -U postgres -O <owner> <db> && pg_restore -U postgres -d <db> restore/<db>.dump
```

新 db 預設 PUBLIC 有 CONNECT，還原後記得 `REVOKE CONNECT ON DATABASE <db> FROM PUBLIC`（見 `concepts/deployment` 的跨 db 隔離）。
