#!/usr/bin/env bash
# Run Claude Code headless with one of the action's prompt templates.
#
# Usage: run-agent.sh <update|review>
set -euo pipefail

: "${ANTHROPIC_API_KEY:?ANTHROPIC_API_KEY is required}"
: "${ACTION_PATH:?ACTION_PATH is required}"

mode="${1:?usage: run-agent.sh <update|review>}"

model_args=()
if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  model_args=(--model "$CLAUDE_MODEL")
fi

render_prompt() {
  # Substitute ${VAR} placeholders in a template using the current environment.
  local template="$1"
  envsubst < "$template"
}

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

# Headless, fully non-interactive. The CI job is the sandbox, so tool permissions
# are bypassed — there is no user to approve edits/commands.
claude -p "$prompt" \
  --dangerously-skip-permissions \
  "${model_args[@]}"

if [[ "$mode" == "review" ]]; then
  if [[ ! -s "$REPORT_FILE" ]]; then
    echo "error: the review agent did not write a report to $REPORT_FILE" >&2
    exit 1
  fi
  echo "report-file=$REPORT_FILE" >> "$GITHUB_OUTPUT"
fi
