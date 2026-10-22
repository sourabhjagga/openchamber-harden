#!/usr/bin/env sh
set -eu

HOME="/home/openchamber"

OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}"
export OPENCODE_CONFIG_DIR

SSH_DIR="${HOME}/.ssh"
SSH_PRIVATE_KEY_PATH="${SSH_DIR}/id_ed25519"
SSH_PUBLIC_KEY_PATH="${SSH_PRIVATE_KEY_PATH}.pub"

mkdir -p "${SSH_DIR}"
if ! chmod 700 "${SSH_DIR}" 2>/dev/null; then
  echo "[entrypoint] warning: cannot chmod ${SSH_DIR}, continuing with existing permissions"
fi

if [ ! -f "${SSH_PRIVATE_KEY_PATH}" ] || [ ! -f "${SSH_PUBLIC_KEY_PATH}" ]; then
  if [ ! -w "${SSH_DIR}" ]; then
    echo "[entrypoint] warning: ssh key missing and ${SSH_DIR} is not writable, continuing without SSH key" >&2
  else
    echo "[entrypoint] generating SSH key..."
    if ! ssh-keygen -t ed25519 -N "" -f "${SSH_PRIVATE_KEY_PATH}" >/dev/null 2>&1; then
      echo "[entrypoint] warning: failed to generate SSH key, continuing without SSH key" >&2
    fi
  fi
fi

if ! chmod 600 "${SSH_PRIVATE_KEY_PATH}" 2>/dev/null; then
  echo "[entrypoint] warning: cannot chmod ${SSH_PRIVATE_KEY_PATH}, continuing"
fi

if ! chmod 644 "${SSH_PUBLIC_KEY_PATH}" 2>/dev/null; then
  echo "[entrypoint] warning: cannot chmod ${SSH_PUBLIC_KEY_PATH}, continuing"
fi

if [ -f "${SSH_PUBLIC_KEY_PATH}" ]; then
  echo "[entrypoint] SSH public key:"
  cat "${SSH_PUBLIC_KEY_PATH}"
fi

# Handle UI password environment variables. UI_PASSWORD is kept as a legacy
# alias; OPENCHAMBER_UI_PASSWORD is the canonical runtime variable.
if [ -z "${OPENCHAMBER_UI_PASSWORD:-}" ] && [ -n "${UI_PASSWORD:-}" ]; then
  OPENCHAMBER_UI_PASSWORD="$UI_PASSWORD"
  export OPENCHAMBER_UI_PASSWORD
fi

if [ -n "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
  echo "[entrypoint] UI password set, enabling authentication"
fi

if [ "${OH_MY_OPENCODE:-false}" = "true" ]; then
  OMO_CONFIG_FILE="${OPENCODE_CONFIG_DIR}/oh-my-opencode.json"

  if [ ! -f "${OMO_CONFIG_FILE}" ]; then
    echo "[entrypoint] npm installing oh-my-opencode..."
    npm install -g oh-my-opencode

    OMO_INSTALL_ARGS="--no-tui --claude=no --openai=no --gemini=no --copilot=no --opencode-zen=no --zai-coding-plan=no --kimi-for-coding=no --skip-auth"

    echo "[entrypoint] oh-my-opencode installing..."
    oh-my-opencode install ${OMO_INSTALL_ARGS}
  fi
fi

# Docker containers need to listen on all interfaces for port mapping to work.
OPENCHAMBER_HOST="${OPENCHAMBER_HOST:-0.0.0.0}"
export OPENCHAMBER_HOST

# The shared Doppler MCP server, started once for the whole container. Every
# project reaches it over HTTP instead of running its own copy.
BRIDGE_BIN="/usr/local/bin/openchamber-bridge"
BRIDGE_PORT="${OPENCHAMBER_BRIDGE_PORT:-8910}"
if [ -x "$BRIDGE_BIN" ]; then
  echo "[entrypoint] starting the shared MCP bridge on port ${BRIDGE_PORT}..."
  OPENCHAMBER_BRIDGE_PORT="$BRIDGE_PORT" nohup "$BRIDGE_BIN" >/tmp/openchamber-bridge.log 2>&1 &
  BRIDGE_WAITED=0
  while [ "$BRIDGE_WAITED" -lt 30 ]; do
    if curl -s -o /dev/null --max-time 2 \
      -X POST "http://127.0.0.1:${BRIDGE_PORT}/mcp" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json, text/event-stream" \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"openchamber","version":"1"}}}'; then
      echo "[entrypoint] MCP bridge is up"
      break
    fi
    sleep 1
    BRIDGE_WAITED=$((BRIDGE_WAITED + 1))
  done
  if [ "$BRIDGE_WAITED" -ge 30 ]; then
    echo "[entrypoint] warning: the MCP bridge did not come up, see /tmp/openchamber-bridge.log" >&2
  fi
fi

echo "[entrypoint] starting..."

if [ "$#" -gt 0 ]; then
  exec "$@"
fi

set -- bun packages/web/bin/cli.js
if [ -n "${OPENCHAMBER_UI_PASSWORD:-}" ]; then
  set -- "$@" --ui-password "$OPENCHAMBER_UI_PASSWORD"
fi
"$@"

exec bun packages/web/bin/cli.js logs
