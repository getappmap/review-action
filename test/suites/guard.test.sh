#!/usr/bin/env bash
# guard.sh: skip only when HEAD is our own gold-traces commit.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SUITE_DIR/.." && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assert.sh"

echo "== guard.sh =="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Make a repo whose HEAD commit has the given author name and subject.
make_repo() { # dir author subject
  local dir="$1" author="$2" subject="$3"
  mkdir -p "$dir"
  git -C "$dir" init -q
  echo x > "$dir/f"
  git -C "$dir" add -A
  GIT_AUTHOR_NAME="$author" GIT_AUTHOR_EMAIL="a@b.c" \
  GIT_COMMITTER_NAME="$author" GIT_COMMITTER_EMAIL="a@b.c" \
    git -C "$dir" commit -q -m "$subject"
}

run_guard() { # dir -> echoes skip value
  local dir="$1" out="$TMP/out"
  : > "$out"
  ( cd "$dir" && GITHUB_OUTPUT="$out" bash "$ROOT/scripts/guard.sh" >/dev/null 2>&1 )
  sed -n 's/^skip=//p' "$out"
}

make_repo "$TMP/human" "Alice Dev" "feat: something"
assert_eq "false" "$(run_guard "$TMP/human")" "human commit -> skip=false"

make_repo "$TMP/ours" "github-actions[bot]" "chore(gold-traces): update behavioral baseline [skip ci]"
assert_eq "true" "$(run_guard "$TMP/ours")" "our gold-traces commit -> skip=true"

make_repo "$TMP/bot-other" "github-actions[bot]" "fix: unrelated bot commit"
assert_eq "false" "$(run_guard "$TMP/bot-other")" "bot commit, other subject -> skip=false"

finish
