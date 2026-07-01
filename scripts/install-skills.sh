#!/usr/bin/env bash
# Install the getappmap/skills the review-action uses.
#
# Clone the whole skills repo into a working directory, then symlink ONLY the
# skills this action uses into ~/.claude/skills. This avoids clobbering any other
# skills the runner (or a self-hosted environment) may already have there.
set -euo pipefail

: "${SKILLS_REPO:?SKILLS_REPO is required}"
: "${SKILLS_REF:?SKILLS_REF is required}"

# Skills this action drives directly, plus the ones they reference at runtime
# (appmap-review and appmap-gold-traces delegate labeling/recording to these).
USED_SKILLS=(appmap-gold-traces appmap-review appmap-label appmap-record)

WORKDIR="${RUNNER_TEMP:-/tmp}/getappmap-skills"
CLAUDE_SKILLS_DIR="${HOME}/.claude/skills"

rm -rf "$WORKDIR"
# Prefer a shallow clone of a branch/tag; fall back to a full clone + checkout so
# an arbitrary SHA in SKILLS_REF also works.
if git clone --depth 1 --branch "$SKILLS_REF" "$SKILLS_REPO" "$WORKDIR" 2>/dev/null; then
  :
else
  git clone "$SKILLS_REPO" "$WORKDIR"
  git -C "$WORKDIR" checkout "$SKILLS_REF"
fi

mkdir -p "$CLAUDE_SKILLS_DIR"

for skill in "${USED_SKILLS[@]}"; do
  src="$WORKDIR/$skill"
  if [[ ! -d "$src" ]]; then
    echo "warning: skill '$skill' not found in $SKILLS_REPO@$SKILLS_REF; skipping" >&2
    continue
  fi
  dest="$CLAUDE_SKILLS_DIR/$skill"
  # Replace only our own symlink; never delete a real directory we didn't create.
  if [[ -L "$dest" ]]; then
    rm -f "$dest"
  elif [[ -e "$dest" ]]; then
    echo "warning: $dest already exists and is not a symlink; leaving it in place" >&2
    continue
  fi
  ln -s "$src" "$dest"
  echo "linked $skill -> $src"
done
