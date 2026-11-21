#!/usr/bin/env sh
# Keep `ARG NODE_VERSION` in the Dockerfile aligned with engines.node.
#
# The upstream sync job merges a new release, which may raise the Node
# requirement (`.nvmrc` / `engines.node`). CircleCI derives the real build
# argument on every build, so the image itself is always correct; this script
# keeps the Dockerfile's default correct too, for local `docker build .` runs
# and for anyone reading the file.
#
# Prints nothing; exits non-zero only when the Dockerfile has no ARG to update.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOCKERFILE="$ROOT_DIR/Dockerfile"
MAJOR=$(sh "$ROOT_DIR/.fork/resolve-node-version.sh")

if [ ! -f "$DOCKERFILE" ]; then
  echo '[reconcile-node] Dockerfile not found' >&2
  exit 1
fi

CURRENT=$(sed -n 's/^ARG NODE_VERSION=\([0-9][0-9]*\).*/\1/p' "$DOCKERFILE" | head -n 1)
if [ -z "$CURRENT" ]; then
  echo '[reconcile-node] Dockerfile has no ARG NODE_VERSION=<major> line' >&2
  exit 1
fi

if [ "$CURRENT" = "$MAJOR" ]; then
  echo "[reconcile-node] ARG NODE_VERSION=$CURRENT already matches engines.node" >&2
  exit 0
fi

# BSD and GNU sed both accept this in-place form without a backup suffix.
sed -i.bak "s/^ARG NODE_VERSION=.*/ARG NODE_VERSION=$MAJOR/" "$DOCKERFILE"
rm -f "$DOCKERFILE.bak"
echo "[reconcile-node] ARG NODE_VERSION $CURRENT -> $MAJOR (from engines.node)" >&2
