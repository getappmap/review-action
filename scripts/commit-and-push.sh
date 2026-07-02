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
if [[ "$origin_url" == https://* ]]; then
  # Push with an explicit token-authenticated URL; strip any existing credentials.
  host_path="${origin_url#https://}"
  host_path="${host_path#*@}"
  push_target="https://x-access-token:${GITHUB_TOKEN}@${host_path}"
else
  # Non-https remote (e.g. ssh, or a file:// remote in tests): push to it as-is.
  push_target="origin"
fi

# Resilient push: the PR branch has multiple concurrent writers — the matrix
# legs (one per package), overlapping runs, and other agents. On rejection,
# fetch the latest branch tip and rebase our commit onto it, then retry. Gold
# updates from different legs touch different files, so a rebase almost always
# applies cleanly; a genuine conflict aborts and fails loudly.
attempt=0
max_attempts=6
until git push "$push_target" "HEAD:refs/heads/${branch}"; do
  attempt=$((attempt + 1))
  if [[ $attempt -ge $max_attempts ]]; then
    echo "Push still rejected after ${attempt} attempts; giving up." >&2
    exit 1
  fi
  echo "Push rejected (attempt ${attempt}/${max_attempts}); fetching + rebasing onto ${branch}..."
  # Small jittered backoff so concurrent legs don't retry in lockstep.
  sleep "$(( (RANDOM % 5) + 1 ))"
  git fetch "$push_target" "$branch"
  if ! git rebase FETCH_HEAD; then
    git rebase --abort || true
    echo "Rebase onto ${branch} conflicted; cannot auto-resolve. Failing." >&2
    exit 1
  fi
done
echo "Pushed gold-trace updates to ${branch}."
echo "updated=true" >> "$GITHUB_OUTPUT"
