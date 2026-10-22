# syntax=docker/dockerfile:1
FROM oven/bun:1.4.3 AS base
WORKDIR /app

FROM base AS deps
WORKDIR /app
COPY package.json bun.lock ./
COPY bun-patches ./bun-patches
COPY packages/ui/package.json ./packages/ui/
COPY packages/web/package.json ./packages/web/
COPY packages/electron/package.json ./packages/electron/
COPY packages/vscode/package.json ./packages/vscode/
COPY packages/mobile/package.json ./packages/mobile/
COPY packages/sdk/package.json ./packages/sdk/
RUN bun install --frozen-lockfile --ignore-scripts

FROM deps AS builder
WORKDIR /app
COPY . .
# The server imports @openchamber/sdk at runtime, and deps installed with
# --ignore-scripts, so the root postinstall never built it. Build it here
# so the runtime stage can copy the output.
RUN bun run --cwd packages/sdk build
RUN bun run build:web

FROM oven/bun:1.4.3 AS runtime
WORKDIR /home/openchamber

RUN apt-get update && apt-get install -y --no-install-recommends \
  bash \
  bzip2 \
  ca-certificates \
  curl \
  git \
  less \
  openssh-client \
  python3 \
  python3-pip \
  && rm -rf /var/lib/apt/lists/*

# uv, the tool the catalog's local Python MCP entries call through `uvx`
# (mcp-grafana). The image ships no Python package manager beyond pip, and
# `uvx` manages its own environments, so the catalog entries that shell out to
# it cannot spawn without this.
ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
  && uv --version \
  && uvx --version

# markitdown-mcp in a venv that is built once, here.
#
# The catalog entry runs it through `uvx`, and `uvx` starts two processes per
# spawn: a `uv tool uvx` wrapper plus the Python server. OpenCode opens one
# MCP connection per project location, so on this host that wrapper and its
# interpreter were the single largest consumer of memory. A venv built at image
# build time gives the entry one plain executable to start instead.
ENV MARKITDOWN_VENV=/opt/markitdown
RUN uv venv "${MARKITDOWN_VENV}" --python 3.13 \
  && uv pip install --python "${MARKITDOWN_VENV}/bin/python" markitdown-mcp \
  && rm -rf /root/.cache/uv

# Chromium and the tools the Server Browser extension needs.
#
# The extension drives a Chrome it starts on this host, and it looks the
# binary up under the names google-chrome, google-chrome-stable, chromium and
# chromium-browser. The chromium-sandbox package ships the setuid-root helper
# Chrome needs: the container blocks unprivileged user namespaces, so without
# it Chrome refuses to start and the extension cannot serve a page.
#
# lsof and ps are only used for the extension's optional development-server
# discovery, but the extension declares them in its service permissions, so
# they have to exist for the grant to be honoured.
RUN apt-get update && apt-get install -y --no-install-recommends \
  chromium \
  chromium-common \
  chromium-sandbox \
  lsof \
  procps \
  && rm -rf /var/lib/apt/lists/* \
  && chromium --version \
  && test -u /usr/lib/chromium/chrome-sandbox

# A wrapper for the Server Browser extension to find on PATH.
#
# The extension looks the browser up under the names google-chrome,
# google-chrome-stable, chromium and chromium-browser, walking PATH in order,
# and it starts the browser without a sandbox flag. This container blocks
# unprivileged user namespaces, so Chromium's namespace sandbox cannot start
# and the browser aborts during startup with SIGABRT. The setuid helper that
# Chromium's SUID sandbox would need cannot be reached at runtime either,
# because that decision is made when the browser is built.
#
# /usr/local/bin comes before /usr/bin in PATH, so this wrapper is the
# chromium the extension resolves, and it starts the real browser with the
# sandbox disabled. The container is the isolation boundary here; the browser
# is only used to fetch pages the agent was asked to look at.
RUN printf '#!/bin/sh\nexec /usr/bin/chromium --no-sandbox "$@"\n' \
      > /usr/local/bin/chromium \
  && chmod 0755 /usr/local/bin/chromium \
  && /usr/local/bin/chromium --version

# Engram, the persistent memory server. One static Go binary, no runtime
# dependency stack, and it is what both the `engram` MCP entry and the
# OpenChamber Engram panel shell out to, so it has to be on PATH for them.
#
# The version is pinned and the archive checksum is verified, so a rebuilt
# image always carries the same binary and a tampered download fails the
# build instead of shipping.
ARG ENGRAM_VERSION=3.5.2
ARG ENGRAM_SHA256=b0ba49cf5a7d5af436c9744a9a0d638b3f9ebb2a7321c8736d30e96305c2993c
RUN curl -fsSL -o /tmp/engram.tar.gz \
    "https://github.com/Gentleman-Programming/engram/releases/download/v${ENGRAM_VERSION}/engram_${ENGRAM_VERSION}_linux_arm64.tar.gz" \
  && echo "${ENGRAM_SHA256}  /tmp/engram.tar.gz" | sha256sum -c - \
  && tar -xzf /tmp/engram.tar.gz -C /usr/local/bin engram \
  && rm -f /tmp/engram.tar.gz \
  && engram --version

# Node.js: ARG default is the major, tracked by Renovate (bumps only when a
# new major ships); setup_${NODE_VERSION}.x resolves the latest patch of that
# line at build time.
ARG NODE_VERSION=24
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - \
  && apt-get install -y --no-install-recommends nodejs \
  && rm -rf /var/lib/apt/lists/*

# Replace the base image's 'bun' user (UID 1000) with 'openchamber'
# so mounted volumes with 1000:1000 ownership work correctly.
RUN userdel bun \
  && groupadd -g 1000 openchamber \
  && useradd -u 1000 -g 1000 -m -s /bin/bash openchamber \
  && chown -R openchamber:openchamber /home/openchamber

ENV NPM_CONFIG_PREFIX=/home/openchamber/.npm-global
ENV PATH=${NPM_CONFIG_PREFIX}/bin:${PATH}

# Create the runtime directories and install the OpenCode CLI as the
# openchamber user, so every path it writes to is owned by uid 1000.
USER openchamber
RUN npm config set prefix /home/openchamber/.npm-global && mkdir -p /home/openchamber/.npm-global && \
  mkdir -p \
    /home/openchamber/.local/share/opencode \
    /home/openchamber/.local/state/opencode \
    /home/openchamber/.config/openchamber \
    /home/openchamber/.config/opencode \
    /home/openchamber/.ssh \
    /home/openchamber/workspaces && \
  npm install -g @opencode/cli@2.1.2

# analytics-mcp, baked in rather than installed on first use.
#
# The MCP's launcher reinstalls the package whenever its binary is missing,
# but ~/.local is not a volume, so every redeploy used to start with a wiped
# install and the reinstall then failed because the image had no pip. With the
# package baked in, the launcher finds the binary straight away and never
# reaches for pip at all.
RUN python3 -m pip install --user --break-system-packages --no-cache-dir \
    analytics-mcp==0.7.0 \
  && test -x /home/openchamber/.local/bin/analytics-mcp \
  && python3 -c "import analytics_mcp.server"

# A shared instance of the Doppler MCP server.
#
# OpenCode opens one MCP connection per project location, so a local MCP
# server is started once per location. The Doppler server only reads
# secrets, and every location wants the same ones, so one instance serves
# them all. This wrapper fronts the server over HTTP and the MCP entry
# points at that.
#
# The script name carries a marker the orphan sweep recognises: the bridge
# outlives the sessions that use it, so it must not be reclaimed like a
# stray MCP server.
ARG SUPERGATEWAY_VERSION=4.2.0
RUN npm install -g "supergateway@${SUPERGATEWAY_VERSION}" \
  && mkdir -p /usr/local/lib/openchamber \
  && printf '%s\n' \
    '#!/bin/sh' \
    '# Shared Doppler MCP server, reached over HTTP by every project.' \
    'set -eu' \
    'DOPPLER_TOKEN_FILE="${DOPPLER_TOKEN_FILE:-/home/openchamber/.config/opencode/doppler_token}"' \
    'DOPPLER_TOKEN="${DOPPLER_TOKEN:-}"' \
    'if [ -z "$DOPPLER_TOKEN" ] && [ -r "$DOPPLER_TOKEN_FILE" ]; then' \
    '  DOPPLER_TOKEN="$(tr -d "[:space:]" < "$DOPPLER_TOKEN_FILE")"' \
    'fi' \
    'export DOPPLER_TOKEN' \
    '# Not exec: the wrapper stays as the process so its own command line' \
    '# carries the marker the orphan sweep looks for.' \
    'supergateway \' \
    '  --stdio "node /home/openchamber/.config/opencode/node_modules/@dopplerhq/mcp-server/dist/index.js --read-only" \' \
    '  --port "${OPENCHAMBER_BRIDGE_PORT:-8910}" \' \
    '  --outputTransport streamableHttp' \
    > /usr/local/bin/openchamber-bridge \
  && chmod 0755 /usr/local/bin/openchamber-bridge \
  && supergateway --version

# cloudflared 2026.3.0 - update digest explicitly when upgrading
COPY --from=cloudflare/cloudflared@sha256:6d91c121b803126f7a5344005d17a9324788fc09d305b6e2560ec6040a7ae283 /usr/local/bin/cloudflared /usr/local/bin/cloudflared

ENV NODE_ENV=production
# The base image ships with the POSIX locale, which makes bash readline treat
# every byte of a multibyte character separately in the built-in terminal.
ENV LANG=C.UTF-8

COPY scripts/docker-entrypoint.sh /home/openchamber/openchamber-entrypoint.sh

COPY --from=builder --chown=openchamber:openchamber /app/node_modules ./node_modules
COPY --from=builder --chown=openchamber:openchamber /app/packages/web/node_modules ./packages/web/node_modules
COPY --from=builder --chown=openchamber:openchamber /app/package.json ./package.json
COPY --from=builder --chown=openchamber:openchamber /app/packages/web/package.json ./packages/web/package.json
COPY --from=builder --chown=openchamber:openchamber /app/packages/sdk/package.json ./packages/sdk/package.json
COPY --from=builder --chown=openchamber:openchamber /app/packages/sdk/dist ./packages/sdk/dist
COPY --from=builder --chown=openchamber:openchamber /app/packages/web/bin ./packages/web/bin
COPY --from=builder --chown=openchamber:openchamber /app/packages/web/server ./packages/web/server
COPY --from=builder --chown=openchamber:openchamber /app/packages/web/dist ./packages/web/dist

# Fix upstream packaging bug: the built-in-extensions directory can ship as
# root-only (mode 0700), which makes the server crash on startup with
# "EACCES: permission denied, open .../built-in-extensions/registry.json"
# because the runtime user is openchamber (uid 1000). Make it readable.
RUN chmod -R a+rX /home/openchamber/packages/web/server/built-in-extensions 2>/dev/null || true

EXPOSE 3000

ENTRYPOINT ["sh", "/home/openchamber/openchamber-entrypoint.sh"]
