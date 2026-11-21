#!/usr/bin/env sh
# Keep the Dockerfile's hardcoded versions aligned with the declarations that
# live in the repository:
#
#   - ARG NODE_VERSION      <- engines.node + .nvmrc + .fork/node-major
#   - FROM oven/bun:<tag>   <- package.json "packageManager": "bun@<version>"
#   - @opencode/cli@<ver>   <- package.json "@opencode/client"
#
# The upstream sync job runs this after every merge, so an upstream bump is
# applied to the Dockerfile instead of leaving it behind (a merge keeps the
# fork's Dockerfile on conflict). `.fork/check-dockerfile.sh` then verifies the
# result, and fails the sync before it can push a skewed image.
#
# Exits non-zero only when a declaration is missing from the repository.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOCKERFILE="$ROOT_DIR/Dockerfile"
PACKAGE_JSON="$ROOT_DIR/package.json"
changes=0

read_first() {
  sed -n "$1" "$2" | head -n 1
}

[ -f "$DOCKERFILE" ] || {
  echo '[reconcile] Dockerfile not found' >&2
  exit 1
}
[ -f "$PACKAGE_JSON" ] || {
  echo '[reconcile] package.json not found' >&2
  exit 1
}

# --- Node -------------------------------------------------------------------
NODE_MAJOR=$(sh "$ROOT_DIR/.fork/resolve-node-version.sh")
CURRENT_NODE=$(read_first 's/^ARG NODE_VERSION=\([0-9][0-9]*\).*/\1/p' "$DOCKERFILE")
if [ -z "$CURRENT_NODE" ]; then
  echo '[reconcile] Dockerfile has no ARG NODE_VERSION=<major> line' >&2
  exit 1
fi
if [ "$CURRENT_NODE" != "$NODE_MAJOR" ]; then
  sed -i.bak "s/^ARG NODE_VERSION=.*/ARG NODE_VERSION=$NODE_MAJOR/" "$DOCKERFILE"
  echo "[reconcile] ARG NODE_VERSION $CURRENT_NODE -> $NODE_MAJOR (engines.node/.fork/node-major)" >&2
  changes=$((changes + 1))
fi

# --- Bun base image ---------------------------------------------------------
BUN_VERSION=$(read_first 's/.*"packageManager"[[:space:]]*:[[:space:]]*"bun@\([0-9][0-9.]*\)".*/\1/p' "$PACKAGE_JSON")
if [ -z "$BUN_VERSION" ]; then
  echo '[reconcile] package.json has no "packageManager": "bun@<version>"' >&2
  exit 1
fi
CURRENT_BUN=$(read_first 's/^FROM oven\/bun:\([0-9][0-9.]*\).*/\1/p' "$DOCKERFILE")
if [ -z "$CURRENT_BUN" ]; then
  echo '[reconcile] Dockerfile has no FROM oven/bun:<version> line' >&2
  exit 1
fi
if [ "$CURRENT_BUN" != "$BUN_VERSION" ]; then
  sed -i.bak "s|^FROM oven/bun:[0-9][0-9.]*|FROM oven/bun:$BUN_VERSION|" "$DOCKERFILE"
  echo "[reconcile] oven/bun $CURRENT_BUN -> $BUN_VERSION (packageManager)" >&2
  changes=$((changes + 1))
fi

# --- OpenCode CLI pin -------------------------------------------------------
CLIENT_VERSION=$(read_first 's/.*"@opencode\/client"[[:space:]]*:[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$PACKAGE_JSON")
if [ -z "$CLIENT_VERSION" ]; then
  echo '[reconcile] package.json has no "@opencode/client": "<version>"' >&2
  exit 1
fi
CURRENT_CLI=$(read_first 's/.*@opencode\/cli@\([0-9][0-9.]*\).*/\1/p' "$DOCKERFILE")
if [ -z "$CURRENT_CLI" ]; then
  echo '[reconcile] Dockerfile has no @opencode/cli@<version> pin' >&2
  exit 1
fi
if [ "$CURRENT_CLI" != "$CLIENT_VERSION" ]; then
  sed -i.bak "s|@opencode/cli@[0-9][0-9.]*|@opencode/cli@$CLIENT_VERSION|g" "$DOCKERFILE"
  echo "[reconcile] @opencode/cli $CURRENT_CLI -> $CLIENT_VERSION (@opencode/client)" >&2
  changes=$((changes + 1))
fi

rm -f "$DOCKERFILE.bak"

if [ "$changes" -eq 0 ]; then
  echo '[reconcile] Dockerfile already matches the declared versions' >&2
fi
