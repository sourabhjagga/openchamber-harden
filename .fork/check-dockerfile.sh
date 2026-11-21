#!/usr/bin/env sh
# Fail loudly when the image build stops guaranteeing a modern Node.
#
# `.fork/check-node-version.mjs` runs inside the build, but it only helps while
# the Dockerfile actually copies Node from the official image and still invokes
# the guard. An upstream merge can silently drop either half; this script checks
# the markers and is run by CircleCI before the build and by the upstream sync
# job before it pushes, so a merge that loses them fails instead of shipping a
# stale Node.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DOCKERFILE="$ROOT_DIR/Dockerfile"
failures=0

fail() {
  printf '[dockerfile-check] FAIL: %s\n' "$1" >&2
  failures=$((failures + 1))
}

[ -f "$DOCKERFILE" ] || {
  echo "[dockerfile-check] FAIL: Dockerfile not found" >&2
  exit 1
}

grep -q '^ARG NODE_VERSION=' "$DOCKERFILE" || fail 'ARG NODE_VERSION is missing'

grep -q 'FROM node:\${NODE_VERSION}-bookworm-slim AS node-dist' "$DOCKERFILE" \
  || fail 'the official Node stage (FROM node:${NODE_VERSION}-bookworm-slim AS node-dist) is missing'

grep -q 'COPY --from=node-dist /usr/local/bin/node /usr/local/bin/node' "$DOCKERFILE" \
  || fail 'Node is not copied from the official node image'

grep -q 'COPY --from=node-dist /usr/local/lib/node_modules/npm /usr/local/lib/node_modules/npm' "$DOCKERFILE" \
  || fail 'npm is not copied from the official node image'

grep -q 'check-node-version.mjs' "$DOCKERFILE" \
  || fail 'the build-time Node guard (check-node-version.mjs) is not run'

# Debian's nodejs package is the original bug: it is always behind the app's
# engines.node. Catch a regression that puts it back into the apt list.
APT_BLOCK=$(awk '/apt-get install/{flag=1} flag{print} /rm -rf \/var\/lib\/apt\/lists/{flag=0}' "$DOCKERFILE")
if printf '%s\n' "$APT_BLOCK" | grep -Eq '(^|[[:space:]])(nodejs|npm)([[:space:]\\]|$)'; then
  fail 'the apt list installs nodejs/npm again (Debian ships Node 20; copy from the node image instead)'
fi

if [ "$failures" -ne 0 ]; then
  printf '[dockerfile-check] %s check(s) failed; the image would not guarantee a modern Node\n' "$failures" >&2
  exit 1
fi

printf '[dockerfile-check] Dockerfile still installs Node from the official image and keeps the build guard\n'
