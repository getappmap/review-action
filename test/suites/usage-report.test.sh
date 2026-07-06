#!/usr/bin/env bash
# usage.mjs report: aggregate the per-run usage records into a footer and step
# outputs. Claude runs show cost; copilot runs show premium requests and never
# a dollar figure. No records -> quiet no-op.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SUITE_DIR/.." && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assert.sh"

echo "== usage.mjs report =="

if ! command -v node >/dev/null 2>&1; then
  echo "  (skipped: node not installed)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

run_report() { # usage-dir
  GITHUB_OUTPUT="$TMP/gh_out" USAGE_DIR="$1" node "$ROOT/scripts/usage.mjs" report
}

# --- claude: two runs aggregate; footer shows cost and cache share ---
DIR="$TMP/claude"; mkdir -p "$DIR"; : > "$TMP/gh_out"
cat > "$DIR/usage-update.json" <<'EOF'
{"mode":"update","agent":"claude","models":["claude-mock-1"],"input_tokens":1000,
 "cache_read_tokens":8000,"cache_write_tokens":1000,"output_tokens":500,
 "cost_usd":0.30,"premium_requests":null,"num_turns":10,"duration_ms":60000}
EOF
cat > "$DIR/usage-review.json" <<'EOF'
{"mode":"review","agent":"claude","models":["claude-mock-1","claude-mock-2"],"input_tokens":2000,
 "cache_read_tokens":16000,"cache_write_tokens":2000,"output_tokens":1500,
 "cost_usd":0.54,"premium_requests":null,"num_turns":20,"duration_ms":150000}
EOF
assert_ok "claude report runs" run_report "$DIR"
footer="$(cat "$DIR/usage-footer.md")"
assert_contains "$footer" '**$0.84**' "total cost is summed"
assert_contains "$footer" '80% from cache' "cache share computed (24k of 30k read)"
assert_contains "$footer" '| update |' "update row present"
assert_contains "$footer" '| review |' "review row present"
assert_contains "$footer" '3m 30s' "total time formatted"
out="$(cat "$TMP/gh_out")"
assert_contains "$out" "cost-usd=0.84" "cost-usd output set"
assert_contains "$out" "premium-requests=" "premium-requests output empty for claude"
assert_contains "$out" "models=claude-mock-1,claude-mock-2" "models output deduplicated"
assert_contains "$out" "footer-file=$DIR/usage-footer.md" "footer-file output set"

# --- copilot: premium requests, no dollar figure anywhere ---
DIR="$TMP/copilot"; mkdir -p "$DIR"; : > "$TMP/gh_out"
cat > "$DIR/usage-review.json" <<'EOF'
{"mode":"review","agent":"copilot","models":["claude-mock-copilot"],"input_tokens":null,
 "cache_read_tokens":null,"cache_write_tokens":null,"output_tokens":900,
 "cost_usd":null,"premium_requests":7,"num_turns":null,"duration_ms":90000}
EOF
assert_ok "copilot report runs" run_report "$DIR"
footer="$(cat "$DIR/usage-footer.md")"
assert_contains "$footer" '**7**' "premium requests totalled"
assert_contains "$footer" 'not reported' "unreported token detail is labeled, not guessed"
assert_not_contains "$footer" '$' "no dollar figure for copilot"
out="$(cat "$TMP/gh_out")"
assert_contains "$out" "premium-requests=7" "premium-requests output set"
assert_contains "$out" "cost-usd=" "cost-usd output empty for copilot"

# --- no records: quiet success, no footer ---
DIR="$TMP/empty"; mkdir -p "$DIR"; : > "$TMP/gh_out"
assert_ok "empty report is a no-op" run_report "$DIR"
assert_no_file "$DIR/usage-footer.md" "no footer written without records"
assert_eq "" "$(cat "$TMP/gh_out")" "no outputs written without records"

finish
