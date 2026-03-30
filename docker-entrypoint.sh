#!/usr/bin/env sh
set -eu

export HOME="${HOME:-/paperclip}"
export PAPERCLIP_HOME="${PAPERCLIP_HOME:-$HOME}"
export HOST="${HOST:-0.0.0.0}"

INSTANCE_ID="${PAPERCLIP_INSTANCE_ID:-default}"

mkdir -p "$PAPERCLIP_HOME" "$PAPERCLIP_HOME/instances/$INSTANCE_ID/logs"

# --- Tailscale VPN (connects to private Tailnet for local model access) ---
if [ -n "${TS_AUTHKEY:-}" ]; then
  echo "[tailscale] Starting tailscaled..."
  tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock --tun=userspace-networking &
  sleep 2
  echo "[tailscale] Authenticating..."
  tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey="$TS_AUTHKEY" --hostname="paperclip-railway"
  echo "[tailscale] Connected! IP: $(tailscale --socket=/var/run/tailscale/tailscaled.sock ip -4)"
else
  echo "[tailscale] Skipped (no TS_AUTHKEY set)"
fi

# Railway usually provides only the hostname. Paperclip needs a full public URL
# for authenticated/public mode onboarding.
if [ -z "${PAPERCLIP_PUBLIC_URL:-}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  export PAPERCLIP_PUBLIC_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi

exec node /app/src/server.js
