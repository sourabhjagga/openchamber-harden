# syntax=docker/dockerfile:1
FROM oven/bun:1.4.4 AS base
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

# What the app runs on, without the toolchain that built it.
#
# The runtime copies this stage's node_modules instead of the builder's. The
# builder needs vite, typescript, oxlint, tailwind, electron-builder and the
# rest of the development stack; the running server needs none of them, and
# together they are about 750 MB of the image.
#
# The prune is a fresh install from the lockfile, not a deletion from the
# installed tree. Bun hardlinks the package store, so removing the top level of
# a live tree leaves symlinks pointing into a store that is now incomplete; a
# clean install cannot end up in that state.
#
# PRUNE_DEV_DEPS=false leaves the full tree in place, so a regression here is
# undone by flipping one build argument instead of reverting the Dockerfile.
FROM deps AS prod-deps
ARG PRUNE_DEV_DEPS=true
RUN if [ "$PRUNE_DEV_DEPS" = "true" ]; then \
      rm -rf node_modules packages/*/node_modules \
      && bun install --frozen-lockfile --ignore-scripts --production \
      && cd packages/web \
      && bun -e 'for (const name of ["express", "ws", "jose", "openai", "simple-git", "zod", "yaml", "node-pty", "@opencode/client"]) import.meta.resolve(name)' \
      && printf 'pruned node_modules: %s\n' "$(du -sh /app/node_modules | cut -f1)"; \
    fi

FROM oven/bun:1.4.4 AS runtime
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

# The browser, and the tools the Server Browser extension needs.
#
# The extension drives a browser it starts on this host, and it looks the
# binary up under the names google-chrome, google-chrome-stable, chromium and
# chromium-browser. Two flavours can supply it, both landing at
# /opt/browser/chrome so the wrapper below does not have to know which one ran:
#
#   debian    Debian's chromium. Carries the distribution's security patches,
#             which arrive with every image rebuild.
#   cft-shell Chrome for Testing's chrome-headless-shell, the binary Puppeteer
#             uses for headless work. The same DevTools surface (navigation,
#             screenshots, input, viewport, PDF, dialogs, console and network),
#             151 MB smaller on disk and 65 MB smaller as a layer, and quicker to
#             start. It is a pinned blob with no distribution patches, so
#             CHROME_HEADLESS_SHELL_VERSION has to be bumped by hand; Renovate
#             does not track it. That is the trade: 65 MB against a browser that
#             stops receiving Debian's security updates.
#
# CHROMIUM_FLAVOR=debian is the default, so the switch has no effect until it is
# set, and going back is one build argument rather than a revert.
#
# lsof and ps are only used for the extension's optional development-server
# discovery, but the extension declares them in its service permissions, so
# they have to exist for the grant to be honoured.
ARG CHROMIUM_FLAVOR=debian
ARG CHROME_HEADLESS_SHELL_VERSION=155.0.8059.79
ARG CHROME_HEADLESS_SHELL_SHA256=72d938cabad9674610939c72ef2d3faf20214a4418c3b4e94c1cebca683e767b

RUN apt-get update && apt-get install -y --no-install-recommends \
  lsof \
  procps \
  $(if [ "$CHROMIUM_FLAVOR" = "cft-shell" ]; then \
      echo ca-certificates fonts-liberation libasound2 libatk-bridge2.0-0 libatk1.0-0 \
        libatspi2.0-0 libcairo2 libcups2 libdbus-1-3 libexpat1 libgbm1 libglib2.0-0 \
        libgtk-3-0 libnspr4 libnss3 libpango-1.0-0 libudev1 libvulkan1 libx11-6 \
        libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2; \
    else \
      echo chromium chromium-common chromium-sandbox; \
    fi) \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /opt/browser \
  && if [ "$CHROMIUM_FLAVOR" = "cft-shell" ]; then \
       case "$(dpkg --print-architecture)" in \
         arm64) CFT_PLATFORM=linux-arm64 ;; \
         amd64) CFT_PLATFORM=linux64 ;; \
         *) echo "no chrome-headless-shell build for $(dpkg --print-architecture)" >&2; exit 1 ;; \
       esac \
       && curl -fsSL -o /tmp/chrome-headless-shell.zip \
         "https://storage.googleapis.com/chrome-for-testing-public/${CHROME_HEADLESS_SHELL_VERSION}/${CFT_PLATFORM}/chrome-headless-shell-${CFT_PLATFORM}.zip" \
       && echo "${CHROME_HEADLESS_SHELL_SHA256}  /tmp/chrome-headless-shell.zip" | sha256sum -c - \
       && python3 -c "import zipfile; zipfile.ZipFile('/tmp/chrome-headless-shell.zip').extractall('/tmp/chs')" \
       && mv /tmp/chs/chrome-headless-shell-${CFT_PLATFORM}/* /opt/browser/ \
       && rm -rf /tmp/chs /tmp/chrome-headless-shell.zip \
       && find /opt/browser/locales -type f ! -name 'en-US.pak' -delete \
       && ln -sf /opt/browser/chrome-headless-shell /opt/browser/chrome; \
     else \
       ln -sf /usr/bin/chromium /opt/browser/chrome \
       && test -u /usr/lib/chromium/chrome-sandbox; \
     fi \
  && /opt/browser/chrome --version

# A wrapper for the Server Browser extension to find on PATH.
#
# The extension looks the browser up under the names google-chrome,
# google-chrome-stable, chromium and chromium-browser, walking PATH in order,
# and it starts the browser without a sandbox flag. This container blocks
# unprivileged user namespaces, so Chromium's namespace sandbox cannot start
# and the browser aborts during startup with SIGABRT.
#
# /usr/local/bin comes before /usr/bin in PATH, so this wrapper is the
# chromium the extension resolves.
#
# The wrapper decides at start up whether the browser can use its own sandbox.
# Chromium's namespace sandbox needs to create an unprivileged user namespace,
# which Docker's default seccomp profile blocks. The container is the
# isolation boundary in that case. When the profile allows the namespace, the
# browser keeps its own sandbox, which holds a hostile page inside the
# browser instead of only inside the container.
#
# The browser is started here rather than exec'd, so that a browser which
# still cannot start with its own sandbox is started again without one. The
# browser never stays in a state where it is running without a sandbox
# because the sandbox was assumed to work.
RUN <<'RUN_EOF'
cat > /usr/local/bin/chromium <<'WRAPPER_EOF'
#!/bin/sh
# Start the real browser, with its own sandbox when the container allows it.
# /opt/browser/chrome is whichever flavour the image installed.
BROWSER=/opt/browser/chrome

if ! unshare -U true >/dev/null 2>&1; then
  exec "$BROWSER" --no-sandbox "$@"
fi

"$BROWSER" "$@" &
browser_pid=$!

# The browser writes its DevTools port file within a second of starting, so
# a browser that is still alive after two seconds has started. One that is
# gone could not use the sandbox.
sleep 2
if kill -0 "$browser_pid" 2>/dev/null; then
  wait "$browser_pid"
  exit $?
fi

exec "$BROWSER" --no-sandbox "$@"
WRAPPER_EOF
chmod 0755 /usr/local/bin/chromium
RUN_EOF
RUN /usr/local/bin/chromium --version

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

# The OpenCode CLI and the other global tools live under the runtime user's own
# prefix, so every path they write to is owned by uid 1000.
ENV NPM_CONFIG_PREFIX=/home/openchamber/.npm-global
ENV PATH=${NPM_CONFIG_PREFIX}/bin:${PATH}

USER openchamber
RUN npm config set prefix /home/openchamber/.npm-global && mkdir -p /home/openchamber/.npm-global && \
  mkdir -p \
    /home/openchamber/.local/share/opencode \
    /home/openchamber/.local/state/opencode \
    /home/openchamber/.config/openchamber \
    /home/openchamber/.config/opencode \
    /home/openchamber/.ssh \
    /home/openchamber/workspaces && \
  npm install -g @opencode/cli@2.1.3

# The MCP servers that every workspace shares are installed once into the
# persistent volume rather than carried in the image.
#
# OpenCode opens one MCP connection per project location, so a local MCP
# server runs once per location. These three are the same for every location,
# so they are installed once and shared.
#
# The image keeps a compressed copy of each install. The entry point unpacks
# them into the volume when they are missing, and the launcher in front of
# each server unpacks it again if the volume was ever emptied. Nothing here
# needs the network, so a start up never waits on a package registry.
#
# The Python venvs are built at the path they will live at. A venv records its
# own absolute path in the shebang of every script inside it, so an install
# that is built somewhere else and moved would not start.
ARG ANALYTICS_MCP_VERSION=0.7.0
ARG MARKITDOWN_MCP_VERSION=0.0.1a8
ARG SUPERGATEWAY_VERSION=4.2.0
RUN mkdir -p /home/openchamber/.mcp-vendor \
  && mkdir -p /home/openchamber/.config/opencode/vendor \
  && uv venv /home/openchamber/.config/opencode/vendor/analytics-mcp --python /usr/bin/python3.13 \
  && uv pip install --python /home/openchamber/.config/opencode/vendor/analytics-mcp/bin/python "analytics-mcp==${ANALYTICS_MCP_VERSION:?unset}" \
  && uv venv /home/openchamber/.config/opencode/vendor/markitdown --python /usr/bin/python3.13 \
  && uv pip install --python /home/openchamber/.config/opencode/vendor/markitdown/bin/python "markitdown-mcp==${MARKITDOWN_MCP_VERSION:?unset}" \
  && npm install --prefix /home/openchamber/.config/opencode/vendor/supergateway "supergateway@${SUPERGATEWAY_VERSION:?unset}" \
  && mkdir -p /home/openchamber/.config/opencode/vendor/supergateway/bin \
  && ln -sf ../node_modules/.bin/supergateway /home/openchamber/.config/opencode/vendor/supergateway/bin/supergateway \
  && test -x /home/openchamber/.config/opencode/vendor/analytics-mcp/bin/analytics-mcp \
  && test -x /home/openchamber/.config/opencode/vendor/markitdown/bin/markitdown-mcp \
  && test -x /home/openchamber/.config/opencode/vendor/supergateway/bin/supergateway \
  && /home/openchamber/.config/opencode/vendor/supergateway/bin/supergateway --version \
  && tar czf /home/openchamber/.mcp-vendor/analytics-mcp.tar.gz -C /home/openchamber/.config/opencode/vendor analytics-mcp \
  && tar czf /home/openchamber/.mcp-vendor/markitdown.tar.gz -C /home/openchamber/.config/opencode/vendor markitdown \
  && tar czf /home/openchamber/.mcp-vendor/supergateway.tar.gz -C /home/openchamber/.config/opencode/vendor supergateway \
  && rm -rf /home/openchamber/.config/opencode/vendor/analytics-mcp \
              /home/openchamber/.config/opencode/vendor/markitdown \
              /home/openchamber/.config/opencode/vendor/supergateway \
  && test -f /home/openchamber/.mcp-vendor/analytics-mcp.tar.gz \
  && test -f /home/openchamber/.mcp-vendor/markitdown.tar.gz \
  && test -f /home/openchamber/.mcp-vendor/supergateway.tar.gz

# cloudflared 2026.3.0 - update digest explicitly when upgrading
COPY --from=cloudflare/cloudflared@sha256:6d91c121b803126f7a5344005d17a9324788fc09d305b6e2560ec6040a7ae283 /usr/local/bin/cloudflared /usr/local/bin/cloudflared

ENV NODE_ENV=production
# The base image ships with the POSIX locale, which makes bash readline treat
# every byte of a multibyte character separately in the built-in terminal.
ENV LANG=C.UTF-8

COPY scripts/docker-entrypoint.sh /home/openchamber/openchamber-entrypoint.sh

COPY --from=prod-deps --chown=openchamber:openchamber /app/node_modules ./node_modules
COPY --from=prod-deps --chown=openchamber:openchamber /app/packages/web/node_modules ./packages/web/node_modules
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
