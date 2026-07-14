# Cloudflare Tunnel

Routes external traffic to in-cluster services via Cloudflare Tunnel (Zero Trust).

## Services routed

| Hostname | Service |
|----------|---------|
| `argocd.jerrytech.me` | `http://argocd-server.argocd.svc:80` |
| `popo.jerrytech.me` | `http://popofinder.popo.svc:80` |
| `papiin-api.jerrytech.me` | `http://papiin-api.papiin-api.svc:80` |
| `ssh.jerrytech.me` | `ssh://192.168.1.188:22` |
| `slipkit.jerrytech.me` | `http://slipkit.slipkit.svc:80` |

Public hostname rules are configured in Cloudflare Zero Trust dashboard, not in this repo.

## Deploy

1. Create the `tunnel-token` secret (do NOT commit the token):

```sh
kubectl create secret generic tunnel-token \
  --from-literal=token=<TUNNEL_TOKEN> \
  -n cloudflared
```

2. Apply the deployment:

```sh
kubectl apply -f cloudflared.yaml
```

## Tunnel info

- Tunnel name: `jerrytech-raspberrypi`
- Managed in: Cloudflare Zero Trust > Networks > Tunnels
