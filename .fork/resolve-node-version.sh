#!/usr/bin/env sh
# Print the Node major that this image must be built with.
#
# The requirement lives in the repository, not in the CI config:
#   - `engines.node` in the root package.json and in every packages/*/package.json
#   - `.nvmrc` (a hint; `lts/<codename>` is mapped below)
#
# CircleCI runs this before `docker build` and passes the result as
# `--build-arg NODE_VERSION=<major>`, so a new upstream release that raises the
# requirement changes the image without anyone editing the Dockerfile.
#
# Output: a single line, the major version (for example `24`).
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT_DIR"

# Every `"node": ">=<major>..."` floor across the workspace.
FLOORS=$(
  for file in package.json packages/*/package.json; do
    [ -f "$file" ] || continue
    # printf keeps each match on its own line even when the file has no
    # trailing newline (two files would otherwise concatenate into "2626").
    printf '%s\n' "$(sed -n 's/.*"node"[[:space:]]*:[[:space:]]*">=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$file")"
  done | grep -E '^[0-9]+$' | sort -n | tail -n 1
)

if [ -z "$FLOORS" ]; then
  echo "resolve-node-version: no engines.node floor found" >&2
  exit 1
fi

# .nvmrc is a hint: `lts/<codename>` and bare versions both appear upstream.
NVMRC_MAJOR=0
if [ -f .nvmrc ]; then
  NVMRC=$(tr -d ' \t\r\n' < .nvmrc)
  case "$NVMRC" in
    lts/*)
      codename=$(printf '%s' "$NVMRC" | cut -d/ -f2 | tr '[:upper:]' '[:lower:]')
      case "$codename" in
        krypton) NVMRC_MAJOR=24 ;;
        jod) NVMRC_MAJOR=22 ;;
        iron) NVMRC_MAJOR=20 ;;
        *) NVMRC_MAJOR=0 ;;
      esac
      ;;
    [0-9]*)
      NVMRC_MAJOR=$(printf '%s' "$NVMRC" | cut -d. -f1)
      ;;
  esac
fi

if [ "$NVMRC_MAJOR" -gt "$FLOORS" ] 2>/dev/null; then
  printf '%s\n' "$NVMRC_MAJOR"
else
  printf '%s\n' "$FLOORS"
fi
