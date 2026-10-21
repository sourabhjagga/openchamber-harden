#!/usr/bin/env bash
# Trigger a Coolify deployment of the image that was just published, and roll
# back to the last good commit if that deployment fails.
#
# This runs on the deployment host, reached over SSH from the CircleCI job
# right after it pushes the image to DockerHub. The CircleCI job only pushes
# the image; this script is what asks Coolify to deploy it, so the deploy
# happens once per push instead of a watcher polling in the background.
#
# It is installed on the host as the forced command of a dedicated SSH key, so
# that key can do nothing except call this script.
#
# Exit codes:
#   0  the deployment finished successfully
#   1  the deployment failed (the rollback was attempted) or the trigger failed
#
# Environment (all have working defaults):
#   COOLIFY_URL                  default http://127.0.0.1:8000
#   COOLIFY_APPLICATION_UUID     the OpenChamber application
#   COOLIFY_TOKEN_FILE           the Coolify API token, read from disk
#   DEPLOY_TIMEOUT               seconds to wait for the deployment
#   POLL_INTERVAL                seconds between deployment status checks

set -uo pipefail

COOLIFY_URL="${COOLIFY_URL:-http://127.0.0.1:8000}"
APP_UUID="${COOLIFY_APPLICATION_UUID:-tstvi6x0rrptvet3jonr31ta}"
TOKEN_FILE="${COOLIFY_TOKEN_FILE:-/data/coolify/openchamber-deploy/api_token}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-1800}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

log() { echo "[oc-deploy] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*"; }

if [ ! -r "$TOKEN_FILE" ]; then
  log "ERROR: cannot read the Coolify token at $TOKEN_FILE"
  exit 1
fi
TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"

api() {
  local method="$1" path="$2" body="${3:-}"
  local args=(-sS --max-time 30 -X "$method"
              -H "Authorization: Bearer $TOKEN"
              -H "Accept: application/json")
  if [ -n "$body" ]; then
    args+=(-H "Content-Type: application/json" --data-binary "$body")
  fi
  curl "${args[@]}" "${COOLIFY_URL}${path}"
}

# The commit of the newest deployment that finished: the version to fall back
# to if the deployment we are about to start does not work out.
last_good_commit() {
  api GET "/api/v1/deployments/applications/${APP_UUID}" \
    | jq -r '[.deployments[] | select(.status == "finished" and .commit != null)][0].commit // empty'
}

ROLLBACK_COMMIT="$(last_good_commit)"
log "applying ${APP_UUID} (rollback target: ${ROLLBACK_COMMIT:-none})"

TRIGGER="$(api POST "/api/v1/applications/${APP_UUID}/start")"
DEPLOY_UUID="$(printf '%s' "$TRIGGER" | jq -r '.deployment_uuid // empty')"
if [ -z "$DEPLOY_UUID" ]; then
  log "ERROR: Coolify did not queue a deployment: ${TRIGGER:0:200}"
  exit 1
fi
log "deployment queued: ${DEPLOY_UUID}"

DEADLINE=$(( $(date +%s) + DEPLOY_TIMEOUT ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep "$POLL_INTERVAL"
  STATUS="$(api GET "/api/v1/deployments/${DEPLOY_UUID}" | jq -r '.status // "unknown"')"
  case "$STATUS" in
    finished)
      log "deployment ${DEPLOY_UUID} finished"
      exit 0
      ;;
    failed|cancelled)
      log "deployment ${DEPLOY_UUID} ${STATUS}, rolling back to ${ROLLBACK_COMMIT:-none}"
      if [ -n "$ROLLBACK_COMMIT" ]; then
        ROLLBACK="$(api POST "/api/v1/applications/${APP_UUID}/rollback" \
          "$(jq -nc --arg commit "$ROLLBACK_COMMIT" '{commit: $commit}')")"
        log "rollback queued: ${ROLLBACK:0:200}"
        log "production is back on the previous version; redeploy manually if that did not come up"
      else
        log "ERROR: no previous deployment to roll back to, production needs manual attention"
      fi
      exit 1
      ;;
    *)
      log "deployment ${DEPLOY_UUID} is ${STATUS}"
      ;;
  esac
done

log "ERROR: deployment ${DEPLOY_UUID} did not finish within ${DEPLOY_TIMEOUT}s"
exit 1
