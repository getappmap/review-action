#!/usr/bin/env bash
# Publish the review report to the job summary and as a sticky PR comment.
set -euo pipefail

: "${REPORT_FILE:?REPORT_FILE is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"

if [[ ! -s "$REPORT_FILE" ]]; then
  echo "error: report file $REPORT_FILE is missing or empty" >&2
  exit 1
fi

# Optional agent-usage footer (written by usage.mjs report).
footer_file=""
if [[ -n "${USAGE_FOOTER:-}" && -s "${USAGE_FOOTER}" ]]; then
  footer_file="$USAGE_FOOTER"
fi

append_footer() { # <target-file>
  if [[ -n "$footer_file" ]]; then
    { printf '\n\n---\n\n'; cat "$footer_file"; } >> "$1"
  fi
}

# Job summary — always available.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  cat "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"
  append_footer "$GITHUB_STEP_SUMMARY"
fi

# PR comment — only when this run is associated with a pull request.
pr_number=""
if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]]; then
  pr_number="$(jq -r '.pull_request.number // .issue.number // empty' "$GITHUB_EVENT_PATH" 2>/dev/null || true)"
fi

if [[ -z "$pr_number" ]]; then
  echo "No pull request associated with this run; posted to job summary only."
  exit 0
fi

# Sticky comment: find our previous comment by a hidden marker and update it.
# COMMENT_TAG (optional) distinguishes comments when the action runs more than
# once per PR (e.g. a matrix): each distinct tag owns its own comment. "." means
# untagged — the default working-directory — so single-job callers keep the
# legacy marker and their existing comment.
tag="${COMMENT_TAG:-}"
if [[ "$tag" == "." ]]; then
  tag=""
fi
# Restrict to characters safe inside the HTML-comment marker and the jq filter.
tag="$(printf '%s' "$tag" | tr -cs 'A-Za-z0-9._/-' '-')"

if [[ -n "$tag" ]]; then
  MARKER="<!-- appmap-behavioral-review:${tag} -->"
else
  MARKER="<!-- appmap-behavioral-review -->"
fi
body_file="$(mktemp)"
{ printf '%s\n\n' "$MARKER"; cat "$REPORT_FILE"; } > "$body_file"
append_footer "$body_file"

repo="${GITHUB_REPOSITORY}"
export GITHUB_TOKEN

existing_id="$(gh api "repos/${repo}/issues/${pr_number}/comments" --paginate \
  --jq "map(select(.body | contains(\"${MARKER}\"))) | .[0].id // empty" 2>/dev/null || true)"

if [[ -n "$existing_id" ]]; then
  gh api -X PATCH "repos/${repo}/issues/comments/${existing_id}" \
    -F body=@"$body_file" >/dev/null
  echo "Updated existing review comment (#${existing_id})."
else
  gh api -X POST "repos/${repo}/issues/${pr_number}/comments" \
    -F body=@"$body_file" >/dev/null
  echo "Posted new review comment on PR #${pr_number}."
fi
