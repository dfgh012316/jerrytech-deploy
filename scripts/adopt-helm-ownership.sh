#!/usr/bin/env bash
# Argo → helm 接管前置：把 chart 會產出、但目前缺 helm ownership 的既有資源
# 補上 meta.helm.sh annotation + managed-by=Helm label，讓 helm upgrade --install
# 能 in-place adopt（而非撞 "invalid ownership metadata"）。
#
# 只針對 chart 實際渲染出的資源（deployment/service/configmap/cronjob…），
# 不會誤碰手動維護的 common-config ConfigMap 或 app secret。
#
#   ./scripts/adopt-helm-ownership.sh <app>
set -euo pipefail

APP="${1:?usage: adopt-helm-ownership.sh <app>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REG="${ROOT}/apps/_registry.yaml"
NS="$(yq e ".apps.${APP}.namespace" "$REG")"
RELEASE="$(yq e ".apps.${APP}.releaseName" "$REG")"
[ "$NS" != "null" ] && [ "$RELEASE" != "null" ] || { echo "app '${APP}' 不在 _registry.yaml"; exit 1; }

echo "==> adopt ${APP}: release=${RELEASE} ns=${NS}"

# 從 chart 渲染出 kind/name 清單（過濾條件關閉而產生的空 doc）
mapfile -t RESOURCES < <(
  helm template "$RELEASE" "${ROOT}/charts/app" -n "$NS" -f "${ROOT}/apps/${APP}/values.yaml" \
    | yq e -N '[.kind, .metadata.name] | join("/")' - \
    | grep -Ev '^(null/|/|null$)' | sort -u
)

for r in "${RESOURCES[@]}"; do
  kind="${r%%/*}"; name="${r##*/}"
  [ -z "$kind" ] || [ -z "$name" ] && continue
  if kubectl -n "$NS" get "$kind" "$name" >/dev/null 2>&1; then
    kubectl -n "$NS" annotate "$kind" "$name" \
      meta.helm.sh/release-name="$RELEASE" \
      meta.helm.sh/release-namespace="$NS" --overwrite >/dev/null
    kubectl -n "$NS" label "$kind" "$name" \
      app.kubernetes.io/managed-by=Helm --overwrite >/dev/null
    echo "  adopted ${kind}/${name}"
  else
    echo "  skip (不存在) ${kind}/${name}"
  fi
done
echo "==> 完成。可執行 deploy-app.sh ${APP} 接管。"
