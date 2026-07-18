#!/usr/bin/env bash
# 從 apps/_registry.yaml 讀 namespace / releaseName，對 cluster 做 helm upgrade --install。
# 本機（ssh 到 Pi）與 CI（in-cluster self-hosted runner）共用同一支。
#
#   ./scripts/deploy-app.sh <app>              # 真的部署
#   ./scripts/deploy-app.sh <app> --dry-run    # 只渲染比對，不動 cluster
set -euo pipefail

APP="${1:?usage: deploy-app.sh <app> [--dry-run]}"
MODE="${2:-}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${ROOT}/apps/_registry.yaml"
VALUES="${ROOT}/apps/${APP}/values.yaml"

[ -f "$REGISTRY" ] || { echo "找不到 ${REGISTRY}"; exit 1; }
[ -f "$VALUES" ]   || { echo "找不到 ${VALUES}（app 名是否正確？）"; exit 1; }

NS="$(yq e ".apps.${APP}.namespace" "$REGISTRY")"
RELEASE="$(yq e ".apps.${APP}.releaseName" "$REGISTRY")"
[ "$NS" != "null" ] && [ "$RELEASE" != "null" ] || { echo "app '${APP}' 不在 _registry.yaml"; exit 1; }

echo "==> deploy app=${APP} release=${RELEASE} ns=${NS} ${MODE}"

ARGS=(upgrade --install "$RELEASE" "${ROOT}/charts/app"
  --namespace "$NS"
  --create-namespace
  --values "$VALUES"
  --history-max 5)

if [ "$MODE" = "--dry-run" ]; then
  ARGS+=(--dry-run --debug)
else
  ARGS+=(--wait --timeout 5m)
fi

helm "${ARGS[@]}"
