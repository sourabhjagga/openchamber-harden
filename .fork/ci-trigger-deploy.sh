#!/usr/bin/env bash
# Ask the deployment host to deploy the image that was just pushed.
#
# The host's SSH key for this job is restricted to a single forced command, so
# this script can only ever ask for a deployment. The command it sends is
# ignored by the server; the forced command runs instead.
#
# The host script exits non-zero when the deployment failed, and that exit
# code comes back through SSH, so the CircleCI job reports the failure even
# though the image itself was pushed successfully.
#
# Environment:
#   OC_DEPLOY_SSH_KEY   the private key for the restricted deploy key
#   OC_DEPLOY_HOST      the deployment host

set -euo pipefail

: "${OC_DEPLOY_SSH_KEY:?OC_DEPLOY_SSH_KEY is not set}"
: "${OC_DEPLOY_HOST:?OC_DEPLOY_HOST is not set}"

KEYFILE="$(mktemp)"
trap 'rm -f "$KEYFILE"' EXIT
printf '%s\n' "$OC_DEPLOY_SSH_KEY" > "$KEYFILE"
chmod 600 "$KEYFILE"

echo "[ci-trigger-deploy] asking ${OC_DEPLOY_HOST} to deploy"
ssh -i "$KEYFILE" \
    -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=15 \
    -o LogLevel=ERROR \
    "ubuntu@${OC_DEPLOY_HOST}" 'true'
echo "[ci-trigger-deploy] host finished the deployment request"
