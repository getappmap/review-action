#!/usr/bin/env bash
# Run the selected agent (Claude Code or GitHub Copilot CLI) headless with one of
# the action's prompt templates.
#
# Usage: run-agent.sh <update|review>
set -euo pipefail

: "${ACTION_PATH:?ACTION_PATH is required}"

AGENT="${AGENT:-claude}"
mode="${1:?usage: run-agent.sh <update|review>}"

# Directory the skills were cloned into (must match scripts/install-skills.sh).
SKILLS_DIR="${RUNNER_TEMP:-/tmp}/getappmap-skills"
export SKILLS_DIR

# Each agent run leaves a usage record in $USAGE_DIR: the raw agent output plus
# a normalized usage-<mode>.json written by scripts/usage.mjs, built only from
# data the agent itself reports. `normalize` also prints the agent's final
# message(s), so the job log stays readable in JSON output mode. Usage
# accounting is best-effort: on any failure, fall back to dumping the raw
# output and continue.
USAGE_DIR="${USAGE_DIR:-${RUNNER_TEMP:-/tmp}/appmap-usage}"
mkdir -p "$USAGE_DIR"

normalize_usage() { # <claude|copilot> <raw-file>
  # --no-log: the stream filter already showed the agent's messages live.
  node "$ACTION_PATH/scripts/usage.mjs" normalize "$1" "$2" \
    --mode "$mode" --out "$USAGE_DIR/usage-$mode.json" \
    --state-dir "${COPILOT_STATE_DIR:-$HOME/.copilot/session-state}" \
    --no-log \
    || cat "$2" 2>/dev/null || true
}

# Live progress: tee the agent's event stream through the usage.mjs filter,
# which forwards every line to the raw capture file and prints one compact
# line per tool call / assistant message — so the job log shows what the
# agent is doing during a long run instead of going silent.
stream_filter() { # <claude|copilot> <raw-file>
  node "$ACTION_PATH/scripts/usage.mjs" stream "$1" --raw-out "$2" || cat > "$2"
}

render_prompt() {
  # Substitute a known set of ${VAR} placeholders in a template from the
  # environment. Pure bash (no envsubst dependency); only these names are
  # expanded, and command substitution / backticks in the template are left
  # untouched.
  local content var val
  content="$(cat "$1")"
  for var in GOLD_TRACES_DIR BASE_REVISION HEAD_REVISION REPORT_FILE SKILLS_DIR; do
    val="${!var:-}"
    content="${content//\$\{$var\}/$val}"
  done
  printf '%s' "$content"
}

# ---- build the base prompt ---------------------------------------------------
case "$mode" in
  update)
    : "${GOLD_TRACES_DIR:?GOLD_TRACES_DIR is required}"
    export GOLD_TRACES_DIR
    prompt="$(render_prompt "$ACTION_PATH/prompts/update-gold-traces.md")"
    ;;
  review)
    : "${BASE_REVISION:?BASE_REVISION is required}"
    : "${HEAD_REVISION:?HEAD_REVISION is required}"
    REPORT_FILE="$(pwd)/.appmap/review/report.md"
    mkdir -p "$(dirname "$REPORT_FILE")"
    export BASE_REVISION HEAD_REVISION REPORT_FILE
    prompt="$(render_prompt "$ACTION_PATH/prompts/review.md")"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    exit 2
    ;;
esac

# ---- run the selected agent --------------------------------------------------
case "$AGENT" in
  claude)
    : "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required for agent 'claude'}"
    export ANTHROPIC_API_KEY
    model_args=()
    [[ -n "${CLAUDE_MODEL:-}" ]] && model_args=(--model "$CLAUDE_MODEL")
    # Claude auto-loads the skills from ~/.claude/skills (symlinked at install).
    # The CI job is the sandbox, so tool permissions are bypassed.
    # stream-json emits every tool call and message as it happens (live
    # progress via stream_filter) and ends with the same result event that
    # carries the usage accounting (tokens, cost, models).
    raw="$USAGE_DIR/raw-$mode-claude.jsonl"
    set +e
    claude -p "$prompt" \
      --dangerously-skip-permissions \
      --output-format stream-json --verbose \
      "${model_args[@]}" \
      | stream_filter claude "$raw"
    agent_status="${PIPESTATUS[0]}"
    set -e
    normalize_usage claude "$raw"
    [[ "$agent_status" -eq 0 ]] || exit "$agent_status"
    ;;

  copilot)
    # Copilot uses a GitHub token with Copilot access; the default GITHUB_TOKEN
    # cannot, so prefer COPILOT_TOKEN and fall back to GITHUB_TOKEN.
    token="${COPILOT_TOKEN:-${GITHUB_TOKEN:-}}"
    if [[ -z "$token" ]]; then
      echo "error: agent 'copilot' needs a Copilot-enabled token (copilot-token input)" >&2
      exit 1
    fi
    export GH_TOKEN="$token" GITHUB_TOKEN="$token"
    model_args=()
    [[ -n "${COPILOT_MODEL:-}" ]] && model_args=(--model "$COPILOT_MODEL")

    # Copilot does not load ~/.claude/skills, so tell it where the skills live on
    # disk and to follow them. The skills reference each other and ship an engine
    # under each skill's assets/ — all reachable under $SKILLS_DIR.
    preamble="You have AppMap skills available on disk under ${SKILLS_DIR}. Wherever the
task below says to \"use the <name> skill\", read ${SKILLS_DIR}/<name>/SKILL.md and
follow it, including any skills it references (e.g. appmap-label, appmap-record) and
its engine at ${SKILLS_DIR}/<name>/assets/ (substitute that path for any \"<skill>\"
placeholder). Do not ask questions; you are non-interactive.

"
    # --allow-all-tools runs fully non-interactively (the CI job is the sandbox).
    # JSON output is a live JSONL event stream (progress via stream_filter)
    # ending in a `result` event with the usage accounting (premium requests,
    # durations).
    raw="$USAGE_DIR/raw-$mode-copilot.jsonl"
    set +e
    copilot -p "${preamble}${prompt}" \
      --allow-all-tools \
      --output-format json \
      "${model_args[@]}" \
      | stream_filter copilot "$raw"
    agent_status="${PIPESTATUS[0]}"
    set -e
    normalize_usage copilot "$raw"
    [[ "$agent_status" -eq 0 ]] || exit "$agent_status"
    ;;

  *)
    echo "unknown agent: $AGENT (expected 'claude' or 'copilot')" >&2
    exit 2
    ;;
esac

# ---- verify review output ----------------------------------------------------
if [[ "$mode" == "review" ]]; then
  if [[ ! -s "$REPORT_FILE" ]]; then
    echo "error: the review agent did not write a report to $REPORT_FILE" >&2
    exit 1
  fi
  echo "report-file=$REPORT_FILE" >> "$GITHUB_OUTPUT"
fi
