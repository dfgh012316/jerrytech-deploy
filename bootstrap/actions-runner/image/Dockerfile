# syntax=docker/dockerfile:1
# 自訂 self-hosted runner image：官方 actions-runner 疊加 helm / kubectl / yq，
# 讓 in-cluster runner 能在 deploy job 直接 helm upgrade（不必每次 job 現裝工具）。
FROM ghcr.io/actions/actions-runner:2.335.1

USER root

# 版本對齊：kubectl = k3s v1.32.6；yq = Pi 上既有 v4.53.3；helm 3.16.x 與 Pi 一致
ARG HELM_VERSION=v3.16.4
ARG KUBECTL_VERSION=v1.32.6
ARG YQ_VERSION=v4.53.3
ARG TARGETARCH=arm64

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" | tar -xz -C /tmp \
 && install -m 0755 "/tmp/linux-${TARGETARCH}/helm" /usr/local/bin/helm \
 && rm -rf "/tmp/linux-${TARGETARCH}" \
 && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && curl -fsSL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
 && chmod +x /usr/local/bin/kubectl /usr/local/bin/yq

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

USER runner
ENTRYPOINT ["/entrypoint.sh"]
