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

reset() { : > "$LOG"; : > "$GITHUB_OUTPUT"; rm -rf "$WORK/gold_traces" "$WORK/.appmap"; }
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

# --- copilot update: correct flag + skills-path preamble ---
reset
AGENT=copilot COPILOT_TOKEN=tok GOLD_TRACES_DIR=gold_traces \
  assert_ok "copilot update runs" agent_run update
body="$(log_body)"
assert_contains "$body" "--allow-all-tools" "copilot uses allow-all-tools flag"
assert_contains "$body" "$SKILLS_DIR_EXPECTED" "copilot prompt points at on-disk skills dir"

# --- copilot: missing token fails ---
reset
AGENT=copilot GOLD_TRACES_DIR=gold_traces \
  assert_fail "copilot without a token fails" agent_run update

# --- unknown agent fails ---
reset
AGENT=bogus GOLD_TRACES_DIR=gold_traces \
  assert_fail "unknown agent fails" agent_run update

finish
