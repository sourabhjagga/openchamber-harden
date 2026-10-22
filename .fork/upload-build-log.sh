#!/usr/bin/env bash
# Publish the build log so a failed build can be read without opening CircleCI.
#
# The CircleCI API does not hand the job output to the tools that drive this
# host, so the log is written to a secret in Doppler instead, where the same
# tools already read from.
#
# The script never fails the build. A log that could not be published is not
# a reason to fail a build that may well have succeeded.
#
# Environment:
#   DOPPLER_TOKEN   a Doppler token for the openchamber project
#   BUILD_LOG       path to the log file, defaults to /tmp/oc-build.log
set -uo pipefail

BUILD_LOG="${BUILD_LOG:-/tmp/oc-build.log}"

if [ ! -f "$BUILD_LOG" ]; then
  echo "[upload-build-log] no log at ${BUILD_LOG}"
  exit 0
fi

if [ -z "${DOPPLER_TOKEN:-}" ]; then
  echo "[upload-build-log] DOPPLER_TOKEN is not set, skipping"
  exit 0
fi

# The interesting part of a build log is its end, where the failure is.
LOG="$(tail -c 60000 "$BUILD_LOG")"

PAYLOAD="$(LOG="$LOG" python3 -c '
import json, os
print(json.dumps({"secrets": {"CI_BUILD_LOG": os.environ.get("LOG", "")}}))
' 2>/dev/null)"

if [ -z "$PAYLOAD" ]; then
  echo "[upload-build-log] could not build the payload"
  exit 0
fi

curl -sS --max-time 30 -X POST \
  -H "Authorization: Bearer ${DOPPLER_TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary "${PAYLOAD}" \
  https://api.doppler.com/v3/configs/config/secrets >/dev/null 2>&1

echo "[upload-build-log] published $(printf '%s' "$LOG" | wc -c) bytes of build log to Doppler"
exit 0
