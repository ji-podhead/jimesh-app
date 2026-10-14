#!/usr/bin/env bash
# install.sh — JiMesh Cloud client bootstrap (PV-7, SPRINT-PROVISION-ONPREM-CLOUD-K8S).
#
# This is the PUBLIC bootstrap for joining a machine to JiMesh CLOUD — NOT the
# self-hosted Headscale flow (that lives in the JiMesh repo, deploy/client).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/ji-podhead/jimesh-app/main/install.sh | sh
#
# Env/konfig-Vertrag (SPRINT-PROVISION-ONPREM-CLOUD-K8S A6):
#   JIMESH_CLOUD_URL        — https://cp.jimesh.io (default)
#   JIMESH_WORKER_TOKEN     — one-shot worker-token from the provisioning page
#                             (Vault write-only, operator steps: PV-2/BG-3)
#   JIMESH_WORKER_NAME      — optional display name for this machine
#
# What it does:
#   1. Verifies the binary surface (docker present — the worker agent runs as a
#      compose/service; bare-metal docker-less machines are NOT supported yet).
#   2. Registers this machine with the CP via POST {JIMESH_CLOUD_URL}/api/workers/register
#      (BG/PV-4 contract) carrying the one-shot worker token; receives a
#      medium-tail token only if registration succeeds.
#   3. Writes a minimal worker-agent compose (no secrets on disk except the
#      medium-tail refresh token, 0600, /etc/jimesh/worker.env).
set -euo pipefail

JIMESH_CLOUD_URL="${JIMESH_CLOUD_URL:-https://cp.jimesh.io}"
WORKER_ENV_DIR="/etc/jimesh"
WORKER_ENV_FILE="$WORKER_ENV_DIR/worker.env"
AGENT_IMAGE="ghcr.io/ji-podhead/jimesh-worker:latest"

say() { printf '[jimesh] %s\n' "$*"; }
die() { printf '[jimesh] ERROR: %s\n' "$*" >&2; exit 1; }

# ---- 1. Precondition surface -------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not found — install docker first (worker agent runs as a container)"
command -v curl   >/dev/null 2>&1 || die "curl not found"

[ -n "${JIMESH_WORKER_TOKEN:-}" ] || die "JIMESH_WORKER_TOKEN missing — get it from the provisioning page (never enters this script visibly except through env)"

say "joining JiMesh Cloud: $JIMESH_CLOUD_URL"

# ---- 2. CP-Registration (PV-4 contract) --------------------------------------
say "registering worker (one-shot token)…"
REGISTER_STATUS="$(curl -s -o "$WORKER_ENV_DIR/.register.json" -w '%{http_code}' \
  -X POST "$JIMESH_CLOUD_URL/api/workers/register" \
  -H 'Content-Type: application/json' \
  --data "{\"token\":\"$JIMESH_WORKER_TOKEN\",\"name\":\"${JIMESH_WORKER_NAME:-$(hostname)}\"}" || true)"

if [ "$REGISTER_STATUS" = "501" ] || [ "$REGISTER_STATUS" = "404" ]; then
  die "CP worker-registration not live yet (HTTP $REGISTER_STATUS) — PV-4 backend endpoint still offline; install script contract is ready but the CP endpoint ships with the worker-registry rollout"
fi
[ "$REGISTER_STATUS" = "200" ] || die "registration failed (HTTP $REGISTER_STATUS) — check token; we do NOT retry automatically (one-shot tokens are consumed by design)"

# Extract a medium-lifetime refresh token + worker id from the CP answer.
JIMESH_WORKER_REFRESH_TOKEN="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("refresh_token",""))' "$WORKER_ENV_DIR/.register.json" 2>/dev/null || true)"
JIMESH_WORKER_ID="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("worker_id",""))' "$WORKER_ENV_DIR/.register.json" 2>/dev/null || true)"
rm -f "$WORKER_ENV_DIR/.register.json"
[ -n "$JIMESH_WORKER_REFRESH_TOKEN" ] || die "CP did not return a refresh token (empty worker payload) — failing closed, nothing persisted"

# ---- 3. Worker-agent service --------------------------------------------------
mkdir -p "$WORKER_ENV_DIR"
umask 077
printf 'JIMESH_CLOUD_URL=%s\nJIMESH_WORKER_ID=%s\nJIMESH_WORKER_REFRESH_TOKEN=%s\n' \
  "$JIMESH_CLOUD_URL" "$JIMESH_WORKER_ID" "$JIMESH_WORKER_REFRESH_TOKEN" > "$WORKER_ENV_FILE"
chmod 600 "$WORKER_ENV_FILE"

cat > /etc/systemd/system/jimesh-worker.service <<SERVICE
[Unit]
Description=JiMesh Cloud worker agent
After=network-online.target docker.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=5
ExecStart=/usr/bin/docker run --rm \\
  --name jimesh-worker \\
  --env-file $WORKER_ENV_FILE \\
  --network host \\
  $AGENT_IMAGE

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload 2>/dev/null || true
systemctl enable --now jimesh-worker 2>/dev/null || true

say "done — worker $JIMESH_WORKER_ID registered and agent scheduled (systemd jimesh-worker)"
say "token refresh is rotated server-side; secrets stayed inside Vault "
