# jimesh-app (public)
Public JiMesh app repository: **client install scripts** + **apps** (android, linux, windows) for JiMesh Cloud.

## Client bootstrap (PV-7, SPRINT-PROVISION-ONPREM-CLOUD-K8S)

```bash
curl -fsSL https://raw.githubusercontent.com/ji-podhead/jimesh-app/main/install.sh | sh
```

Requires `docker` + `JIMESH_WORKER_TOKEN` env (one-shot, from the JiMesh provisioning page).
Registration contract: `POST {JIMESH_CLOUD_URL}/api/workers/register` (PV-4) —
until the CP endpoint is live the script fails honestly (HTTP 501/404 path).

NOT the self-hosted headscale bootstrap — that lives in the JiMesh repo (`deploy/client`).
