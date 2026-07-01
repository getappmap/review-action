#!/usr/bin/env bash
# commit-and-push.sh: no-op when clean; otherwise stage everything, commit with
# [skip ci] as github-actions[bot], and push to origin (a local bare remote here).
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SUITE_DIR/.." && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assert.sh"

echo "== commit-and-push.sh =="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Bare remote + a working clone on branch main.
BARE="$TMP/remote.git"
git init -q --bare "$BARE"
REPO="$TMP/repo"
git clone -q "$BARE" "$REPO"
git -C "$REPO" config user.name seed
git -C "$REPO" config user.email seed@t
echo hello > "$REPO/README"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m "init"
git -C "$REPO" branch -M main
git -C "$REPO" push -q origin main

run_commit() { ( cd "$REPO" && GITHUB_TOKEN=dummy GITHUB_HEAD_REF=main \
  GITHUB_OUTPUT="$TMP/out" bash "$ROOT/scripts/commit-and-push.sh" ); }

# --- changes present: commit + push ---
: > "$TMP/out"
mkdir -p "$REPO/gold_traces/baseline/appmaps"
echo '{}' > "$REPO/gold_traces/baseline/appmaps/x.appmap.json"
assert_ok "commit-and-push with changes" run_commit
assert_contains "$(cat "$TMP/out")" "updated=true" "reports updated=true"

pushed_subject="$(git -C "$BARE" log -1 --pretty=%s main)"
pushed_author="$(git -C "$BARE" log -1 --pretty=%an main)"
assert_contains "$pushed_subject" "[skip ci]" "pushed commit carries [skip ci]"
assert_eq "github-actions[bot]" "$pushed_author" "pushed commit authored by the bot"
assert_contains "$(git -C "$BARE" ls-tree -r --name-only main)" \
  "gold_traces/baseline/appmaps/x.appmap.json" "gold traces landed on the remote"

# --- clean tree: no-op ---
: > "$TMP/out"
before="$(git -C "$BARE" rev-parse main)"
assert_ok "commit-and-push with no changes" run_commit
assert_contains "$(cat "$TMP/out")" "updated=false" "reports updated=false"
assert_eq "$before" "$(git -C "$BARE" rev-parse main)" "remote unchanged when clean"

finish
