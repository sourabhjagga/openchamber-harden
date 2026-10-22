#!/usr/bin/env sh
set -eu

HOME="/home/openchamber"

OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-${HOME}/.config/opencode}"
export OPENCODE_CONFIG_DIR

# The MCP servers that every workspace shares live in the persistent volume.
# The image carries a compressed copy of each install, so the volume can be
# filled without a network round trip, and the launcher in front of each
# server fills it again if the volume was ever emptied.
VENDOR_DIR="${HOME}/.config/opencode/vendor"
VENDOR_ARCHIVES="/opt/mcp-vendor"
MCP_BIN_DIR="${HOME}/.config/opencode/bin"

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

# The MCP servers that every workspace shares live in the persistent volume.
# The image carries a compressed copy of each install, so the volume can be
# filled without a network round trip, and the launcher in front of each
# server fills it again if the volume was ever emptied.
unpack_vendor() {
  # unpack_vendor <name> <path inside the install that proves it is complete>
  name="$1"
  probe="$2"
  archive="${VENDOR_ARCHIVES}/${name}.tar.gz"
  target="${VENDOR_DIR}/${name}"
  [ -f "$archive" ] || return 1
  [ -e "${target}/${probe}" ] && return 0
  mkdir -p "$VENDOR_DIR"
  tar xzf "$archive" -C "$VENDOR_DIR"
  [ -e "${target}/${probe}" ]
}

if unpack_vendor analytics-mcp bin/analytics-mcp; then
  echo "[entrypoint] analytics-mcp is in place"
else
  echo "[entrypoint] warning: analytics-mcp is not available" >&2
fi

if unpack_vendor markitdown bin/markitdown-mcp; then
  echo "[entrypoint] markitdown-mcp is in place"
else
  echo "[entrypoint] warning: markitdown-mcp is not available" >&2
fi

if unpack_vendor supergateway bin/supergateway; then
  echo "[entrypoint] supergateway is in place"
else
  echo "[entrypoint] warning: supergateway is not available" >&2
fi

# The launcher in front of each server puts its install back if the volume
# was emptied. It is written here, and into the volume, because the config
# points at these paths and the volume has to survive a wipe.
mkdir -p "$MCP_BIN_DIR"

cat > "${MCP_BIN_DIR}/analytics-mcp" <<'LAUNCHER_EOF'
#!/bin/sh
# Launcher for the analytics-mcp server.
#
# The install lives in the persistent volume. If the volume was emptied, the
# launcher puts it back from the copy in the image, so the server starts
# without waiting on a package registry.
set -eu
VENDOR_DIR="${HOME}/.config/opencode/vendor"
VENV="${VENDOR_DIR}/analytics-mcp"
if [ ! -x "${VENV}/bin/analytics-mcp" ]; then
  mkdir -p "$VENDOR_DIR"
  tar xzf /opt/mcp-vendor/analytics-mcp.tar.gz -C "$VENDOR_DIR"
fi
exec "${VENV}/bin/analytics-mcp" "$@"
LAUNCHER_EOF
chmod 0755 "${MCP_BIN_DIR}/analytics-mcp"

cat > "${MCP_BIN_DIR}/markitdown-mcp" <<'LAUNCHER_EOF'
#!/bin/sh
# Launcher for the markitdown-mcp server.
#
# The install lives in the persistent volume. If the volume was emptied, the
# launcher puts it back from the copy in the image, so the server starts
# without waiting on a package registry.
set -eu
VENDOR_DIR="${HOME}/.config/opencode/vendor"
VENV="${VENDOR_DIR}/markitdown"
if [ ! -x "${VENV}/bin/markitdown-mcp" ]; then
  mkdir -p "$VENDOR_DIR"
  tar xzf /opt/mcp-vendor/markitdown.tar.gz -C "$VENDOR_DIR"
fi
exec "${VENV}/bin/markitdown-mcp" "$@"
LAUNCHER_EOF
chmod 0755 "${MCP_BIN_DIR}/markitdown-mcp"

# The shared Doppler MCP server, started once for the whole container. Every
# project reaches it over HTTP instead of running a copy of its own.
#
# The wrapper is written here rather than in the image because a Dockerfile RUN
# would have Docker substitute the shell variables in it before the script
# ever saw them, and the script would then look for its token file in the
# current directory. Writing it at start time, with a quoted heredoc, keeps
# every variable for the script that runs it.
BRIDGE_DIR="${HOME}/.npm-global/bin"
BRIDGE_BIN="${BRIDGE_DIR}/openchamber-bridge"
BRIDGE_PORT="${OPENCHAMBER_BRIDGE_PORT:-8910}"
SUPERGATEWAY_BIN="${VENDOR_DIR}/supergateway/bin/supergateway"

if [ -x "$SUPERGATEWAY_BIN" ]; then
  mkdir -p "$BRIDGE_DIR"
  cat > "$BRIDGE_BIN" <<'BRIDGE_EOF'
#!/bin/sh
# Shared Doppler MCP server, reached over HTTP by every project.
#
# Not exec: the wrapper stays as the process so that its own command line
# carries the marker the orphan sweep looks for. The sweep would otherwise
# end this bridge like any other stray MCP server.
set -eu
DOPPLER_TOKEN_FILE="${DOPPLER_TOKEN_FILE:-/home/openchamber/.config/opencode/doppler_token}"
DOPPLER_TOKEN="${DOPPLER_TOKEN:-}"
if [ -z "$DOPPLER_TOKEN" ] && [ -r "$DOPPLER_TOKEN_FILE" ]; then
  DOPPLER_TOKEN="$(tr -d '[:space:]' < "$DOPPLER_TOKEN_FILE")"
fi
export DOPPLER_TOKEN
SUPERGATEWAY="${HOME}/.config/opencode/vendor/supergateway/bin/supergateway"
if [ ! -x "$SUPERGATEWAY" ]; then
  mkdir -p "${HOME}/.config/opencode/vendor"
  tar xzf /opt/mcp-vendor/supergateway.tar.gz -C "${HOME}/.config/opencode/vendor"
fi
exec "$SUPERGATEWAY" \
  --stdio "node /home/openchamber/.config/opencode/node_modules/@dopplerhq/mcp-server/dist/index.js --read-only" \
  --port "${OPENCHAMBER_BRIDGE_PORT:-8910}" \
  --outputTransport streamableHttp
BRIDGE_EOF
  chmod 0755 "$BRIDGE_BIN"

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
