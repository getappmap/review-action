#!/usr/bin/env bash
# usage.mjs normalize: parse VENDORED REAL agent output (test/fixtures/agent-output)
# so the parser is tested against the genuine CLI output shapes, not mocks.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SUITE_DIR/.." && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assert.sh"

echo "== usage.mjs normalize (real agent traces) =="

if ! command -v node >/dev/null 2>&1; then
  echo "  (skipped: node not installed)"
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURES="$TEST_DIR/fixtures/agent-output"

# --- claude: real result object ---
assert_ok "claude normalize runs" \
  node "$ROOT/scripts/usage.mjs" normalize claude "$FIXTURES/claude-result.json" \
    --mode review --out "$TMP/claude.json"
assert_contains "$LAST_OUTPUT" "git bisect" "agent's final message re-emitted for the log"
rec="$(cat "$TMP/claude.json")"
assert_contains "$rec" '"agent": "claude"' "agent recorded"
assert_contains "$rec" '"claude-haiku-4-5-20251001"' "model id from modelUsage"
assert_contains "$rec" '"cost_usd": 0.0195067' "cost taken verbatim from the agent"
assert_contains "$rec" '"input_tokens": 10' "input tokens from usage"
assert_contains "$rec" '"cache_read_tokens": 17157' "cache reads from usage"
assert_contains "$rec" '"num_turns": 1' "turns recorded"

# --- copilot: real JSONL stream + real session log enrichment ---
assert_ok "copilot normalize runs" \
  node "$ROOT/scripts/usage.mjs" normalize copilot "$FIXTURES/copilot-stream.jsonl" \
    --mode review --out "$TMP/copilot.json" \
    --state-dir "$FIXTURES/copilot-session-state"
assert_contains "$LAST_OUTPUT" "git bisect" "assistant message re-emitted for the log"
rec="$(cat "$TMP/copilot.json")"
assert_contains "$rec" '"agent": "copilot"' "agent recorded"
assert_contains "$rec" '"claude-sonnet-4.6"' "model id from the message events"
assert_contains "$rec" '"premium_requests": 1' "premium requests from the result event"
assert_contains "$rec" '"cost_usd": null' "no dollar figure for copilot"
assert_contains "$rec" '"input_tokens": 25809' "input tokens enriched from the session log"

# --- copilot without a session log: premium requests still reported ---
assert_ok "copilot normalize without session log" \
  node "$ROOT/scripts/usage.mjs" normalize copilot "$FIXTURES/copilot-stream.jsonl" \
    --mode review --out "$TMP/copilot-bare.json" \
    --state-dir "$TMP/does-not-exist"
rec="$(cat "$TMP/copilot-bare.json")"
assert_contains "$rec" '"premium_requests": 1' "premium requests survive without the log"
assert_contains "$rec" '"input_tokens": null' "input tokens honestly null without the log"

# --- rendering respects each agent's input-token semantics ---
# Copilot's inputTokens already includes cache writes; claude's excludes them.
DIR="$TMP/render"; mkdir -p "$DIR"
cp "$TMP/copilot.json" "$DIR/usage-review.json"
USAGE_DIR="$DIR" node "$ROOT/scripts/usage.mjs" report >/dev/null
footer="$(cat "$DIR/usage-footer.md")"
assert_contains "$footer" "25.8k" "copilot tokens read are not double-counted"
assert_not_contains "$footer" "51.6k" "input and cache-write are not summed for copilot"

finish
