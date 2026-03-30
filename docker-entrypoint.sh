#!/usr/bin/env sh
set -eu

export HOME="${HOME:-/paperclip}"
export PAPERCLIP_HOME="${PAPERCLIP_HOME:-$HOME}"
export HOST="${HOST:-0.0.0.0}"

INSTANCE_ID="${PAPERCLIP_INSTANCE_ID:-default}"

mkdir -p "$PAPERCLIP_HOME" "$PAPERCLIP_HOME/instances/$INSTANCE_ID/logs"

# --- Tailscale VPN (connects to private Tailnet for local model access) ---
TS_SOCK="/var/run/tailscale/tailscaled.sock"
if [ -n "${TS_AUTHKEY:-}" ]; then
  echo "[tailscale] Starting tailscaled..."
  tailscaled --state=/var/lib/tailscale/tailscaled.state --socket="$TS_SOCK" --tun=userspace-networking --socks5-server=localhost:1055 --outbound-http-proxy-listen=localhost:1055 &
  sleep 2
  echo "[tailscale] Authenticating..."
  tailscale --socket="$TS_SOCK" up --authkey="$TS_AUTHKEY" --hostname="paperclip-railway"
  echo "[tailscale] Connected! IP: $(tailscale --socket="$TS_SOCK" ip -4)"

  # Set proxy vars for Tailscale userspace networking.
  # ALL_PROXY routes all traffic (including to Tailscale IPs) through the SOCKS5 proxy.
  # NO_PROXY excludes Railway internal services and localhost from the proxy.
  export ALL_PROXY=socks5://localhost:1055
  export HTTP_PROXY=http://localhost:1055
  export NO_PROXY=localhost,127.0.0.1,.railway.internal,10.0.0.0/8
  echo "[tailscale] HTTP/SOCKS5 proxy set on localhost:1055 (NO_PROXY: Railway internals)"
else
  echo "[tailscale] Skipped (no TS_AUTHKEY set)"
fi

# --- OpenCode: register Ollama provider for model discovery ---
if [ -n "${OLLAMA_HOST:-}" ]; then
  OPENCODE_CFG_DIR="$HOME/.config/opencode"
  mkdir -p "$OPENCODE_CFG_DIR"

  # Wait for Tailscale peer route to stabilize before querying Ollama
  echo "[opencode] Waiting for Tailscale peer route to $OLLAMA_HOST ..."
  OLLAMA_READY=false
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if curl -sf --connect-timeout 3 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
      OLLAMA_READY=true
      break
    fi
    echo "[opencode] Attempt $i: Ollama not reachable yet, retrying in 2s..."
    sleep 2
  done

  if [ "$OLLAMA_READY" = "true" ]; then
    echo "[opencode] Ollama reachable! Querying models..."
    OLLAMA_MODELS=$(curl -sf --connect-timeout 10 "${OLLAMA_HOST}/api/tags" | node -e "
      const d=require('fs').readFileSync('/dev/stdin','utf8');
      const tags=JSON.parse(d).models||[];
      const out={};
      tags.forEach(m=>{out[m.name]={name:m.name}});
      process.stdout.write(JSON.stringify(out));
    " 2>/dev/null || echo '{}')
  else
    echo "[opencode] WARNING: Could not reach Ollama at $OLLAMA_HOST after 10 attempts"
    OLLAMA_MODELS='{}'
  fi

  cat > "$OPENCODE_CFG_DIR/opencode.json" <<EOCFG
{
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama (Mac Studio)",
      "options": {
        "baseURL": "${OLLAMA_HOST}/v1"
      },
      "models": ${OLLAMA_MODELS}
    }
  }
}
EOCFG
  MODEL_COUNT=$(echo "$OLLAMA_MODELS" | node -e "const d=require('fs').readFileSync('/dev/stdin','utf8');console.log(Object.keys(JSON.parse(d)).length)" 2>/dev/null || echo "0")
  echo "[opencode] Registered ${MODEL_COUNT} Ollama model(s) in $OPENCODE_CFG_DIR/opencode.json"
else
  echo "[opencode] Skipped Ollama provider (no OLLAMA_HOST set)"
fi

# Railway usually provides only the hostname. Paperclip needs a full public URL
# for authenticated/public mode onboarding.
if [ -z "${PAPERCLIP_PUBLIC_URL:-}" ] && [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
  export PAPERCLIP_PUBLIC_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi

exec node /app/src/server.js
