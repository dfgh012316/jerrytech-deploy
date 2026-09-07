#!/usr/bin/env bash
# 對 apps/_registry.yaml 裡每個 app 跑 helm lint + helm template + kubeconform。
# CI（.github/workflows/chart-ci.yaml）與本機共用。需要 helm、yq (mikefarah v4)、kubeconform。
#
#   ./scripts/chart-check.sh            # 全部 app
#   ./scripts/chart-check.sh slipkit    # 單一 app
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${ROOT}/apps/_registry.yaml"
CHART="${ROOT}/charts/app"
K8S_VERSION="${K8S_VERSION:-1.32.6}"   # Pi 上的 k3s 版本

APPS=("$@")
if [ ${#APPS[@]} -eq 0 ]; then
  # 先接住 yq 輸出再餵 mapfile：`mapfile < <(yq ...)` 不會傳遞 yq 的失敗（set -e 管不到 process substitution）
  APP_LIST="$(yq e '.apps | keys | .[]' "$REGISTRY")"
  [ -n "$APP_LIST" ] || { echo "_registry.yaml 裡沒有任何 app"; exit 1; }
  mapfile -t APPS <<< "$APP_LIST"
fi

for APP in "${APPS[@]}"; do
  NS="$(yq e ".apps.${APP}.namespace" "$REGISTRY")"
  RELEASE="$(yq e ".apps.${APP}.releaseName" "$REGISTRY")"
  VALUES="${ROOT}/apps/${APP}/values.yaml"
  [ "$NS" != "null" ] && [ "$RELEASE" != "null" ] || { echo "app '${APP}' 不在 _registry.yaml"; exit 1; }

  echo "==> ${APP} (release=${RELEASE} ns=${NS})"
  helm lint "$CHART" --strict --values "$VALUES"
  helm template "$RELEASE" "$CHART" --namespace "$NS" --values "$VALUES" \
    | kubeconform -strict -summary -kubernetes-version "$K8S_VERSION"
done
