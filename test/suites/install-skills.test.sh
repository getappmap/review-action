#!/usr/bin/env bash
# install-skills.sh: clone the skills repo; for claude, symlink ONLY the used
# skills into ~/.claude/skills without clobbering existing dirs; for copilot,
# symlink nothing.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SUITE_DIR/.." && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assert.sh"

echo "== install-skills.sh =="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Build a local git repo to serve as SKILLS_REPO (clone target) from the fixture.
SKILLS_REPO="$TMP/skills.git"
cp -R "$TEST_DIR/fixtures/skills-src" "$SKILLS_REPO"
git -C "$SKILLS_REPO" init -q
git -C "$SKILLS_REPO" add -A
GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
  git -C "$SKILLS_REPO" commit -q -m "skills fixture"
# Ensure the default branch is named 'main' (SKILLS_REF default).
git -C "$SKILLS_REPO" branch -M main

run_install() { # agent home runner-temp
  AGENT="$1" HOME="$2" RUNNER_TEMP="$3" \
  SKILLS_REPO="$SKILLS_REPO" SKILLS_REF="main" \
    bash "$ROOT/scripts/install-skills.sh"
}

# --- claude: links used skills, skips the unused one ---
H1="$TMP/home1"; RT1="$TMP/rt1"; mkdir -p "$H1" "$RT1"
assert_ok "claude install runs" run_install claude "$H1" "$RT1"
for s in appmap-gold-traces appmap-review appmap-label appmap-record; do
  assert_symlink "$H1/.claude/skills/$s" "linked $s"
done
assert_no_file "$H1/.claude/skills/appmap-unused" "unused skill not linked"

# --- claude: pre-existing real dir is NOT clobbered ---
H2="$TMP/home2"; RT2="$TMP/rt2"; mkdir -p "$H2/.claude/skills/appmap-review" "$RT2"
echo "keep me" > "$H2/.claude/skills/appmap-review/mine.txt"
assert_ok "claude install with existing dir" run_install claude "$H2" "$RT2"
assert_file "$H2/.claude/skills/appmap-review/mine.txt" "existing real dir preserved"
# A symlink should NOT have replaced it.
[[ -L "$H2/.claude/skills/appmap-review" ]] && failed "existing dir was replaced by a symlink" \
  || pass "existing dir left as a directory (not a symlink)"

# --- copilot: no symlinks created, but skills are cloned ---
H3="$TMP/home3"; RT3="$TMP/rt3"; mkdir -p "$H3" "$RT3"
assert_ok "copilot install runs" run_install copilot "$H3" "$RT3"
assert_no_file "$H3/.claude/skills" "copilot creates no ~/.claude/skills"
assert_file "$RT3/getappmap-skills/appmap-review/SKILL.md" "copilot clone present in working dir"

finish
