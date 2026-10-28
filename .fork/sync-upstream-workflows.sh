#!/usr/bin/env sh
# Reconcile upstream's GitHub Actions workflows with what this fork needs.
#
# This fork ships a Docker image (CircleCI -> DockerHub -> Coolify). It does
# not publish npm packages, desktop builds, mobile builds, Nix packages, docs
# to the upstream website, or the VS Code extension, and it does not run
# upstream's PR/issue bots.
#
# Two kinds of upstream workflow do not belong here:
#
#   1. Workflows that authenticate with upstream's GitHub App
#      (OC_REVIEW_APP_ID / OC_REVIEW_APP_PRIVATE_KEY) or another upstream-only
#      secret. This fork has none of them, so every run dies at the token
#      step with "The 'client-id' (or deprecated 'app-id') input must be set
#      to a non-empty string".
#
#   2. Workflows that publish upstream artifacts (npm, macOS/Windows desktop
#      builds, mobile builds, the docs site, the VS Code extension) or that
#      only maintain upstream's Nix flake. Nothing in this fork consumes
#      those outputs.
#
# oc-review.yml is the one workflow worth keeping: it runs type-check, lint,
# tests and the build on pull requests, and it needs no secrets. Upstream
# schedules it on Blacksmith's hosted runners ("blacksmith-4vcpu-ubuntu-2404"),
# which are installed as a GitHub App on the openchamber org and therefore do
# not exist in this fork. The script repoints those jobs at ubuntu-latest so
# a pull request in this fork actually gets checked.
#
# Usage:
#   .fork/sync-upstream-workflows.sh            # apply to the working tree
#   .fork/sync-upstream-workflows.sh --restore  # restore from upstream/main
#
# Re-run this after every upstream sync. `git reset --hard <upstream tag>`
# restores the workflow files that upstream owns; the fork owns only the
# disable list and the runner repoint.
set -eu

# Upstream-only: GitHub App credentials, or upstream artifacts this fork
# never consumes. Removed from .github/workflows/.
DISABLED_WORKFLOWS="
bot-help.yml
bot-summarize.yml
build-macos-arm64-dmg.yml
docs-source.yml
issue-intake.yml
label-merge-conflict.yml
mobile-ci.yml
mobile-release.yml
nix-eval.yml
nix-hashes.yml
oc-integration.yml
opencode-smoke.yml
opencode.yml
pr-intake.yml
pr-review.yml
release-desktop-smoke.yml
release.yml
sdk-preview.yml
stale.yml
vscode-extension.yml
"

# Kept, with the hosted runner label repointed to a runner this fork has.
PATCHED_WORKFLOWS="
oc-review.yml
"

UPSTREAM_RUNNER="blacksmith-4vcpu-ubuntu-2404"
FORK_RUNNER="ubuntu-latest"

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

restore() {
  for wf in $DISABLED_WORKFLOWS $PATCHED_WORKFLOWS; do
    if git cat-file -e "upstream/main:.github/workflows/$wf" 2>/dev/null; then
      git checkout upstream/main -- ".github/workflows/$wf"
      echo "restored .github/workflows/$wf"
    else
      echo "skip $wf (not present upstream)"
    fi
  done
}

apply() {
  for wf in .github/workflows/*.yml; do
    [ -f "$wf" ] || continue
    name="$(basename "$wf")"
    case "$name" in
      upstream-sync.yml)
        # Fork-owned sync workflow, keep untouched
        ;;
      oc-review.yml)
        # Keep and repoint runner
        if grep -q "$UPSTREAM_RUNNER" "$wf"; then
          sed -i "s|$UPSTREAM_RUNNER|$FORK_RUNNER|g" "$wf"
          echo "repointed $name: $UPSTREAM_RUNNER -> $FORK_RUNNER"
        fi
        git add "$wf" 2>/dev/null || true
        ;;
      *)
        # All other upstream-only workflows (bots, desktop, mobile, nix, docs)
        git rm -f --quiet "$wf" 2>/dev/null || rm -f "$wf"
        echo "disabled $name"
        ;;
    esac
  done
}

case "${1:-}" in
  --restore) restore ;;
  *) apply ;;
esac
