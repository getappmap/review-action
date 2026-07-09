#!/usr/bin/env bash
# run-agent.sh: prompt rendering, agent branching, token validation, review output.
# The real agent CLI is replaced by test/mocks/{claude,copilot}.
set -uo pipefail
SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$(cd "$SUITE_DIR/.." && pwd)"
ROOT="$(cd "$TEST_DIR/.." && pwd)"
source "$TEST_DIR/lib/assert.sh"

echo "== run-agent.sh =="

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WORK="$TMP/work"; mkdir -p "$WORK"
LOG="$TMP/agent.log"

export PATH="$TEST_DIR/mocks:$PATH"
export ACTION_PATH="$ROOT"
export RUNNER_TEMP="$TMP/rt"; mkdir -p "$RUNNER_TEMP"
export MOCK_AGENT_LOG="$LOG"
export GITHUB_OUTPUT="$TMP/gh_out"
SKILLS_DIR_EXPECTED="$RUNNER_TEMP/getappmap-skills"

USAGE_DIR_DEFAULT="$RUNNER_TEMP/appmap-usage"
reset() { : > "$LOG"; : > "$GITHUB_OUTPUT"; rm -rf "$WORK/gold_traces" "$WORK/.appmap" "$USAGE_DIR_DEFAULT"; }
agent_run() { ( cd "$WORK" && bash "$ROOT/scripts/run-agent.sh" "$1" ); }
log_body() { cat "$LOG"; }

# --- claude update: success + correct flag + rendered prompt ---
reset
AGENT=claude ANTHROPIC_API_KEY=key GOLD_TRACES_DIR=gold_traces \
  assert_ok "claude update runs" agent_run update
assert_file "$WORK/gold_traces/appmap_golden_set.yaml" "update seeded gold traces"
body="$(log_body)"
assert_contains "$body" "--dangerously-skip-permissions" "claude uses skip-permissions flag"
assert_contains "$body" "appmap-gold-traces" "prompt names the gold-traces skill"
assert_contains "$body" "gold_traces" "placeholder \${GOLD_TRACES_DIR} rendered"
assert_not_contains "$body" '${GOLD_TRACES_DIR}' "no unrendered placeholder remains"
assert_file "$USAGE_DIR_DEFAULT/usage-update.json" "claude update wrote a usage record"
usage="$(cat "$USAGE_DIR_DEFAULT/usage-update.json")"
assert_contains "$usage" '"agent": "claude"' "usage record names the agent"
assert_contains "$usage" '"cost_usd": 0.42' "usage record carries the reported cost"
assert_contains "$usage" 'claude-mock-1' "usage record carries the model id"

# --- claude update: missing API key fails ---
reset
AGENT=claude GOLD_TRACES_DIR=gold_traces \
  assert_fail "claude update without ANTHROPIC_API_KEY fails" agent_run update

# --- claude review: writes report + sets output ---
reset
AGENT=claude ANTHROPIC_API_KEY=key BASE_REVISION=base HEAD_REVISION=head \
  assert_ok "claude review runs" agent_run review
assert_file "$WORK/.appmap/review/report.md" "review wrote the report"
assert_contains "$(cat "$GITHUB_OUTPUT")" "report-file=" "review sets report-file output"

# --- review: agent produced no report -> error ---
reset
AGENT=claude ANTHROPIC_API_KEY=key BASE_REVISION=base HEAD_REVISION=head MOCK_NO_REPORT=1 \
  assert_fail "review fails when no report is written" agent_run review

# --- agent-agnostic model / mini-model ---
reset
AGENT=claude ANTHROPIC_API_KEY=key GOLD_TRACES_DIR=gold_traces MODEL=claude-sonnet-4-5 MINI_MODEL=claude-haiku-x \
  assert_ok "claude update with model + mini-model" agent_run update
body="$(log_body)"
assert_contains "$body" "--model claude-sonnet-4-5" "model passed to claude as --model"
assert_contains "$body" "small_fast_model=claude-haiku-x" "mini-model exported as ANTHROPIC_SMALL_FAST_MODEL"

reset
AGENT=copilot COPILOT_TOKEN=tok GOLD_TRACES_DIR=gold_traces MODEL=gpt-x \
  assert_ok "copilot update with model" agent_run update
assert_contains "$(log_body)" "--model gpt-x" "model passed to copilot as --model"

reset
AGENT=copilot COPILOT_TOKEN=tok GOLD_TRACES_DIR=gold_traces MINI_MODEL=claude-haiku-x \
  assert_ok "copilot update with mini-model (ignored)" agent_run update
assert_contains "$LAST_OUTPUT" "not supported by the copilot agent" "copilot warns on mini-model"
assert_not_contains "$(log_body)" "small_fast_model=claude-haiku-x" "copilot does not export a mini-model"

# --- copilot update: correct flag + skills-path preamble ---
reset
AGENT=copilot COPILOT_TOKEN=tok GOLD_TRACES_DIR=gold_traces \
  assert_ok "copilot update runs" agent_run update
body="$(log_body)"
assert_contains "$body" "--allow-all-tools" "copilot uses allow-all-tools flag"
assert_contains "$body" "$SKILLS_DIR_EXPECTED" "copilot prompt points at on-disk skills dir"
assert_file "$USAGE_DIR_DEFAULT/usage-update.json" "copilot update wrote a usage record"
usage="$(cat "$USAGE_DIR_DEFAULT/usage-update.json")"
assert_contains "$usage" '"premium_requests": 3' "usage record carries premium requests"
assert_contains "$usage" '"cost_usd": null' "no dollar cost is reported for copilot"
assert_contains "$usage" 'claude-mock-copilot' "usage record carries the model id"

# --- copilot review: token detail enriched from the CLI's own session log ---
reset
STATE="$TMP/copilot-state/mock-copilot-session"; mkdir -p "$STATE"
echo '{"type":"assistant.message","data":{"model":"claude-mock-copilot","usage":{"inputTokens":25855,"outputTokens":4,"cacheReadTokens":10,"cacheWriteTokens":25852,"reasoningTokens":0}}}' > "$STATE/events.jsonl"
AGENT=copilot COPILOT_TOKEN=tok BASE_REVISION=base HEAD_REVISION=head COPILOT_STATE_DIR="$TMP/copilot-state" \
  assert_ok "copilot review runs" agent_run review
usage="$(cat "$USAGE_DIR_DEFAULT/usage-review.json")"
assert_contains "$usage" '"input_tokens": 25855' "token detail enriched from the session log"

# --- copilot: missing token fails ---
reset
AGENT=copilot GOLD_TRACES_DIR=gold_traces \
  assert_fail "copilot without a token fails" agent_run update

# --- unknown agent fails ---
reset
AGENT=bogus GOLD_TRACES_DIR=gold_traces \
  assert_fail "unknown agent fails" agent_run update

finish
