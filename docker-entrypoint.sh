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

# --- OpenCode: register Ollama provider for model discovery ---
if [ -n "${OLLAMA_HOST:-}" ]; then
  OPENCODE_CFG_DIR="$HOME/.config/opencode"
  mkdir -p "$OPENCODE_CFG_DIR"
  echo "[opencode] Querying Ollama models from $OLLAMA_HOST ..."
  OLLAMA_MODELS=$(curl -sf "${OLLAMA_HOST}/api/tags" 2>/dev/null | node -e "
    const d=require('fs').readFileSync('/dev/stdin','utf8');
    const tags=JSON.parse(d).models||[];
    const out={};
    tags.forEach(m=>{out[m.name]={name:m.name}});
    process.stdout.write(JSON.stringify(out));
  " 2>/dev/null || echo '{}')

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
