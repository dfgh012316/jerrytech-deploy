#!/usr/bin/env bash
# 部署完清掉這個 app 在 Cloudflare 的快取，再預熱幾個入口。deploy-app.yaml 在 helm upgrade --wait 之後跑：
# 那時新的 Pod 已經在服務，清掉之後邊緣不會又被舊 Pod 的回應填回去。沒清的話，讀者在部署後還會看到舊的
# 頁面（openlawmaker 的 HTML 邊緣存 10 分鐘）與舊的 API 回應（1 小時）。
#
#   CLOUDFLARE_PURGE_TOKEN=… ./scripts/cdn-refresh.sh <app>
#
# 只處理 apps/_registry.yaml 裡有 cdn 的 app。沒有 CLOUDFLARE_PURGE_TOKEN 時印警告就結束（不讓部署失敗）。
# token：Cloudflare API token，權限 Zone › Cache Purge › Purge 與 Zone › Zone › Read，Zone Resources 只限那個 zone。
# 依 hostname 清（cdn.hosts），不是整個 zone：同一個 zone 裡的其他網站不受影響（Cloudflare 2025-04 起所有方案都能用）。
# 預熱只填到 runner 走到的那個 Cloudflare 機房（2026-11-14 量：runner Pod 走聖荷西 SJC，Pi 主機走新加坡 SIN；
# 每一行最後印的就是機房代號）；其他機房的第一位讀者照常回源一次，除非 zone 開了 Tiered Cache。
set -euo pipefail

APP="${1:?usage: cdn-refresh.sh <app>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${ROOT}/apps/_registry.yaml"

ZONE="$(yq e ".apps.${APP}.cdn.zone // \"\"" "$REGISTRY")"
if [ -z "$ZONE" ]; then
  echo "${APP} 沒有設定 cdn，略過"
  exit 0
fi
if [ -z "${CLOUDFLARE_PURGE_TOKEN:-}" ]; then
  echo "::warning::沒有 CLOUDFLARE_PURGE_TOKEN，${APP} 的 Cloudflare 快取沒有清（讀者可能還會看到舊的頁面一段時間）"
  exit 0
fi
# 先接住 yq 輸出再切行：`mapfile < <(yq ...)` 不會傳遞 yq 的失敗（同 chart-check.sh）
HOSTS_RAW="$(yq e ".apps.${APP}.cdn.hosts[]" "$REGISTRY")"
WARM_RAW="$(yq e ".apps.${APP}.cdn.warm[] // \"\"" "$REGISTRY")"
mapfile -t HOSTS <<<"$HOSTS_RAW"
mapfile -t WARM <<<"$WARM_RAW"
[ -n "${HOSTS[0]}" ] || { echo "::error::${APP} 的 cdn.hosts 是空的"; exit 1; }

cf() {
  curl -sS --max-time 30 -H "Authorization: Bearer ${CLOUDFLARE_PURGE_TOKEN}" -H 'Content-Type: application/json' "$@"
}

ZONES="$(cf "https://api.cloudflare.com/client/v4/zones?name=${ZONE}")"
ZONE_ID="$(jq -r '.result[0].id // empty' <<<"$ZONES")"
if [ -z "$ZONE_ID" ]; then
  echo "::error::找不到 zone ${ZONE}（token 要有這個 zone 的 Zone Read）：$(jq -c '.errors' <<<"$ZONES" 2>/dev/null || echo "$ZONES")"
  exit 1
fi

# 舊 Pod 剛從 Service 拿掉，等 kube-proxy 換好規則，避免清完又被舊 Pod 的回應填回去。
sleep 10
BODY="$(printf '%s\n' "${HOSTS[@]}" | jq -R . | jq -sc '{hosts: .}')"
RESULT="$(cf -X POST "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/purge_cache" --data "$BODY")"
if ! jq -e '.success' <<<"$RESULT" >/dev/null; then
  echo "::error::清除 ${HOSTS[*]} 的快取失敗：$(jq -c '.errors' <<<"$RESULT" 2>/dev/null || echo "$RESULT")"
  exit 1
fi
echo "==> 已清除 ${HOSTS[*]} 的 Cloudflare 快取"

# get：抓一次（帶 Accept-Encoding，和瀏覽器一樣拿壓縮的版本），印狀態碼、cf-cache-status 與機房（cf-ray 的結尾）。
get() {
  curl -sS --compressed -o /dev/null -D - --max-time 60 "$1" 2>/dev/null \
    | tr -d '\r' | awk 'NR == 1 { code = $2 }
        tolower($1) == "cf-cache-status:" { c = $2 }
        tolower($1) == "cf-ray:" { n = split($2, r, "-"); colo = r[n] }
        END { print code, c, colo }' || echo "ERR"
}

# 清除要幾秒才傳到每個機房；之後依序抓（每個之間停一下，不同時打 Pi）。
sleep 5
for host in "${HOSTS[@]}"; do
  # 首頁 HTML 寫死了這一版的 JS／CSS 檔名：一起抓，第一位讀者不用回源拿。
  ASSETS="$(curl -sS --compressed --max-time 60 "https://${host}/" | grep -oE '/assets/[A-Za-z0-9._-]+\.(js|css)' | sort -u || true)"
  mapfile -t A <<<"$ASSETS"
  echo "==> 預熱 ${host}"
  for p in "${WARM[@]}" "${A[@]}"; do
    [ -n "$p" ] || continue
    echo "  $(get "https://${host}${p}") ${p}"
    sleep 0.3
  done
done
