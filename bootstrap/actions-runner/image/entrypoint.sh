#!/usr/bin/env bash
# 自寫 runner entrypoint：用 PAT 向 GitHub 換 registration token 註冊自己，
# 收到 SIGTERM/SIGINT（pod 被刪）時自動反註冊，避免留下 offline 殭屍 runner。
set -euo pipefail

: "${ACCESS_TOKEN:?need ACCESS_TOKEN (PAT)}"
: "${REPO_OWNER:?need REPO_OWNER}"
: "${REPO_NAME:?need REPO_NAME}"

RUNNER_NAME="${RUNNER_NAME:-$(hostname)}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted}"
API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}"
URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"

# 取得一次性 token：$1 = registration | remove
get_token() {
  curl -sfL -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API}/actions/runners/${1}-token" | jq -r '.token'
}

cleanup() {
  echo "[entrypoint] 收到停止訊號，反註冊 runner ..."
  local t
  t="$(get_token remove || true)"
  if [ -n "${t}" ] && [ "${t}" != "null" ]; then
    ./config.sh remove --token "${t}" || true
  fi
  exit 0
}
trap cleanup SIGINT SIGTERM

echo "[entrypoint] 向 ${REPO_OWNER}/${REPO_NAME} 註冊 runner '${RUNNER_NAME}' (labels: ${RUNNER_LABELS})"
REG_TOKEN="$(get_token registration)"
if [ -z "${REG_TOKEN}" ] || [ "${REG_TOKEN}" = "null" ]; then
  echo "[entrypoint] 取得 registration token 失敗，請確認 PAT 權限" >&2
  exit 1
fi

./config.sh \
  --url "${URL}" \
  --token "${REG_TOKEN}" \
  --name "${RUNNER_NAME}" \
  --labels "${RUNNER_LABELS}" \
  --work "_work" \
  --unattended \
  --replace

# run.sh 放前景；trap 需要它在背景才能攔到訊號，故 & + wait
./run.sh &
wait $!
