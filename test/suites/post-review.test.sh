#!/usr/bin/env bash
# post-review.sh: always write the job summary; post a sticky PR comment only when
# the run is tied to a PR (create vs. update by marker). `gh` is mocked.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SUITE_DIR/.." && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assert.sh"

echo "== post-review.sh =="

if ! command -v jq >/dev/null 2>&1; then
  echo "  (skipped: jq not installed)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export PATH="$TEST_DIR/mocks:$PATH"

REPORT="$TMP/report.md"
printf '# Review\n\nBody line.\n' > "$REPORT"

run_post() { # event-json-file
  local summary="$TMP/summary"; : > "$summary"
  local ghlog="$TMP/ghlog"; : > "$ghlog"
  SUMMARY_OUT="$summary" GHLOG_OUT="$ghlog" \
  REPORT_FILE="$REPORT" GITHUB_TOKEN=x GITHUB_REPOSITORY="octo/repo" \
  GITHUB_STEP_SUMMARY="$summary" GITHUB_EVENT_PATH="$1" \
  COMMENT_TAG="${COMMENT_TAG:-}" \
  MOCK_GH_LOG="$ghlog" MOCK_GH_EXISTING_ID="${MOCK_GH_EXISTING_ID:-}" \
    bash "$ROOT/scripts/post-review.sh" >/dev/null 2>&1
}

# --- non-PR event: summary only, no gh calls ---
echo '{}' > "$TMP/push.json"
run_post "$TMP/push.json"
assert_contains "$(cat "$TMP/summary")" "Body line." "summary written on non-PR run"
assert_eq "" "$(cat "$TMP/ghlog")" "gh not called on non-PR run"

# --- PR event, no existing comment: POST ---
echo '{"pull_request":{"number":42}}' > "$TMP/pr.json"
MOCK_GH_EXISTING_ID="" run_post "$TMP/pr.json"
ghlog="$(cat "$TMP/ghlog")"
assert_contains "$ghlog" "issues/42/comments" "POST targets the PR comments endpoint"
assert_contains "$ghlog" "POST" "new comment uses POST"

# --- PR event, existing comment: PATCH by id ---
echo '{"pull_request":{"number":42}}' > "$TMP/pr.json"
MOCK_GH_EXISTING_ID="999" run_post "$TMP/pr.json"
ghlog="$(cat "$TMP/ghlog")"
assert_contains "$ghlog" "issues/comments/999" "PATCH targets the existing comment id"
assert_contains "$ghlog" "PATCH" "existing comment uses PATCH"

# --- comment tag: marker carries the tag, so each matrix entry owns a comment ---
MOCK_GH_EXISTING_ID="" COMMENT_TAG="services/web" run_post "$TMP/pr.json"
ghlog="$(cat "$TMP/ghlog")"
assert_contains "$ghlog" "<!-- appmap-behavioral-review:services/web -->" "tagged marker used for lookup"

# --- "." tag (working-directory default) means untagged: legacy marker ---
MOCK_GH_EXISTING_ID="" COMMENT_TAG="." run_post "$TMP/pr.json"
ghlog="$(cat "$TMP/ghlog")"
assert_contains "$ghlog" "<!-- appmap-behavioral-review -->" "dot tag falls back to legacy marker"
assert_not_contains "$ghlog" "appmap-behavioral-review:" "dot tag adds no tag suffix"

# --- unsafe characters in the tag are normalized ---
MOCK_GH_EXISTING_ID="" COMMENT_TAG='we"b >1' run_post "$TMP/pr.json"
ghlog="$(cat "$TMP/ghlog")"
assert_contains "$ghlog" "<!-- appmap-behavioral-review:we-b-1 -->" "tag is sanitized for the marker"

finish
