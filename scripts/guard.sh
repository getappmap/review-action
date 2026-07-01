#!/usr/bin/env bash
# Re-trigger loop guard. Pushing gold-trace updates to the PR branch would re-fire
# the workflow; bail if HEAD is already one of our own gold-trace commits. Writes
# `skip=true|false` to $GITHUB_OUTPUT (or stdout when run outside Actions).
set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"

subject="$(git log -1 --pretty=%s 2>/dev/null || true)"
author="$(git log -1 --pretty=%an 2>/dev/null || true)"

if [[ "$author" == "github-actions[bot]" && "$subject" == chore\(gold-traces\):* ]]; then
  echo "HEAD is an action-authored gold-traces commit; skipping to avoid a re-trigger loop."
  echo "skip=true" >> "$out"
else
  echo "skip=false" >> "$out"
fi
