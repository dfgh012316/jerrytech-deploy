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
   # 內容（四行）：R2_ACCOUNT_ID=…、R2_ACCESS_KEY_ID=…、R2_SECRET_ACCESS_KEY=…、R2_BUCKET=…
   ```

4. 建 Secret（值經 stdin 傳到 Pi，不上命令列）並 apply：

   ```sh
   ssh -o ProxyCommand='cloudflared access ssh --hostname %h' dfgh012316@ssh.jerrytech.me \
     'sudo k3s kubectl create secret generic r2-backup -n shared --from-env-file=/dev/stdin' < ~/.config/jerrytech/r2-backup.env
   sudo k3s kubectl apply -f bootstrap/postgres-backup/backup.yaml   # 在 Pi 上，或經同一條 ssh
   ```

5. 手動跑一次確認：`kubectl create job -n shared backup-test --from=cronjob/postgres-backup`，看 `kubectl logs -n shared job/backup-test -c dump` 與 `-c upload`。

## 還原

```sh
rclone copy r2:<bucket>/postgres/<日期>/ ./restore/
psql -U postgres -f restore/globals.sql                      # roles（已存在的會報錯，可忽略）
createdb -U postgres -O <owner> <db> && pg_restore -U postgres -d <db> restore/<db>.dump
```

新 db 預設 PUBLIC 有 CONNECT，還原後記得 `REVOKE CONNECT ON DATABASE <db> FROM PUBLIC`（見 `concepts/deployment` 的跨 db 隔離）。
