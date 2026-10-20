#!/usr/bin/env sh
# Disable the upstream GitHub Actions workflows in this fork.
#
# Why: each of these authenticates with upstream's GitHub App
# (OC_REVIEW_APP_ID / OC_REVIEW_APP_PRIVATE_KEY) or another upstream-only
# secret. This fork has none of them, so every run dies at the token step
# with "The 'client-id' (or deprecated 'app-id') input must be set to a
# non-empty string" and burns runner minutes for nothing.
#
# This fork's own CI is CircleCI (.circleci/config.yml) -> DockerHub -> Coolify.
# The CircleCI image build is unaffected by anything here.
#
# Usage:
#   .fork/disable-upstream-workflows.sh            # remove them from .github/workflows/
#   .fork/disable-upstream-workflows.sh --restore  # bring them back from upstream
#
# Re-run this after every upstream sync. `git reset --hard <upstream tag>`
# restores the workflow files because upstream owns them; the fork only owns
# the deletion.
set -eu

WORKFLOWS="
bot-help.yml
bot-summarize.yml
issue-intake.yml
label-merge-conflict.yml
nix-hashes.yml
oc-integration.yml
opencode.yml
pr-intake.yml
pr-review.yml
stale.yml
"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "${1:-}" = "--restore" ]; then
  for wf in $WORKFLOWS; do
    if git cat-file -e "upstream/main:.github/workflows/$wf" 2>/dev/null; then
      git checkout upstream/main -- ".github/workflows/$wf"
      echo "restored .github/workflows/$wf"
    else
      echo "skip $wf (not present upstream)"
    fi
  done
  exit 0
fi

for wf in $WORKFLOWS; do
  if [ -f ".github/workflows/$wf" ]; then
    git rm -f --quiet ".github/workflows/$wf"
    echo "disabled .github/workflows/$wf"
  else
    echo "skip $wf (already disabled)"
  fi
done
