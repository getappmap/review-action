#!/usr/bin/env bash
# Publish a PR movie: upload the video and podcast where people can play them,
# then post or update one sticky PR comment with Watch, Listen and Read.
#
# Storage, in order of preference:
#   MOVIE_BUCKET set   -> aws s3 cp to s3://$MOVIE_BUCKET/<repo>/pr-<n>/, linked
#                         through MOVIE_BASE_URL (plays in the browser)
#   otherwise          -> assets on a "pr-movies" pre-release in this repo
#                         (clicking downloads instead of playing)
set -euo pipefail

: "${MOVIE_DIR:?MOVIE_DIR is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${SKILLS_DIR:?SKILLS_DIR is required}"
export GITHUB_TOKEN GH_TOKEN="$GITHUB_TOKEN"

[[ -s "$MOVIE_DIR/movie.json" ]] || { echo "error: $MOVIE_DIR/movie.json is missing" >&2; exit 1; }

pr="${PR_NUMBER:-}"
if [[ -z "$pr" && -f "${GITHUB_EVENT_PATH:-}" ]]; then
  pr="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
fi
[[ -n "$pr" ]] || { echo "No pull request for this run; nothing to publish."; exit 0; }

repo="$GITHUB_REPOSITORY"
sha="${HEAD_REVISION:-$GITHUB_SHA}"
short="${sha:0:7}"

# Podcast as MP3 and as an inline-playable MP4 over the diagram.
if [[ -s "$MOVIE_DIR/podcast.m4a" ]]; then
  "$SKILLS_DIR/appmap-pr-movie/assets/podcast.sh" "$MOVIE_DIR"
fi

declare -A url=()
upload() { # <local file> <key>
  local file="$1" name="pr-${pr}-${short}-$2"
  [[ -s "$file" ]] || return 0
  if [[ -n "${MOVIE_BUCKET:-}" ]]; then
    : "${MOVIE_BASE_URL:?MOVIE_BASE_URL is required with MOVIE_BUCKET}"
    aws s3 cp --only-show-errors "$file" "s3://${MOVIE_BUCKET}/${repo}/${name}"
    url[$2]="${MOVIE_BASE_URL%/}/${repo}/${name}"
  else
    local tag="pr-movies"
    gh release view "$tag" -R "$repo" >/dev/null 2>&1 \
      || gh release create "$tag" -R "$repo" --prerelease --title "PR movies" \
           --notes "Summaries of pull requests, made by appmap-pr-movie." >/dev/null
    cp "$file" "${RUNNER_TEMP:-/tmp}/$name"
    gh release upload "$tag" -R "$repo" --clobber "${RUNNER_TEMP:-/tmp}/$name" >/dev/null
    url[$2]="https://github.com/${repo}/releases/download/${tag}/${name}"
  fi
}

upload "$MOVIE_DIR/movie.mp4"   movie.mp4
upload "$MOVIE_DIR/podcast.mp4" podcast.mp4
upload "$MOVIE_DIR/podcast.mp3" podcast.mp3
upload "$MOVIE_DIR/poster.png"  poster.png

listen="${url[podcast.mp4]:-${url[podcast.mp3]:-}}"
body="$(mktemp)"
node "$SKILLS_DIR/appmap-pr-movie/assets/comment.mjs" "$MOVIE_DIR" \
  "${url[movie.mp4]:-}" "$listen" "${url[poster.png]:-}" > "$body"

[[ -n "${GITHUB_STEP_SUMMARY:-}" ]] && cat "$body" >> "$GITHUB_STEP_SUMMARY"

MARKER="<!-- appmap-pr-movie -->"
existing="$(gh api "repos/${repo}/issues/${pr}/comments" --paginate \
  --jq "map(select(.body | contains(\"${MARKER}\"))) | .[0].id // empty" 2>/dev/null || true)"
if [[ -n "$existing" ]]; then
  gh api -X PATCH "repos/${repo}/issues/comments/${existing}" -F body=@"$body" >/dev/null
  echo "Updated the PR movie comment (#${existing})."
else
  gh api -X POST "repos/${repo}/issues/${pr}/comments" -F body=@"$body" >/dev/null
  echo "Posted the PR movie comment on PR #${pr}."
fi
