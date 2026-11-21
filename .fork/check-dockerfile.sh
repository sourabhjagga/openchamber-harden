#!/usr/bin/env sh
# Fail loudly when the image build stops guaranteeing the tool versions the
# repository declares.
#
# These invariants survive upstream merges only if something checks them:
#   - Node comes from the official image and its version satisfies engines.node
#     (the build runs `.fork/check-node-version.mjs` as a second net).
#   - The Bun base image matches the `packageManager` field.
#   - The `@opencode/cli` pin matches `@opencode/client` (they are released as a
#     pair; a mismatch breaks the server/CLI protocol).
#   - uv/uvx and Chromium (the Python MCP runner and the Server Browser) are
#     still baked into the runtime stage.
#
# CircleCI runs this before `docker build`, and the upstream sync job runs it
# before pushing, so a merge that drops or skews one of these fails instead of
# shipping.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOCKERFILE="$ROOT_DIR/Dockerfile"
PACKAGE_JSON="$ROOT_DIR/package.json"

failures=0

fail() {
  printf '[dockerfile-check] FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

[ -f "$DOCKERFILE" ] || {
  echo "[dockerfile-check] FAIL: Dockerfile not found" >&2
  exit 1
}
[ -f "$PACKAGE_JSON" ] || {
  echo "[dockerfile-check] FAIL: package.json not found" >&2
  exit 1
}

# --- Node -------------------------------------------------------------------
grep -q '^ARG NODE_VERSION=' "$DOCKERFILE" || fail 'ARG NODE_VERSION is missing'

grep -q 'FROM node:\${NODE_VERSION}-bookworm-slim AS node-dist' "$DOCKERFILE" \
  || fail 'the official Node stage (FROM node:${NODE_VERSION}-bookworm-slim AS node-dist) is missing'

grep -q 'COPY --from=node-dist /usr/local/bin/node /usr/local/bin/node' "$DOCKERFILE" \
  || fail 'Node is not copied from the official node image'

grep -q 'COPY --from=node-dist /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm' "$DOCKERFILE" \
  || fail 'npm is not copied from the official node image'

grep -q 'check-node-version.mjs' "$DOCKERFILE" \
  || fail 'the build-time Node guard (check-node-version.mjs) is not run'

# The ARG default is what a manual `docker build .` uses; keep it in step with
# the resolver (.fork/node-major, engines.node, .nvmrc).
EXPECTED_NODE=$(sh "$ROOT_DIR/.fork/resolve-node-version.sh")
ARG_NODE=$(sed -n 's/^ARG NODE_VERSION=\([0-9][0-9]*\).*/\1/p' "$DOCKERFILE" | head -n 1)
if [ -z "$ARG_NODE" ]; then
  fail 'ARG NODE_VERSION has no numeric default'
elif [ "$ARG_NODE" != "$EXPECTED_NODE" ]; then
  fail "ARG NODE_VERSION=$ARG_NODE but the resolver says $EXPECTED_NODE (run .fork/reconcile-tool-versions.sh)"
fi

# Debian's nodejs package is the original bug: it is always behind the app's
# engines.node. Catch a regression that puts it back into the apt list.
APT_BLOCK=$(awk '/apt-get install/{flag=1} flag{print} /rm -rf \/var\/lib\/apt\/lists/{flag=0}' "$DOCKERFILE")
if printf '%s\n' "$APT_BLOCK" | grep -Eq '(^|[[:space:]])(nodejs|npm)([[:space:]\\]|$)'; then
  fail 'the apt list installs nodejs/npm again (Debian ships Node 20; copy from the node image instead)'
fi

# --- Bun base image vs packageManager --------------------------------------
BUN_TAGS=$(sed -n 's/^FROM oven\/bun:\([0-9][0-9.]*\).*/\1/p' "$DOCKERFILE" | sort -u)
BUN_TAG_COUNT=$(printf '%s\n' "$BUN_TAGS" | grep -c . || true)
PACKAGE_MANAGER=$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"bun@\([0-9][0-9.]*\)".*/\1/p' "$PACKAGE_JSON" | head -n 1)
if [ "$BUN_TAG_COUNT" -ne 1 ]; then
  fail "expected one oven/bun tag in the Dockerfile, found ${BUN_TAG_COUNT:-0} (${BUN_TAGS:-none})"
elif [ -z "$PACKAGE_MANAGER" ]; then
  fail 'package.json has no "packageManager": "bun@<version>"'
elif [ "$BUN_TAGS" != "$PACKAGE_MANAGER" ]; then
  fail "oven/bun:${BUN_TAGS} does not match packageManager bun@${PACKAGE_MANAGER}"
fi

# --- OpenCode CLI pin vs @opencode/client ----------------------------------
CLI_PIN=$(sed -n 's/.*@opencode\/cli@\([0-9][0-9.]*\).*/\1/p' "$DOCKERFILE" | head -n 1)
CLIENT_PIN=$(sed -n 's/.*"@opencode\/client"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$PACKAGE_JSON" | head -n 1)
if [ -z "$CLI_PIN" ]; then
  fail 'the Dockerfile has no @opencode/cli@<version> pin'
elif [ -z "$CLIENT_PIN" ]; then
  fail 'package.json has no "@opencode/client": "<version>"'
elif [ "$CLI_PIN" != "$CLIENT_PIN" ]; then
  fail "@opencode/cli@${CLI_PIN} does not match @opencode/client ${CLIENT_PIN}"
fi

# --- Python MCP runner (uv/uvx) --------------------------------------------
grep -q '^ARG UV_VERSION=' "$DOCKERFILE" || fail 'ARG UV_VERSION is missing'
grep -q 'FROM ghcr.io/astral-sh/uv:\${UV_VERSION}' "$DOCKERFILE" \
  || fail 'the uv image stage is missing'
grep -q 'COPY --from=uv-dist /uv /uvx /usr/local/bin/' "$DOCKERFILE" \
  || fail 'uv/uvx are not copied into the image'
grep -q 'uvx --version' "$DOCKERFILE" \
  || fail 'the build does not verify uvx'

# --- Headless Chromium (Server Browser) ------------------------------------
if printf '%s\n' "$APT_BLOCK" | grep -Eq '(^|[[:space:]])chromium([[:space:]\\]|$)'; then
  :
else
  fail 'the apt list no longer installs chromium'
fi
grep -q 'ln -sf /usr/lib/chromium/chromium /opt/browser/chrome' "$DOCKERFILE" \
  || fail '/opt/browser/chrome is not linked to the Debian chromium binary'
grep -q '/usr/local/bin/chromium' "$DOCKERFILE" \
  || fail 'the /usr/local/bin/chromium wrapper is missing'

if [ "$failures" -ne 0 ]; then
  printf '[dockerfile-check] %s check(s) failed; the image would not match the declared tool versions\n' "$failures" >&2
  exit 1
fi

printf '[dockerfile-check] Node, Bun, OpenCode CLI, uv/uvx and Chromium all match the repository\n'
