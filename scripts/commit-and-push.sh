#!/usr/bin/env bash
# Commit everything the gold-traces agent changed and push it to the PR head branch.
#
# Per the action's design, the agent may change more than just the baselines
# (config, added AppMap labels in source, new gold tests). We commit ALL of it so
# nothing the agent did is lost or left as a manual translation chore for the user;
# if the user dislikes the changes, they revert/adjust them and re-run.
set -euo pipefail

: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
COMMIT_MESSAGE="${COMMIT_MESSAGE:-chore(gold-traces): update behavioral baseline}"

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

# Nothing to do if the agent produced no changes.
if [[ -z "$(git status --porcelain)" ]]; then
  echo "No gold-trace changes to commit."
  echo "updated=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

git add -A
# `[skip ci]` is the primary loop-break; the action's HEAD guard is the backstop.
git commit -m "${COMMIT_MESSAGE} [skip ci]"

# Resolve the branch to push to. On pull_request runs HEAD is detached, so use the
# PR head ref; otherwise use the current branch.
branch="${GITHUB_HEAD_REF:-}"
if [[ -z "$branch" ]]; then
  branch="$(git rev-parse --abbrev-ref HEAD)"
fi

origin_url="$(git remote get-url origin)"
# Push with an explicit token-authenticated URL; strip any existing credentials.
host_path="${origin_url#https://}"
host_path="${host_path#*@}"
authed_url="https://x-access-token:${GITHUB_TOKEN}@${host_path}"

git push "$authed_url" "HEAD:refs/heads/${branch}"
echo "Pushed gold-trace updates to ${branch}."
echo "updated=true" >> "$GITHUB_OUTPUT"
